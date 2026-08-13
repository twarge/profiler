import AppKit
import CoreGraphics
import Foundation
import Observation

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
        didSet {
            guard selectedUVCDeviceID != oldValue else { return }
            if sourceKind == .uvc { switchToCurrentDeviceProfile() } else { scheduleSave() }
        }
    }
    /// Start capturing on launch using the remembered backend and camera.
    var autostart = true { didSet { scheduleSave() } }
    /// Name of the device whose stored settings are currently loaded, for the sidebar.
    var activeProfileName: String?

    // Analysis
    var settings = AnalysisSettings() {
        didSet {
            pipeline.settings = settings
            source?.measurementChannel = settings.channel
            scheduleSave()
        }
    }
    var metrics = BeamMetrics()
    var frozen = false { didSet { pipeline.isFrozen = frozen } }

    // Display
    var colormap: Colormap = .inferno { didSet { rerenderCurrentFrame(); scheduleSave() } }
    var logarithmic = false { didSet { rerenderCurrentFrame(); scheduleSave() } }
    var displayGain: Double = 1.0 { didSet { rerenderCurrentFrame(); scheduleSave() } }
    var showCrosshair = true { didSet { scheduleSave() } }
    var showEllipse = true { didSet { scheduleSave() } }
    var showAperture = true { didSet { scheduleSave() } }
    var displayImage: CGImage?

    // Gain servo
    var gain = GainState()
    let gainController = GainController()
    var autoGainEnabled = false {
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

        // Release the camera on quit. Without this the session outlives the process and the
        // device stays claimed until it is unplugged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
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
        defer {
            isApplyingProfile = false
            activeProfileName = currentDeviceName
        }

        let p = profile ?? DeviceProfile()
        var next = settings
        next.micronsPerPixel = p.micronsPerPixel
        next.channel = p.channel
        next.noiseSigmaMultiplier = p.noiseSigmaMultiplier
        next.apertureFactor = p.apertureFactor
        next.subtractDarkFrame = p.subtractDarkFrame
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
        showAperture = p.showAperture

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
        profile.micronsPerPixel = settings.micronsPerPixel
        profile.channel = settings.channel
        profile.noiseSigmaMultiplier = settings.noiseSigmaMultiplier
        profile.apertureFactor = settings.apertureFactor
        profile.subtractDarkFrame = settings.subtractDarkFrame
        profile.autoGainEnabled = autoGainEnabled
        profile.targetPeak = targetPeak
        profile.colormap = colormap
        profile.logarithmic = logarithmic
        profile.displayGain = displayGain
        profile.showCrosshair = showCrosshair
        profile.showEllipse = showEllipse
        profile.showAperture = showAperture
        store.save(profile, for: currentDeviceKey)

        var state = store.appState
        state.sourceKind = sourceKind.rawValue
        state.selectedPTPCameraID = selectedPTPCameraID
        state.selectedUVCDeviceID = selectedUVCDeviceID
        state.autostart = autostart
        store.appState = state
    }

    func forgetCurrentDevice() {
        store.forget(key: currentDeviceKey)
        applyProfile(nil)
        status = "Cleared stored settings for \(currentDeviceName)."
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
            activeProfileName = currentDeviceName
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

    private func publish(frame: BeamFrame, metrics: BeamMetrics) {
        lastFrame = frame
        self.metrics = metrics
        displayImage = BeamImageRenderer.makeImage(
            frame: frame,
            colormap: colormap,
            displayGain: displayGain,
            logarithmic: logarithmic
        )
        updateFrameRate()

        Task { await self.runGainServo(metrics: metrics) }
    }

    private func rerenderCurrentFrame() {
        guard let frame = lastFrame else { return }
        displayImage = BeamImageRenderer.makeImage(
            frame: frame,
            colormap: colormap,
            displayGain: displayGain,
            logarithmic: logarithmic
        )
    }

    private func updateFrameRate() {
        let now = Date()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now.timeIntervalSince($0) > 2 }
        if frameTimestamps.count >= 2, let first = frameTimestamps.first {
            let span = now.timeIntervalSince(first)
            fps = span > 0 ? Double(frameTimestamps.count - 1) / span : 0
        }

        // Capture rate is measured from the pipeline's own counter, so it reflects what the
        // camera actually delivered rather than what survived analysis.
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
        guard let image = displayImage, image.width > 0 else { return 5.94 }
        return 35_600.0 / Double(image.width)
    }

    // MARK: - Export

    func exportMeasurement() {
        guard let frame = lastFrame else {
            errorMessage = "Nothing to export yet."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export measurement"
        panel.nameFieldStringValue = "beam-\(Self.timestampString())"
        panel.message = "Writes a PNG, a CSV of both profiles, and a JSON of the metrics."

        guard panel.runModal() == .OK, let base = panel.url else { return }
        let directory = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent

        do {
            if let image = displayImage {
                let rep = NSBitmapImageRep(cgImage: image)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("\(stem).png"))
                }
            }
            try exportCSV(to: directory.appendingPathComponent("\(stem)-profiles.csv"))
            try exportJSON(frame: frame, to: directory.appendingPathComponent("\(stem)-metrics.json"))
            status = "Exported to \(directory.path)."
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportCSV(to url: URL) throws {
        let scale = settings.micronsPerPixel
        var text = "axis,index,position_um,intensity\n"
        for (i, v) in metrics.profileX.enumerated() {
            let position = (Double(i) - metrics.centroidX) * scale
            text += "x,\(i),\(position),\(v)\n"
        }
        for (i, v) in metrics.profileY.enumerated() {
            let position = (Double(i) - metrics.centroidY) * scale
            text += "y,\(i),\(position),\(v)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportJSON(frame: BeamFrame, to url: URL) throws {
        let scale = settings.micronsPerPixel
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": sourceKind.rawValue,
            "frame_width_px": frame.width,
            "frame_height_px": frame.height,
            "microns_per_pixel": scale,
            "channel": settings.channel.rawValue,
            "noise_threshold_sigma": settings.noiseSigmaMultiplier,
            "aperture_factor": settings.apertureFactor,
            "dark_frame_subtracted": hasDarkFrame && settings.subtractDarkFrame,
            "centroid_x_um": metrics.centroidX * scale,
            "centroid_y_um": metrics.centroidY * scale,
            "d4sigma_x_um": metrics.d4SigmaX * scale,
            "d4sigma_y_um": metrics.d4SigmaY * scale,
            "major_diameter_um": metrics.majorDiameter * scale,
            "minor_diameter_um": metrics.minorDiameter * scale,
            "ellipticity": metrics.ellipticity,
            "angle_deg": metrics.angleDegrees,
            "peak_fraction_full_scale": metrics.peak,
            "saturated_fraction": metrics.saturatedFraction,
            "saturated": metrics.isSaturated,
            "background_mean": metrics.backgroundMean,
            "background_sigma": metrics.backgroundSigma,
            "converged": metrics.converged,
            "iterations": metrics.iterations,
        ]
        if let iso = gain.currentISO { payload["iso"] = iso }
        if let shutter = gain.shutterLabel { payload["shutter"] = shutter }
        if let fit = metrics.fitX {
            payload["fit_x_d4sigma_um"] = fit.d4SigmaEquivalent * scale
            payload["fit_x_r_squared"] = fit.rSquared
        }
        if let fit = metrics.fitY {
            payload["fit_y_d4sigma_um"] = fit.d4SigmaEquivalent * scale
            payload["fit_y_r_squared"] = fit.rSquared
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
