#if os(visionOS)
import Foundation

// The visionOS build leaves the camera backends out (see `PTPSource`, `UVCSource`): its
// windows show a publishing Mac's measurements, or the synthetic beam. These stand in for
// the two backends so the model — one type for every platform — still has them to name.
// They find no cameras, and `ProfilerModel.SourceKind.available` keeps them out of reach.

private struct NoCameraBackend: LocalizedError {
    var errorDescription: String? {
        "Cameras connect to a Mac or an iPad. Choose a remote source to see one from here."
    }
}

enum PTPTransport {
    struct DiscoveredCamera: Identifiable, Hashable {
        var id: String
        var name: String
        var acceptsPTP: Bool
    }
}

final class PTPSource: FrameSource {
    let displayName = "Sony PC Remote (PTP)"
    var onFrame: ((BeamFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var onInterruption: ((SourceInterruption?) -> Void)?
    var measurementChannel: MeasurementChannel = .green
    var onDevicesChanged: (([PTPTransport.DiscoveredCamera]) -> Void)?
    var discoveredCameras: [PTPTransport.DiscoveredCamera] { [] }

    func beginDiscovery() {}
    func select(cameraID: String?) {}
    func closeImmediately() {}
    func start() async throws { throw NoCameraBackend() }
    func stop() async {}
}

final class UVCSource: FrameSource {
    let displayName = "USB video (UVC)"
    var onFrame: ((BeamFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var onInterruption: ((SourceInterruption?) -> Void)?
    var measurementChannel: MeasurementChannel = .green

    static func availableDevices() -> [(id: String, name: String)] { [] }
    func select(deviceID: String?) {}
    func start() async throws { throw NoCameraBackend() }
    func stop() async {}
}
#endif
