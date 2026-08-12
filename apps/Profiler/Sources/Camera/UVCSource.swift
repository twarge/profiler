// AVCaptureSession predates Sendable annotation; all use here is confined to `queue`.
@preconcurrency import AVFoundation
import Foundation

/// Capture from a UVC device — the a7C in USB Streaming mode, or any webcam.
///
/// macOS exposes no ISO or exposure-duration API for capture devices (`AVCaptureDevice.ISO`
/// and `setExposureModeCustom` are both `API_UNAVAILABLE(macos)`), so this source reports
/// gain as advisory only: the servo computes the correction and the UI tells the operator
/// how many stops to dial in on the camera body.
final class UVCSource: NSObject, FrameSource {

    let displayName = "USB video (UVC)"
    var onFrame: ((BeamFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var measurementChannel: MeasurementChannel = .green

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "uvc.capture")
    private var selectedDeviceID: String?

    static func availableDevices() -> [(id: String, name: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
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
            throw NSError(
                domain: "Profiler", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Camera access denied. Grant it in System Settings › Privacy & Security › Camera."]
            )
        }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
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
        session.commitConfiguration()

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
        let sessionRef = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if sessionRef.isRunning { sessionRef.stopRunning() }
                c.resume()
            }
        }
    }

    func gainState() async -> GainState {
        GainState(
            canReadISO: false,
            canSetISO: false,
            currentISO: nil,
            availableISO: [],
            shutterLabel: nil,
            apertureLabel: nil,
            advisoryOnly: true,
            note: "macOS exposes no ISO control for UVC devices. "
                + "Set exposure on the camera body; the servo will tell you which way to go."
        )
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
