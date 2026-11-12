import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class ProfilerModel {

    enum SourceKind: String, CaseIterable, Identifiable, Codable {
        case ptp = "Sony PC Remote"
        case uvc = "USB Video"
        case synthetic = "Synthetic"
        case remote = "Remote"
        var id: String { rawValue }

        var detail: String {
            switch self {
            case .ptp: return "PTP live view with closed-loop ISO control."
            case .uvc: return "USB Streaming mode. Higher resolution, no ISO control."
            case .synthetic: return "Simulated beam with known ground truth."
            case .remote: return "A camera window published by Profiler on another device."
            }
        }

        /// The backends this platform can run. A Vision Pro has no camera backends: it
        /// shows a publishing Mac's measurements, or the simulator.
        static var available: [SourceKind] {
            #if os(visionOS)
            [.remote, .synthetic]
            #else
            allCases
            #endif
        }
    }

    // Capture
    var sourceKind: SourceKind = .synthetic {
        willSet {
            guard newValue != sourceKind, !isApplyingProfile else { return }
            saveTask?.cancel()
            persist()
        }
        didSet {
            guard sourceKind != oldValue else { return }
            if !isApplyingProfile { letGoOfCameraTakenElsewhere() }
            switchToCurrentDeviceProfile()
            updateBrowsing()
        }
    }
    var isRunning = false
    var status = "Idle."
    var errorMessage: String?
    /// Why frames have stopped arriving: while running, a pause the source expects to
    /// recover from; once a source has ended by itself, why it did — kept over the last
    /// frame until the next start, which would otherwise pass for a live one.
    private(set) var interruption: String?
    /// Rate of frames measured and displayed.
    var fps: Double = 0
    /// Rate of frames arriving from the camera. Divergence from `fps` means analysis is
    /// dropping frames, which is the usual reason a steady capture looks uneven.
    var captureFPS: Double = 0
    var droppedFrames = 0

    // Device selection
    var ptpCameras: [PTPTransport.DiscoveredCamera] = []
    var selectedPTPCameraID: String? {
        willSet {
            guard newValue != selectedPTPCameraID,
                  sourceKind == .ptp, !isApplyingProfile else { return }
            saveTask?.cancel()
            persist()
        }
        didSet {
            guard selectedPTPCameraID != oldValue else { return }
            if refusesTakenCamera(.ptp, selectedPTPCameraID) {
                isApplyingProfile = true
                selectedPTPCameraID = oldValue
                isApplyingProfile = false
                return
            }
            // Only reload settings when this selection is the one in play. Discovery
            // adopting a camera while the Synthetic backend is active must not pull the
            // camera's profile over the simulator's, or save one under the other's key.
            if sourceKind == .ptp { switchToCurrentDeviceProfile() } else { scheduleSave() }
        }
    }
    var uvcDevices: [UVCDeviceInfo] = []
    var selectedUVCDeviceID: String? {
        willSet {
            guard newValue != selectedUVCDeviceID,
                  sourceKind == .uvc, !isApplyingProfile else { return }
            saveTask?.cancel()
            persist()
        }
        didSet {
            guard selectedUVCDeviceID != oldValue else { return }
            if refusesTakenCamera(.uvc, selectedUVCDeviceID) {
                isApplyingProfile = true
                selectedUVCDeviceID = oldValue
                isApplyingProfile = false
                return
            }
            if sourceKind == .uvc { switchToCurrentDeviceProfile() } else { scheduleSave() }
        }
    }
    /// Profiler windows published on the local network, while the Remote backend is chosen.
    private(set) var remotePublishers: [LabcastPeer] = []
    /// The publisher this window shows, by its Bonjour name. Any number of windows may
    /// watch one publisher, so unlike a camera it is never taken.
    var selectedRemoteName: String? {
        willSet {
            guard newValue != selectedRemoteName,
                  sourceKind == .remote, !isApplyingProfile else { return }
            saveTask?.cancel()
            persist()
        }
        didSet {
            guard selectedRemoteName != oldValue else { return }
            if sourceKind == .remote { switchToCurrentDeviceProfile() } else { scheduleSave() }
        }
    }
    /// Passcode for publishers that ask for one. One for the app, like `publishPasscode`.
    var remotePasscode = UserDefaults.standard.string(forKey: NetworkPreference.remotePasscode) ?? "" {
        didSet {
            guard remotePasscode != oldValue else { return }
            UserDefaults.standard.set(remotePasscode, forKey: NetworkPreference.remotePasscode)
            for other in Instruments.shared.others(than: self) where other.remotePasscode != remotePasscode {
                other.remotePasscode = remotePasscode
            }
        }
    }
    /// What the publisher being watched last said about itself. Nil on a local source.
    private(set) var remoteState: BeamRemoteState?

    /// Publish this window's measurements on the local network. Off until the operator
    /// turns it on, and remembered per camera.
    var publishing = false {
        didSet {
            guard publishing != oldValue, !isApplyingProfile else { return }
            syncPublisher()
            scheduleSave()
        }
    }
    /// When set, viewers must enter the same passcode, and the link is encrypted.
    var publishPasscode = UserDefaults.standard.string(forKey: NetworkPreference.publishPasscode) ?? "" {
        didSet {
            guard publishPasscode != oldValue else { return }
            UserDefaults.standard.set(publishPasscode, forKey: NetworkPreference.publishPasscode)
            for other in Instruments.shared.others(than: self) where other.publishPasscode != publishPasscode {
                other.publishPasscode = publishPasscode
            }
            // Not on every keystroke: each change takes the listener down and up again.
            passcodeTask?.cancel()
            passcodeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                self?.syncPublisher()
            }
        }
    }
    /// The name viewers see this window under while it is published.
    private(set) var publishedName: String?
    private(set) var publishError: String?
    private(set) var viewerCount = 0

    /// Start capturing on launch using the remembered backend and camera. One setting for the
    /// app rather than per window, so a change in any window reaches the others.
    var autostart = true {
        didSet {
            guard autostart != oldValue, !isApplyingProfile else { return }
            for other in Instruments.shared.others(than: self) { other.adoptAutostart(autostart) }
            scheduleSave()
        }
    }

    // Analysis
    var settings = AnalysisSettings() {
        didSet {
            pipeline.settings = settings
            source?.measurementChannel = settings.channel
            if !useBareSensorPitch { manualMicronsPerPixel = settings.micronsPerPixel }
            scheduleSave()
            publishState()
        }
    }
    var metrics = BeamMetrics()
    var frozen = false { didSet { pipeline.isFrozen = frozen; publishState() } }

    /// Pitch comes from the streamed frame width rather than the entered value. Held here
    /// rather than in `AnalysisSettings` because the analyser only ever wants the resulting
    /// number, and it is recomputed whenever the stream width changes.
    var useBareSensorPitch = true {
        didSet {
            guard useBareSensorPitch != oldValue else { return }
            if useBareSensorPitch {
                applyBareSensorPitch()
            } else {
                // Hand the entered calibration back, so the checkbox is undoable rather
                // than a one-way overwrite of a number that was measured, not guessed.
                settings.micronsPerPixel = manualMicronsPerPixel
            }
            scheduleSave()
        }
    }
    /// The pitch as entered, held aside while the bare-sensor figure drives the analyser.
    /// This, not the derived value, is what gets stored for the device.
    private var manualMicronsPerPixel: Double = DeviceProfile().micronsPerPixel

    // Display
    var colormap: Colormap = .turbo { didSet { displaySettingsChanged() } }
    var logarithmic = false { didSet { displaySettingsChanged() } }
    var displayGain: Double = 1.0 { didSet { displaySettingsChanged() } }
    var showCrosshair = true { didSet { scheduleSave() } }
    var showEllipse = true { didSet { scheduleSave() } }
    var showMajorAxis = true { didSet { scheduleSave() } }
    var showProfiles = true { didSet { scheduleSave() } }
    /// The current value drawn large on each time-series row.
    var showPlotReadout = true { didSet { scheduleSave() } }
    /// How much history the time-series plots keep and show, in seconds. Pushed straight
    /// into the recorder, which prunes to it on the next sample.
    var plotWindow: Double = 60 {
        didSet { timeSeries.window = plotWindow; scheduleSave() }
    }
    /// Significant figures for every displayed measurement. A display choice, not an
    /// analysis one: exports carry full precision regardless.
    var significantFigures = 3 { didSet { scheduleSave() } }
    /// Fraction reserved for the profile bands on each axis of the image-aspect box. A
    /// fraction rather than a pixel count survives resizing and means the same thing on a
    /// laptop and an iPad.
    var profileChartFraction: Double = 0.18 { didSet { scheduleSave() } }
    var expandedSettingsSections: Set<String> = ["source", "gain"] {
        didSet { scheduleSave() }
    }
    var expandedMetricSections: Set<String> = [
        "position", "size", "shape", "signal", "truth"
    ] {
        didSet { scheduleSave() }
    }
    var displayImage: CGImage?
    /// Raw marginal sums from the live lane, updated at the display rate. The measured,
    /// apertured profiles live in `metrics` and lag behind these.
    var liveProfileX: [Float] = []
    var liveProfileY: [Float] = []

    // Gain servo
    var gain = GainState()
    let gainController = GainController()
    /// On by default: an unexposed beam is the usual reason a first measurement looks wrong,
    /// and the servo is the thing that fixes it. Sources that cannot set gain report the
    /// correction as an advisory instead, so this stays useful even when it cannot act.
    var autoGainEnabled = true {
        didSet {
            gainController.settings.enabled = autoGainEnabled
            gainController.reset()
            if !autoGainEnabled { advisory = nil }
            scheduleSave()
            publishState()
        }
    }
    var targetPeak: Double = 0.70 {
        didSet { gainController.settings.targetPeak = targetPeak; scheduleSave() }
    }
    var advisory: String?

    // Time series

    /// Quantities the operator has asked to display. Recording is independent of this set,
    /// so opening a plot reveals the complete retained history immediately.
    var plottedQuantities: Set<PlotQuantity> = [] {
        didSet { scheduleSave() }
    }
    private(set) var timeSeries = TimeSeriesRecorder()

    func togglePlot(_ quantity: PlotQuantity) {
        if plottedQuantities.contains(quantity) {
            plottedQuantities.remove(quantity)
        } else {
            plottedQuantities.insert(quantity)
        }
    }

    func clearPlots() {
        plottedQuantities.removeAll()
    }

    func resetTimeHistory() {
        timeSeries.clear()
    }

    // Dark frame
    var darkFrameStatus: String?
    var hasDarkFrame = false

    // Synthetic ground truth, shown for validation when that source is active.
    var syntheticTruth: SyntheticSource.Truth?

    struct UVCDeviceInfo: Identifiable, Hashable {
        var id: String
        var name: String
    }

    private var source: FrameSource?
    /// The start or stop under way. Each waits for the one before it, so a stop issued while
    /// a camera is still connecting — the window closing during autostart, say — lands once
    /// the connect has finished instead of racing it, and the connect cannot undo it.
    private var lifecycle: Task<Void, Never>?
    /// Long-lived, so its ICDeviceBrowser keeps running for the life of the app. A browser
    /// created at Start would not have enumerated anything yet and would fail every time.
    private let ptpSource = PTPSource()
    private let pipeline = AnalysisPipeline()
    private var lastFrame: BeamFrame?
    private var frameTimestamps: [Date] = []
    private var captureRateMark: (Date, Int)?

    private let store = SettingsStore()
    private var saveTask: Task<Void, Never>?
    /// Suppresses persistence while a profile is being applied, so restoring settings
    /// doesn't immediately write them back over themselves.
    private var isApplyingProfile = false
    private var isoRefreshCounter = 0
    /// Set once the window has settled what it measures (`open`). Until then the model holds
    /// no camera and saves nothing: its backend is a placeholder, not anybody's choice.
    private(set) var isOpen = false
    /// The window has gone (`endSession`): nothing is published or browsed for any more.
    private var isClosed = false
    /// Whether autostart resumes this window's camera: one that was measuring when the app
    /// last quit, or — with no record of that — the last one used. A window opened beside
    /// others only selects the next free camera, and a reopened one that was idle stays
    /// idle: switching on a camera nobody asked for, the laptop's own or a phone's, is not
    /// autostart's to do.
    private var resumesRememberedCamera = false
    private let releaseObservers = ObserverTokens()

    private var publisher: BeamPublisher?
    /// The same publisher, where the live-view queue can reach it.
    private let publisherTap = BeamPublisherTap()
    private var publishedState: BeamRemoteState?
    private var passcodeTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var remoteImagesReceived = 0

    init() {
        pipeline.settings = settings
        gainController.settings.enabled = false
        gainController.settings.targetPeak = targetPeak

        pipeline.onResult = { [weak self] frame, metrics in
            Task { @MainActor in self?.publish(frame: frame, metrics: metrics) }
        }
        pipeline.onLiveView = { [weak self, publisherTap] image, profileX, profileY in
            // Encoded here, on the live-view queue, and only while a viewer is watching.
            if let image { publisherTap.publisher?.publish(image: image) }
            Task { @MainActor in
                self?.publishLiveView(image: image, profileX: profileX, profileY: profileY)
            }
        }
        pipeline.onDarkFrameProgress = { [weak self] done, total in
            Task { @MainActor in
                self?.darkFrameStatus = "Capturing dark frame \(done)/\(total)…"
            }
        }
        pipeline.onDarkFrameReady = { [weak self] in
            Task { @MainActor in
                self?.hasDarkFrame = true
                self?.darkFrameStatus = "Dark frame captured."
            }
        }

        ptpSource.onDevicesChanged = { [weak self] cameras in
            Task { @MainActor in
                guard let self else { return }
                self.ptpCameras = cameras
                // An empty list means nothing has enumerated yet, not that the remembered
                // camera is gone — clearing the selection here would discard it before the
                // device has had a chance to appear.
                guard !cameras.isEmpty else { return }
                if self.selectedPTPCameraID == nil
                    || !cameras.contains(where: { $0.id == self.selectedPTPCameraID }) {
                    self.selectedPTPCameraID = cameras.first {
                        $0.acceptsPTP && !self.isTakenElsewhere(.ptp, id: $0.id)
                    }?.id
                }
            }
        }

        Instruments.shared.join(self)
        ptpSource.beginDiscovery()

        // Release the camera when the app goes away. Without this the session outlives the
        // process and the device stays claimed until it is unplugged.
        #if os(macOS)
        let releasePoints = [NSApplication.willTerminateNotification]
        #else
        // iOS takes the USB device away the moment the app leaves the foreground, and a
        // suspended app can be killed without ever seeing willTerminate. Backgrounding is
        // the last point at which the session can still be closed cleanly.
        let releasePoints = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ]
        #endif

        releaseObservers.tokens = releasePoints.map { point in
            NotificationCenter.default.addObserver(
                forName: point,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveTask?.cancel()
                    // Every window sees this at once, so none of them speaks for which camera
                    // to launch with: that stays with the last one a window chose or started.
                    self?.persist(includingAppState: false)
                    self?.ptpSource.closeImmediately()
                }
            }
        }
    }

    /// A window that goes without `endSession` — an iPad scene the system discards — must
    /// still not leave its camera claimed. The source closes synchronously; nothing here
    /// can wait for a graceful teardown.
    deinit {
        ptpSource.closeImmediately()
        // A weak member that has gone is dropped on the next change; make one, so other
        // windows see this camera come free now rather than whenever that happens.
        Task { @MainActor in Instruments.shared.prune() }
    }

    // MARK: - Windows

    /// Settles what this window measures, once it is on screen: the camera it had, when it
    /// is restored or reopened from the last session; for the first window of a launch, the
    /// first window's camera from that session, or failing that the one used last; otherwise
    /// the first camera on that backend no other window has, selected but not started. A
    /// new window is for another camera, not a second view of one already in use.
    func open(restoring savedDeviceKey: String?) {
        guard !isOpen else { return }
        let state = store.appState
        var lastKind = SourceKind(rawValue: state.sourceKind) ?? .synthetic
        if !SourceKind.available.contains(lastKind) { lastKind = .synthetic }

        isApplyingProfile = true
        autostart = state.autostart
        let isFirst = !Instruments.shared.others(than: self).contains(where: \.isOpen)
        let launchWindow = savedDeviceKey == nil && isFirst
            ? Instruments.shared.claimLaunchWindow() : nil
        if let key = savedDeviceKey ?? launchWindow?.deviceKey,
           let saved = Self.source(fromDeviceKey: key), SourceKind.available.contains(saved.kind) {
            // Back on the camera it had, and measuring again only if it was when the app quit.
            resumesRememberedCamera = Instruments.shared.wasRunningAtLastQuit(key)
            sourceKind = saved.kind
            switch saved.kind {
            case .ptp: selectedPTPCameraID = saved.id
            case .uvc: selectedUVCDeviceID = saved.id
            case .remote: selectedRemoteName = saved.id
            case .synthetic: break
            }
        } else if isFirst {
            resumesRememberedCamera = true
            sourceKind = lastKind
            selectedPTPCameraID = state.selectedPTPCameraID
            selectedUVCDeviceID = state.selectedUVCDeviceID
            selectedRemoteName = state.selectedRemoteName
        } else {
            sourceKind = lastKind
            selectedRemoteName = state.selectedRemoteName
            // This window's browser has not enumerated yet; the others' have.
            let attached = ptpCameras + Instruments.shared.others(than: self).flatMap(\.ptpCameras)
            selectedPTPCameraID = attached.first {
                $0.acceptsPTP && !isTakenElsewhere(.ptp, id: $0.id)
            }?.id
            selectedUVCDeviceID = UVCSource.availableDevices().first {
                !isTakenElsewhere(.uvc, id: $0.id)
            }?.id
        }
        // A restored window can find its camera opened first by a window restored before it.
        letGoOfCameraTakenElsewhere()
        isApplyingProfile = false
        isOpen = true
        applyProfile(store.profile(for: currentDeviceKey))
        refreshUVCDevices()
        updateBrowsing()
    }

    /// Trades a choice another window has since taken for the first camera still free. A
    /// window keeps the camera it last chose on each backend, and switching back to one
    /// would otherwise leave two windows holding the same camera — each then refusing the
    /// other's start. Only the selection changes: the caller applies the profile.
    private func letGoOfCameraTakenElsewhere() {
        guard let id = selectedDeviceID, isTakenElsewhere(sourceKind, id: id) else { return }
        let wasApplying = isApplyingProfile
        isApplyingProfile = true
        defer { isApplyingProfile = wasApplying }
        switch sourceKind {
        case .ptp:
            selectedPTPCameraID = ptpCameras.first {
                $0.acceptsPTP && !isTakenElsewhere(.ptp, id: $0.id)
            }?.id
        case .uvc:
            selectedUVCDeviceID = uvcDevices.first { !isTakenElsewhere(.uvc, id: $0.id) }?.id
        case .synthetic, .remote:
            break
        }
    }

    /// The window has closed, so nothing is left showing the measurement: the camera is let
    /// go, for the other windows and other apps, and the servo stops writing ISO nobody is
    /// watching.
    func endSession() async {
        // This model goes with its window, so a save the debounce is still holding is
        // written now — the settings only: which camera to launch with is for the windows
        // still open to say.
        saveTask?.cancel()
        persist(includingAppState: false)
        await stop()
        Instruments.shared.leave(self)
        isClosed = true
        syncPublisher()
        updateBrowsing()
    }

    /// The camera this window has taken, which no other window may open: its choice on a
    /// real backend, once it is open. A synthetic beam is nobody's to take, and a remote
    /// publisher is everybody's to watch.
    var heldDeviceKey: String? {
        guard isOpen, sourceKind == .ptp || sourceKind == .uvc, selectedDeviceID != nil
        else { return nil }
        return currentDeviceKey
    }

    func isTakenElsewhere(_ kind: SourceKind, id: String) -> Bool {
        Instruments.shared.holder(of: Self.deviceKey(kind, id), other: self) != nil
    }

    /// Whether a camera just chosen is one another window has, which the caller then puts
    /// back: two windows holding one camera would each refuse the other's start. The picker
    /// marks such a camera, but macOS lets a marked menu item be chosen all the same.
    private func refusesTakenCamera(_ kind: SourceKind, _ id: String?) -> Bool {
        guard sourceKind == kind, !isApplyingProfile, let id, isTakenElsewhere(kind, id: id)
        else { return false }
        let name = kind == .ptp
            ? ptpCameras.first { $0.id == id }?.name
            : uvcDevices.first { $0.id == id }?.name
        errorMessage = CameraTaken.this(name ?? "That camera").localizedDescription
        return true
    }

    private func adoptAutostart(_ value: Bool) {
        isApplyingProfile = true
        autostart = value
        isApplyingProfile = false
    }

    // MARK: - Persistence

    /// Identity of the device the current settings belong to. Synthetic gets its own bucket
    /// so experimenting with the simulator never disturbs a real camera's calibration.
    var currentDeviceKey: String { Self.deviceKey(sourceKind, selectedDeviceID) }

    private var selectedDeviceID: String? {
        switch sourceKind {
        case .synthetic: return nil
        case .ptp: return selectedPTPCameraID
        case .uvc: return selectedUVCDeviceID
        case .remote: return selectedRemoteName
        }
    }

    private static func deviceKey(_ kind: SourceKind, _ id: String?) -> String {
        switch kind {
        case .synthetic: return "synthetic"
        case .ptp: return "ptp/" + (id ?? "unassigned")
        case .uvc: return "uvc/" + (id ?? "unassigned")
        case .remote: return "remote/" + (id ?? "unassigned")
        }
    }

    /// The backend and camera a device key names: the way back from `deviceKey`, for a
    /// window the system restores with the key it was saved under.
    private static func source(fromDeviceKey key: String) -> (kind: SourceKind, id: String?)? {
        if key == deviceKey(.synthetic, nil) { return (.synthetic, nil) }
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let id = parts[1] == "unassigned" ? nil : parts[1]
        switch parts[0] {
        case "ptp": return (.ptp, id)
        case "uvc": return (.uvc, id)
        case "remote": return (.remote, id)
        default: return nil
        }
    }

    /// Subject of the window: whichever camera or source is selected. Reports honestly
    /// when nothing is attached rather than naming a device that isn't there.
    var windowTitle: String {
        switch sourceKind {
        case .synthetic: return "Synthetic beam"
        case .ptp:
            return ptpCameras.first { $0.id == selectedPTPCameraID }?.name ?? "No camera"
        case .uvc:
            return uvcDevices.first { $0.id == selectedUVCDeviceID }?.name ?? "No video device"
        case .remote:
            return selectedRemoteName ?? "No publisher"
        }
    }

    private var currentDeviceName: String {
        switch sourceKind {
        case .synthetic: return "Synthetic beam"
        case .ptp:
            return ptpCameras.first { $0.id == selectedPTPCameraID }?.name ?? "Sony camera"
        case .uvc:
            return uvcDevices.first { $0.id == selectedUVCDeviceID }?.name ?? "USB video device"
        case .remote:
            return selectedRemoteName ?? "Remote publisher"
        }
    }

    /// Sensor preset matching the attached camera, if the library knows it. Synthetic frames
    /// have no physical sensor, so they deliberately match nothing; a remote camera's
    /// calibration is its publisher's business.
    var detectedSensor: SensorPreset? {
        guard sourceKind == .ptp || sourceKind == .uvc else { return nil }
        return SensorLibrary.preset(forDeviceName: currentDeviceName)
    }

    /// The preset's pitch at the width actually being streamed, which is the number the
    /// analyser wants. Nil until a frame has arrived and the stream width is known.
    var detectedSensorPitch: Double? {
        guard let preset = detectedSensor, let frame = lastFrame, frame.width > 0 else {
            return nil
        }
        return preset.pitchMicrons(forFrameWidth: frame.width)
    }

    private func switchToCurrentDeviceProfile() {
        guard !isApplyingProfile else { return }
        applyProfile(store.profile(for: currentDeviceKey))
        scheduleSave()
    }

    private func applyProfile(_ profile: DeviceProfile?) {
        isApplyingProfile = true
        defer { isApplyingProfile = false }

        let p = profile ?? DeviceProfile()
        var next = settings
        next.micronsPerPixel = p.micronsPerPixel
        next.channel = p.channel
        next.noiseSigmaMultiplier = p.noiseSigmaMultiplier
        next.apertureFactor = p.apertureFactor
        next.subtractDarkFrame = p.subtractDarkFrame
        next.fitProfiles = p.fitProfiles
        settings = next
        pipeline.settings = next
        source?.measurementChannel = next.channel

        autoGainEnabled = p.autoGainEnabled
        targetPeak = p.targetPeak
        colormap = p.colormap
        logarithmic = p.logarithmic
        displayGain = p.displayGain
        showCrosshair = p.showCrosshair
        showEllipse = p.showEllipse
        showMajorAxis = p.showMajorAxis
        showProfiles = p.showProfiles
        showPlotReadout = p.showPlotReadout
        significantFigures = p.significantFigures
        plotWindow = p.plotWindow
        profileChartFraction = p.profileChartFraction
        expandedSettingsSections = Set(p.expandedSettingsSections)
        expandedMetricSections = Set(p.expandedMetricSections)
        // The recorder holds the previous device's series; the quantities may be the same
        // but the beam is not, so it starts empty rather than splicing two setups together.
        timeSeries.clear()
        plottedQuantities = Set(p.plottedQuantities)
        manualMicronsPerPixel = p.micronsPerPixel
        useBareSensorPitch = p.useBareSensorPitch
        // With the checkbox on there may be no frame yet to derive from; the next one
        // applies it through `publish`.
        if useBareSensorPitch { applyBareSensorPitch() }

        publishing = p.publishOnNetwork

        if profile == nil {
            status = "New device — using default settings."
        }
        // The camera, and with it the published name, may have changed with the profile.
        syncPublisher()
    }

    private func scheduleSave() {
        guard !isApplyingProfile else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // Coalesce the burst of writes a slider drag produces.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// `includingAppState` writes this window's backend and camera as the ones to launch
    /// with, besides its device's settings.
    private func persist(includingAppState: Bool = true) {
        guard isOpen else { return }
        var profile = DeviceProfile()
        profile.deviceName = currentDeviceName
        profile.micronsPerPixel = manualMicronsPerPixel
        profile.useBareSensorPitch = useBareSensorPitch
        profile.channel = settings.channel
        profile.noiseSigmaMultiplier = settings.noiseSigmaMultiplier
        profile.apertureFactor = settings.apertureFactor
        profile.subtractDarkFrame = settings.subtractDarkFrame
        profile.fitProfiles = settings.fitProfiles
        profile.autoGainEnabled = autoGainEnabled
        profile.targetPeak = targetPeak
        profile.colormap = colormap
        profile.logarithmic = logarithmic
        profile.displayGain = displayGain
        profile.showCrosshair = showCrosshair
        profile.showEllipse = showEllipse
        profile.showMajorAxis = showMajorAxis
        profile.showProfiles = showProfiles
        profile.showPlotReadout = showPlotReadout
        profile.significantFigures = significantFigures
        profile.plotWindow = plotWindow
        // Sorted, so the stored JSON does not churn with the set's iteration order.
        profile.plottedQuantities = plottedQuantities.sorted { $0.rawValue < $1.rawValue }
        profile.profileChartFraction = profileChartFraction
        profile.expandedSettingsSections = expandedSettingsSections.sorted()
        profile.expandedMetricSections = expandedMetricSections.sorted()
        profile.publishOnNetwork = publishing
        store.save(profile, for: currentDeviceKey)

        guard includingAppState else { return }
        var state = store.appState
        state.sourceKind = sourceKind.rawValue
        state.selectedPTPCameraID = selectedPTPCameraID
        state.selectedUVCDeviceID = selectedUVCDeviceID
        state.selectedRemoteName = selectedRemoteName
        state.autostart = autostart
        store.appState = state
    }

    // MARK: - Autostart

    /// Restores the last backend and camera, waiting for PTP enumeration if needed.
    ///
    /// The wait matters: `ICDeviceBrowser` takes a second or two to report a camera that is
    /// already plugged in, so starting immediately at launch would reliably fail.
    func restoreAndAutostart() async {
        guard autostart, resumesRememberedCamera, !isRunning else { return }

        switch sourceKind {
        case .synthetic:
            await start()

        case .remote:
            // No waiting for it to show up in the browser: the link keeps trying by itself.
            if selectedRemoteName != nil { await start() }

        case .uvc:
            refreshUVCDevices()
            guard uvcDevices.contains(where: { $0.id == selectedUVCDeviceID })
                || !uvcDevices.isEmpty else {
                status = "Autostart: no USB video device attached."
                return
            }
            await start()

        case .ptp:
            status = "Waiting for \(currentDeviceName)…"
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                // The window closed while waiting: there is nothing left to start for.
                guard !Task.isCancelled else { return }
                let remembered = ptpCameras.first {
                    $0.id == selectedPTPCameraID && $0.acceptsPTP
                }
                let anyUsable = ptpCameras.first { $0.acceptsPTP }
                if remembered != nil || (selectedPTPCameraID == nil && anyUsable != nil) {
                    await start()
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            status = "Autostart: the remembered camera did not appear. "
                + "Check it is powered on and in PC Remote mode."
        }
    }

    // MARK: - Source lifecycle

    func start() async { await inTurn { await self.startSource() } }

    func stop() async { await inTurn { await self.stopSource() } }

    private func inTurn(_ step: @escaping @MainActor () async -> Void) async {
        let previous = lifecycle
        let current = Task { @MainActor in
            await previous?.value
            await step()
        }
        lifecycle = current
        await current.value
    }

    private func startSource() async {
        errorMessage = nil
        await stopSource()

        do {
            try claimCamera()
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed to start."
            return
        }

        let newSource: FrameSource
        switch sourceKind {
        case .ptp:
            ptpSource.select(cameraID: selectedPTPCameraID)
            newSource = ptpSource
            syntheticTruth = nil
        case .uvc:
            let uvc = UVCSource()
            uvc.select(deviceID: selectedUVCDeviceID)
            newSource = uvc
            syntheticTruth = nil
        case .synthetic:
            let synthetic = SyntheticSource()
            syntheticTruth = synthetic.truth
            newSource = synthetic
        case .remote:
            guard let name = selectedRemoteName else {
                errorMessage = "Choose a publisher first."
                status = "Failed to start."
                return
            }
            let remote = RemoteSource(publisherNamed: name, passcode: remotePasscode)
            watch(remote)
            remoteState = nil
            syntheticTruth = nil
            // Nothing local is being analysed, so nothing local is left to export or rescale.
            lastFrame = nil
            newSource = remote
        }

        newSource.measurementChannel = settings.channel
        // Submitted straight from the capture thread. Hopping to the main actor per frame
        // put every frame behind whatever the UI was doing, which showed up as jitter.
        newSource.onFrame = { [weak self] frame in
            self?.pipeline.submit(frame)
        }
        newSource.onStatus = { [weak self] text in
            Task { @MainActor in self?.status = text }
        }
        newSource.onInterruption = { [weak self, weak newSource] interruption in
            Task { @MainActor in
                // A report from a source since replaced describes nothing on screen.
                guard let self, let newSource, self.source === newSource else { return }
                await self.sourceInterrupted(interruption)
            }
        }

        source = newSource

        do {
            try await newSource.start()
            isRunning = true
            gainController.reset()
            await refreshGainState()
            // Write the working configuration straight through rather than waiting on the
            // debounce, so a later crash can't lose the fact that this setup ran.
            persist()
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed to start."
            isRunning = false
            source = nil
        }
        syncPublisher()
    }

    private func stopSource() async {
        if let source {
            await source.stop()
        }
        source = nil
        isRunning = false
        interruption = nil
        fps = 0
        captureFPS = 0
        frameTimestamps.removeAll()
        captureRateMark = nil
        remoteImagesReceived = 0
        publishState()
    }

    private func sourceInterrupted(_ report: SourceInterruption?) async {
        switch report {
        case nil:
            interruption = nil
        case let .paused(reason):
            interruption = reason
        case let .ended(reason):
            // Stopped here too, so the window stops saying Capturing and the camera is let
            // go properly, whatever state the source left it in.
            await stop()
            interruption = reason
        }
        publishState()
    }

    func beginPTPDiscovery() {
        ptpSource.beginDiscovery()
        ptpCameras = ptpSource.discoveredCameras
    }

    func refreshUVCDevices() {
        uvcDevices = UVCSource.availableDevices().map { UVCDeviceInfo(id: $0.id, name: $0.name) }
        if selectedUVCDeviceID == nil {
            selectedUVCDeviceID = uvcDevices.first { !isTakenElsewhere(.uvc, id: $0.id) }?.id
        }
    }

    /// Settles the camera a start opens, so that it is never one another window has: this
    /// window's choice while that is attached, else the first attached camera no window is
    /// using, which becomes the choice. Left to themselves the sources fall back to the
    /// first camera attached — with two windows, quite possibly the other window's.
    private func claimCamera() throws {
        let attached: [(id: String, name: String, usable: Bool)]
        switch sourceKind {
        case .synthetic, .remote:
            return
        case .ptp:
            attached = ptpCameras.map { ($0.id, $0.name, $0.acceptsPTP) }
        case .uvc:
            refreshUVCDevices()
            attached = uvcDevices.map { ($0.id, $0.name, true) }
        }
        // Nothing attached, or a chosen camera that refuses PTP, is the source's to report.
        if let chosen = attached.first(where: { $0.id == selectedDeviceID }) {
            if isTakenElsewhere(sourceKind, id: chosen.id) { throw CameraTaken.this(chosen.name) }
            return
        }
        let usable = attached.filter(\.usable)
        guard !usable.isEmpty else { return }
        guard let free = usable.first(where: { !isTakenElsewhere(sourceKind, id: $0.id) }) else {
            throw CameraTaken.every(sourceKind)
        }
        switch sourceKind {
        case .ptp: selectedPTPCameraID = free.id
        case .uvc: selectedUVCDeviceID = free.id
        case .synthetic, .remote: break
        }
    }

    /// Block-based observers outlive whoever added them unless removed; these go with the
    /// model, so a window's release hooks do not pile up after it has closed.
    private final class ObserverTokens {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    private enum CameraTaken: LocalizedError {
        case this(String)
        case every(SourceKind)

        var errorDescription: String? {
            switch self {
            case let .this(name):
                return "\(name) is in use in another window."
            case let .every(kind):
                let devices = kind == .ptp ? "Sony camera" : "USB video device"
                return "Every \(devices) attached is in use in another window."
            }
        }
    }

    // MARK: - Frame handling

    /// The full measurement landing — possibly several live frames after the picture it
    /// describes was shown.
    private func publish(frame: BeamFrame, metrics: BeamMetrics) {
        lastFrame = frame
        self.metrics = metrics
        // Before recording anything derived from the pitch: a source can change its stream
        // width mid-run, and a stale pitch would silently rescale every reported size.
        if useBareSensorPitch { applyBareSensorPitch() }
        timeSeries.record(
            metrics: metrics,
            gain: gain,
            micronsPerPixel: settings.micronsPerPixel
        )
        markAnalysed()
        // State first, so a viewer has the scale these numbers are in before the numbers.
        publishState()
        publisher?.publish(metrics: metrics)

        Task { await self.runGainServo(metrics: metrics) }
    }

    /// The live lane: picture and raw profiles at the display rate, no measurement yet.
    private func publishLiveView(image: CGImage?, profileX: [Float], profileY: [Float]) {
        if let image { displayImage = image }
        liveProfileX = profileX
        liveProfileY = profileY
        updateCaptureCounters()
    }

    private func displaySettingsChanged() {
        pipeline.displaySettings = DisplaySettings(
            colormap: colormap, displayGain: displayGain, logarithmic: logarithmic)
        rerenderCurrentFrame()
        scheduleSave()
    }

    /// Re-render on the analysed frame, so a colormap or gain change is visible while
    /// frozen or stopped; when running, the next live frame supersedes it immediately.
    private func rerenderCurrentFrame() {
        guard let frame = lastFrame else { return }
        displayImage = BeamImageRenderer.makeImage(
            frame: frame,
            colormap: colormap,
            displayGain: displayGain,
            logarithmic: logarithmic
        )
    }

    private func markAnalysed() {
        let now = Date()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now.timeIntervalSince($0) > 2 }
        if frameTimestamps.count >= 2, let first = frameTimestamps.first {
            let span = now.timeIntervalSince(first)
            fps = span > 0 ? Double(frameTimestamps.count - 1) / span : 0
        }
    }

    /// Capture rate is measured from the pipeline's own counter, so it reflects what the
    /// camera actually delivered rather than what survived analysis.
    private func updateCaptureCounters() {
        let now = Date()
        let counters = pipeline.counters
        // From a publisher, what arrives is its pictures; frames it skipped are its own count.
        let received = sourceKind == .remote ? remoteImagesReceived : counters.received
        droppedFrames = sourceKind == .remote ? 0 : counters.dropped
        if let (mark, count) = captureRateMark {
            let span = now.timeIntervalSince(mark)
            if span >= 1.0 {
                captureFPS = Double(received - count) / span
                captureRateMark = (now, received)
            }
        } else {
            captureRateMark = (now, received)
        }
    }

    // MARK: - Gain

    func refreshGainState() async {
        guard let source else { return }
        gain = await source.gainState()
        publishState()
    }

    private func runGainServo(metrics: BeamMetrics) async {
        isoRefreshCounter += 1
        if isoRefreshCounter >= 10 {
            isoRefreshCounter = 0
            await refreshGainState()
        }

        guard autoGainEnabled, let source else { return }

        let decision = gainController.update(
            peak: metrics.peak, saturated: metrics.isSaturated, state: gain)

        switch decision {
        case let .setISO(value):
            advisory = nil
            do {
                try await source.setISO(value)
                status = "Auto-gain set ISO \(value)."
                await refreshGainState()
            } catch {
                advisory = "Could not set ISO: \(error.localizedDescription)"
            }
        case let .advise(_, message):
            advisory = message
        case .none:
            break
        }
    }

    func setISOManually(_ value: Int) async {
        guard let source else { return }
        do {
            try await source.setISO(value)
            await refreshGainState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Publishing

    /// Brings the publisher into line with what this window should be publishing: nothing,
    /// unless the operator has turned it on for a window with a source of its own. Called
    /// whenever any of that may have changed; does nothing when it has not.
    private func syncPublisher() {
        let name = isOpen && !isClosed && publishing && sourceKind != .remote
            ? Self.serviceName(for: currentDeviceName) : nil
        if let publisher, publisher.name == name, publishedPasscode == publishPasscode {
            publishState()
            return
        }
        if publisher == nil, name == nil { return }
        publisher?.stop()
        publisher = nil
        publisherTap.publisher = nil
        publishedState = nil
        publishedName = nil
        publishError = nil
        viewerCount = 0
        guard let name else { return }

        let next = BeamPublisher(name: name, passcode: publishPasscode)
        publishedPasscode = publishPasscode
        next.onSetISO = { [weak self] iso in
            guard let self else { throw LabcastError.remote("That window has closed.") }
            try await self.setISO(fromViewer: iso)
        }
        next.onViewersChanged { [weak self, weak next] count in
            Task { @MainActor in
                guard let self, let next, self.publisher === next else { return }
                self.viewerCount = count
            }
        }
        publisher = next
        publisherTap.publisher = next
        publishedName = name
        publishState()
        Task { [weak self] in
            do {
                try await next.start()
            } catch {
                guard let self, self.publisher === next else { return }
                if case let LabcastError.listenerFailed(reason) = error {
                    self.publishError = "Could not publish: \(reason)"
                } else {
                    self.publishError = "Could not publish: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Passcode the running publisher was started with.
    private var publishedPasscode = ""

    /// The computer's name, then the camera's: a Mac with two cameras publishes two windows,
    /// and a viewer has to be able to tell them apart. Bonjour allows a name 63 bytes.
    private static func serviceName(for source: String) -> String {
        #if os(macOS)
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let host = UIDevice.current.name
        #endif
        var name = "\(host) – \(source)"
        while name.utf8.count > 63 { name.removeLast() }
        return name
    }

    /// Sends the retained state, when a publisher is up and the state has changed.
    private func publishState() {
        guard let publisher else { return }
        let state = BeamRemoteState(
            sourceName: currentDeviceName,
            sourceKind: sourceKind.rawValue,
            isRunning: isRunning,
            isPaused: frozen,
            interruption: interruption,
            micronsPerPixel: settings.micronsPerPixel,
            channel: settings.channel,
            frameWidth: lastFrame?.width ?? 0,
            frameHeight: lastFrame?.height ?? 0,
            gain: gain,
            autoGain: autoGainEnabled
        )
        guard state != publishedState else { return }
        publishedState = state
        publisher.publish(state: state)
    }

    /// A viewer's ISO request. Refused wherever this window's own ISO picker would be
    /// disabled, with the reason sent back to the viewer.
    private func setISO(fromViewer value: Int) async throws {
        guard let source, isRunning else {
            throw LabcastError.remote("The camera is not capturing.")
        }
        guard gain.canSetISO else {
            throw LabcastError.remote("This camera's ISO cannot be set from the app.")
        }
        guard !autoGainEnabled else {
            throw LabcastError.remote("The auto-gain servo is on at the publisher, and sets the ISO itself.")
        }
        try await source.setISO(value)
        status = "A viewer set ISO \(value)."
        await refreshGainState()
    }

    // MARK: - Remote source

    /// The size, in pixels, that the metrics' coordinates refer to: the picture's own on a
    /// local source, the publisher's analysed frame on a remote one, whose preview picture
    /// may have been scaled down.
    var beamPixelSize: CGSize {
        if sourceKind == .remote, let remoteState,
           remoteState.frameWidth > 0, remoteState.frameHeight > 0 {
            return CGSize(width: remoteState.frameWidth, height: remoteState.frameHeight)
        }
        guard let image = displayImage else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    /// Whether the ISO is somebody else's to set just now: the servo's — here, or at the
    /// publisher being watched.
    var isoIsServoDriven: Bool {
        sourceKind == .remote ? remoteState?.autoGain ?? false : autoGainEnabled
    }

    /// Browses for publishers only while the Remote backend is chosen: looking is what
    /// makes the system ask for local-network access, which a camera window never needs.
    private func updateBrowsing() {
        let wanted = isOpen && !isClosed && sourceKind == .remote
        guard wanted != (browseTask != nil) else { return }
        browseTask?.cancel()
        browseTask = nil
        guard wanted else {
            remotePublishers = []
            return
        }
        browseTask = Task { [weak self] in
            for await found in LabcastBrowser.peers(appID: BeamWire.appID) {
                guard let self, !Task.isCancelled else { return }
                self.remotePublishers = found
                if self.selectedRemoteName == nil, !self.isRunning {
                    self.selectedRemoteName = found.first?.name
                }
            }
        }
    }

    /// Whether the publisher chosen asks for a passcode, as far as browsing can tell.
    var remoteNeedsPasscode: Bool {
        remotePublishers.first { $0.name == selectedRemoteName }?.requiresPasscode ?? false
    }

    /// Routes a remote source's values to where the pipeline's would go. The seam is here
    /// rather than at `onFrame` because nothing is analysed on this side: the publisher's
    /// metrics, profiles and picture are shown as received.
    private func watch(_ remote: RemoteSource) {
        remote.onState = { [weak self, weak remote] state in
            Task { @MainActor in
                guard let self, let remote, self.source === remote else { return }
                self.receive(state)
            }
        }
        remote.onMeasurement = { [weak self, weak remote] metrics in
            Task { @MainActor in
                guard let self, let remote, self.source === remote else { return }
                self.receive(metrics)
            }
        }
        remote.onImage = { [weak self, weak remote] image in
            Task { @MainActor in
                guard let self, let remote, self.source === remote, !self.frozen else { return }
                self.displayImage = image
                self.remoteImagesReceived += 1
                self.updateCaptureCounters()
            }
        }
    }

    private func receive(_ state: BeamRemoteState) {
        remoteState = state
        gain = state.gain
        // The publisher's scale and channel are the ones its numbers are in. Shown, not
        // saved: they are not this window's settings to remember.
        if settings.micronsPerPixel != state.micronsPerPixel || settings.channel != state.channel {
            let wasApplying = isApplyingProfile
            isApplyingProfile = true
            settings.micronsPerPixel = state.micronsPerPixel
            settings.channel = state.channel
            isApplyingProfile = wasApplying
        }
    }

    private func receive(_ metrics: BeamMetrics) {
        guard !frozen else { return }
        self.metrics = metrics
        // The charts draw the live lane's profiles; from a publisher those are the measured
        // ones, which arrive with the metrics they belong to.
        liveProfileX = metrics.profileX
        liveProfileY = metrics.profileY
        timeSeries.record(
            metrics: metrics,
            gain: gain,
            micronsPerPixel: settings.micronsPerPixel
        )
        markAnalysed()
    }

    // MARK: - Dark frame

    func captureDarkFrame() {
        guard isRunning else {
            errorMessage = "Start a source before capturing a dark frame."
            return
        }
        darkFrameStatus = "Block the beam, then wait…"
        pipeline.beginDarkCapture(frames: 16)
    }

    func clearDarkFrame() {
        pipeline.clearDarkFrame()
        hasDarkFrame = false
        darkFrameStatus = nil
    }

    // MARK: - Calibration

    /// Pixel pitch for a bare sensor with the lens removed, derived from the current frame
    /// width. The a7C's 35.6 mm imager is 6000 px wide natively (5.94 µm), so a stream at
    /// any other width scales the effective pitch proportionally.
    func assumedBareSensorScale() -> Double {
        guard let width = streamedFrameWidth else { return 5.94 }
        return 35_600.0 / Double(width)
    }

    /// Width of the frames actually arriving, which is what the bare-sensor pitch divides
    /// into the sensor width. Nil before the first frame, when there is nothing to divide.
    var streamedFrameWidth: Int? {
        guard let frame = lastFrame, frame.width > 0 else { return nil }
        return frame.width
    }

    /// Pushes the derived pitch into the analyser. Called when the checkbox goes on and on
    /// every frame while it stays on, since a source can change its stream width mid-run.
    func applyBareSensorPitch() {
        let pitch = assumedBareSensorScale()
        guard settings.micronsPerPixel != pitch else { return }
        settings.micronsPerPixel = pitch
    }

    // MARK: - Export

    /// The current measurement as shareable, draggable artifacts — nil until a frame has
    /// been analysed. Built on the analysed frame, not the live one, so the exported image
    /// and the exported numbers describe the same beam. Cheap to compute: the encoders
    /// inside run only when a transfer happens.
    var currentExport: MeasurementExport? {
        guard let frame = lastFrame else { return nil }
        return MeasurementExport(
            frame: frame,
            colormap: colormap,
            displayGain: displayGain,
            logarithmic: logarithmic,
            metrics: metrics,
            micronsPerPixel: settings.micronsPerPixel,
            source: sourceKind.rawValue,
            channel: settings.channel.rawValue,
            noiseSigmaMultiplier: settings.noiseSigmaMultiplier,
            apertureFactor: settings.apertureFactor,
            darkFrameSubtracted: hasDarkFrame && settings.subtractDarkFrame,
            iso: gain.currentISO,
            shutter: gain.shutterLabel,
            timestamp: Date()
        )
    }
}

/// App-wide network settings, in UserDefaults beside the rest of the app's state.
enum NetworkPreference {
    static let publishPasscode = "labcast.publishPasscode.v1"
    static let remotePasscode = "labcast.remotePasscode.v1"
}
