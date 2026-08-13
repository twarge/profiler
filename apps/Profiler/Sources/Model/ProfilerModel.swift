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
        var id: String { rawValue }

        var detail: String {
            switch self {
            case .ptp: return "PTP live view with closed-loop ISO control."
            case .uvc: return "USB Streaming mode. Higher resolution, no ISO control."
            case .synthetic: return "Simulated beam with known ground truth."
            }
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
            switchToCurrentDeviceProfile()
        }
    }
    var isRunning = false
    var status = "Idle."
    var errorMessage: String?
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
            if sourceKind == .uvc { switchToCurrentDeviceProfile() } else { scheduleSave() }
        }
    }
    /// Start capturing on launch using the remembered backend and camera.
    var autostart = true { didSet { scheduleSave() } }

    // Analysis
    var settings = AnalysisSettings() {
        didSet {
            pipeline.settings = settings
            source?.measurementChannel = settings.channel
            if !useBareSensorPitch { manualMicronsPerPixel = settings.micronsPerPixel }
            scheduleSave()
        }
    }
    var metrics = BeamMetrics()
    var frozen = false { didSet { pipeline.isFrozen = frozen } }

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

    init() {
        pipeline.settings = settings
        gainController.settings.enabled = false
        gainController.settings.targetPeak = targetPeak

        pipeline.onResult = { [weak self] frame, metrics in
            Task { @MainActor in self?.publish(frame: frame, metrics: metrics) }
        }
        pipeline.onLiveView = { [weak self] image, profileX, profileY in
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
                    self.selectedPTPCameraID = cameras.first(where: { $0.acceptsPTP })?.id
                }
            }
        }

        restoreAppState()
        ptpSource.beginDiscovery()
        refreshUVCDevices()

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

        for point in releasePoints {
            NotificationCenter.default.addObserver(
                forName: point,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveTask?.cancel()
                    self?.persist()
                    self?.ptpSource.closeImmediately()
                }
            }
        }
    }

    // MARK: - Persistence

    /// Identity of the device the current settings belong to. Synthetic gets its own bucket
    /// so experimenting with the simulator never disturbs a real camera's calibration.
    var currentDeviceKey: String {
        switch sourceKind {
        case .synthetic: return "synthetic"
        case .ptp: return "ptp/" + (selectedPTPCameraID ?? "unassigned")
        case .uvc: return "uvc/" + (selectedUVCDeviceID ?? "unassigned")
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
        }
    }

    private var currentDeviceName: String {
        switch sourceKind {
        case .synthetic: return "Synthetic beam"
        case .ptp:
            return ptpCameras.first { $0.id == selectedPTPCameraID }?.name ?? "Sony camera"
        case .uvc:
            return uvcDevices.first { $0.id == selectedUVCDeviceID }?.name ?? "USB video device"
        }
    }

    /// Sensor preset matching the attached camera, if the library knows it. Synthetic frames
    /// have no physical sensor, so they deliberately match nothing.
    var detectedSensor: SensorPreset? {
        guard sourceKind != .synthetic else { return nil }
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

    private func restoreAppState() {
        isApplyingProfile = true
        let state = store.appState
        sourceKind = SourceKind(rawValue: state.sourceKind) ?? .synthetic
        selectedPTPCameraID = state.selectedPTPCameraID
        selectedUVCDeviceID = state.selectedUVCDeviceID
        autostart = state.autostart
        isApplyingProfile = false
        applyProfile(store.profile(for: currentDeviceKey))
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

        if profile == nil {
            status = "New device — using default settings."
        }
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

    private func persist() {
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
        store.save(profile, for: currentDeviceKey)

        var state = store.appState
        state.sourceKind = sourceKind.rawValue
        state.selectedPTPCameraID = selectedPTPCameraID
        state.selectedUVCDeviceID = selectedUVCDeviceID
        state.autostart = autostart
        store.appState = state
    }

    // MARK: - Autostart

    /// Restores the last backend and camera, waiting for PTP enumeration if needed.
    ///
    /// The wait matters: `ICDeviceBrowser` takes a second or two to report a camera that is
    /// already plugged in, so starting immediately at launch would reliably fail.
    func restoreAndAutostart() async {
        guard autostart, !isRunning else { return }

        switch sourceKind {
        case .synthetic:
            await start()

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

    func start() async {
        errorMessage = nil
        await stop()

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
    }

    func stop() async {
        if let source {
            await source.stop()
        }
        source = nil
        isRunning = false
        fps = 0
        captureFPS = 0
        frameTimestamps.removeAll()
        captureRateMark = nil
    }

    func beginPTPDiscovery() {
        ptpSource.beginDiscovery()
        ptpCameras = ptpSource.discoveredCameras
    }

    func refreshUVCDevices() {
        uvcDevices = UVCSource.availableDevices().map { UVCDeviceInfo(id: $0.id, name: $0.name) }
        if selectedUVCDeviceID == nil { selectedUVCDeviceID = uvcDevices.first?.id }
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
        droppedFrames = counters.dropped
        if let (mark, count) = captureRateMark {
            let span = now.timeIntervalSince(mark)
            if span >= 1.0 {
                captureFPS = Double(counters.received - count) / span
                captureRateMark = (now, counters.received)
            }
        } else {
            captureRateMark = (now, counters.received)
        }
    }

    // MARK: - Gain

    func refreshGainState() async {
        guard let source else { return }
        gain = await source.gainState()
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
