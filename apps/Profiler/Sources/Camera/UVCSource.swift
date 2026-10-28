// AVCaptureSession predates Sendable annotation; all use here is confined to `queue`.
@preconcurrency import AVFoundation
import Foundation

/// Capture from a UVC device — the a7C in USB Streaming mode, or any webcam.
///
/// Neither platform lets this source drive exposure, so gain is advisory only: the servo
/// computes the correction and the UI tells the operator how many stops to dial in on the
/// camera body. On macOS there is no API at all (`AVCaptureDevice.ISO` and
/// `setExposureModeCustom` are both `API_UNAVAILABLE(macos)`); on iOS the API exists but
/// applies to the built-in cameras, and UVC devices do not advertise custom exposure.
final class UVCSource: NSObject, FrameSource {

    let displayName = "USB video (UVC)"
    var onFrame: ((BeamFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var onInterruption: ((SourceInterruption?) -> Void)?
    var measurementChannel: MeasurementChannel = .green

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "uvc.capture")
    private var selectedDeviceID: String?

    /// On macOS the built-in FaceTime camera is worth offering — it is a real fallback for
    /// checking the pipeline. On iOS it is not: the iPad's own cameras have fixed lenses and
    /// would silently stand in for a missing beam camera, so only external UVC devices count.
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = {
        #if os(macOS)
        [.external, .builtInWideAngleCamera]
        #else
        [.external]
        #endif
    }()

    static func availableDevices() -> [(id: String, name: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    func select(deviceID: String?) {
        selectedDeviceID = deviceID
    }

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            #if os(macOS)
            let where_ = "System Settings › Privacy & Security › Camera"
            #else
            let where_ = "Settings › Privacy & Security › Camera"
            #endif
            throw NSError(
                domain: "Profiler", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Camera access denied. Grant it in \(where_)."]
            )
        }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices

        guard let device = devices.first(where: { $0.uniqueID == selectedDeviceID })
            ?? devices.first else {
            throw NSError(
                domain: "Profiler", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No USB video device found."]
            )
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(
                domain: "Profiler", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not attach \(device.localizedName)."]
            )
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(
                domain: "Profiler", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not attach video output."]
            )
        }
        session.addOutput(output)
        #if os(iOS)
        // To AVFoundation, a window sharing the screen — beside another Profiler window, or
        // in Split View — is multitasking, and without this the camera is cut off the moment
        // it does. Supported on iPads that run Stage Manager with an external display.
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        #endif
        session.commitConfiguration()
        observeInterruptions(of: device)

        let sessionRef = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                sessionRef.startRunning()
                c.resume()
            }
        }
        onStatus?("Streaming from \(device.localizedName).")
    }

    func stop() async {
        // A stop asked for is not an interruption to report.
        NotificationCenter.default.removeObserver(self)
        let sessionRef = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if sessionRef.isRunning { sessionRef.stopRunning() }
                c.resume()
            }
        }
    }

    func gainState() async -> GainState {
        #if os(macOS)
        let limitation = "macOS exposes no ISO control for UVC devices."
        #else
        let limitation = "iOS exposes ISO only for its own cameras, not UVC devices."
        #endif
        return GainState(
            canReadISO: false,
            canSetISO: false,
            currentISO: nil,
            availableISO: [],
            shutterLabel: nil,
            apertureLabel: nil,
            advisoryOnly: true,
            note: limitation
                + " Set exposure on the camera body; the servo will tell you which way to go."
        )
    }
}

// MARK: - Interruptions

extension UVCSource {
    /// Selector-based observers, which go with the source; `stop` removes them sooner.
    private func observeInterruptions(of device: AVCaptureDevice) {
        let center = NotificationCenter.default
        center.removeObserver(self)
        center.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                           name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                           name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                           name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.addObserver(self, selector: #selector(deviceWasDisconnected(_:)),
                           name: AVCaptureDevice.wasDisconnectedNotification, object: device)
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        onInterruption?(.paused(Self.reason(for: note)))
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        onInterruption?(nil)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        onInterruption?(.ended(
            "Capture stopped: \(error?.localizedDescription ?? "the session failed.") "
            + "Press Start to try again."))
    }

    @objc private func deviceWasDisconnected(_ note: Notification) {
        let name = (note.object as? AVCaptureDevice)?.localizedName ?? "The camera"
        onInterruption?(.ended("\(name) was disconnected."))
    }

    /// What the system says, in terms of what the operator can do about it.
    private static func reason(for note: Notification) -> String {
        #if os(iOS)
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        switch raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)) {
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            // Only on iPads without multitasking camera access; see `start`.
            return "This iPad pauses USB video while the window shares the screen. "
                + "Make the window full screen to resume."
        case .videoDeviceInUseByAnotherClient:
            return "Another app is using the camera."
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "The system paused the camera to let the device cool down."
        case .videoDeviceNotAvailableInBackground:
            return "The camera is unavailable while Profiler is in the background."
        default:
            break
        }
        #endif
        return "The system paused the camera."
    }
}

extension UVCSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let frame = FrameConverter.beamFrame(
            from: buffer, channel: measurementChannel) else { return }
        onFrame?(frame)
    }
}
