import Foundation
import ImageCaptureCore

/// Wraps ImageCaptureCore's PTP pass-through in an async interface.
///
/// We never touch USB directly: macOS's own ImageCapture stack owns the device and
/// `requestSendPTPCommand` forwards raw PTP containers through it. That avoids fighting
/// `ptpcamerad` for the interface and keeps the whole path on public API.
final class PTPTransport: NSObject {

    struct DiscoveredCamera: Identifiable, Hashable {
        var id: String
        var name: String
        var acceptsPTP: Bool

        static func == (a: DiscoveredCamera, b: DiscoveredCamera) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private let browser = ICDeviceBrowser()
    private var devices: [ICCameraDevice] = []
    private var openDevice: ICCameraDevice?

    private var openContinuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    /// Called on the main queue whenever the set of visible cameras changes.
    var onDevicesChanged: (([DiscoveredCamera]) -> Void)?
    /// Raw PTP event packets pushed by the camera.
    var onPTPEvent: ((Data) -> Void)?
    /// The open device went away.
    var onDisconnect: (() -> Void)?

    private(set) var isSessionOpen = false

    override init() {
        super.init()
        browser.delegate = self
    }

    // MARK: - Discovery

    func startBrowsing() {
        let mask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
        browser.browsedDeviceTypeMask = mask
        browser.start()
    }

    func stopBrowsing() {
        browser.stop()
    }

    var discovered: [DiscoveredCamera] {
        devices.map(Self.describe)
    }

    private static func describe(_ d: ICCameraDevice) -> DiscoveredCamera {
        DiscoveredCamera(
            id: d.uuidString ?? d.name ?? UUID().uuidString,
            name: d.name ?? "Unknown camera",
            acceptsPTP: d.capabilities.contains(
                ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        )
    }

    // MARK: - Session

    func openSession(cameraID: String, timeout: Duration = .seconds(10)) async throws {
        // Never stack sessions. A second open against a device that already has one fails,
        // and leaves both attempts wedged.
        if isSessionOpen {
            closeSession()
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Retire any continuation orphaned by a previous attempt, rather than leaking it.
        resumeOpen(.failure(PTPError.timeout("a previous session open")))

        guard let device = devices.first(where: { ($0.uuidString ?? $0.name) == cameraID }) else {
            throw PTPError.noCameraFound
        }
        device.delegate = self
        openDevice = device

        // ImageCaptureCore gives no guarantee that the open callback ever arrives — if the
        // camera is busy or half-asleep it can simply never fire. Without this the await
        // hangs forever and the app looks frozen rather than reporting a failure.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeOpen(.failure(PTPError.timeout("the camera to open a session")))
        }
        defer { watchdog.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            openContinuation = c
            lock.unlock()
            device.requestOpenSession()
        }
        isSessionOpen = true
    }

    func closeSession() {
        isSessionOpen = false
        guard let d = openDevice else { return }
        openDevice = nil
        d.requestCloseSession()
    }

    private func resumeOpen(_ result: Result<Void, Error>) {
        lock.lock()
        let c = openContinuation
        openContinuation = nil
        lock.unlock()
        switch result {
        case .success: c?.resume()
        case let .failure(e): c?.resume(throwing: e)
        }
    }

    // MARK: - Transactions

    /// Sends one PTP transaction and returns the response code, parameters, and data phase.
    ///
    /// `throwOnError: false` is used for probes where a non-OK response is a legitimate
    /// answer rather than a failure (live-view handle discovery, optional properties).
    @discardableResult
    func send(
        _ code: UInt16,
        parameters: [UInt32] = [],
        outData: Data? = nil,
        throwOnError: Bool = true
    ) async throws -> PTPResponse {
        guard let device = openDevice, isSessionOpen else { throw PTPError.notConnected }
        let command = PTPCommand.container(code: code, parameters: parameters)

        let response: PTPResponse = try await withCheckedThrowingContinuation { c in
            device.requestSendPTPCommand(command, outData: outData) { first, second, error in
                if let error {
                    c.resume(throwing: error)
                    return
                }
                // Apple's block names the two NSData arguments ambiguously
                // (`responseData` then `ptpResponseData`), so identify them by content:
                // whichever parses as a container with type == response is the response.
                let a = first
                let b = second
                let parsedA = PTPCommand.parseResponse(a)
                let parsedB = PTPCommand.parseResponse(b)

                let parsed: (code: UInt16, parameters: [UInt32])?
                let payload: Data
                if let parsedA, parsedB == nil {
                    parsed = parsedA
                    payload = b
                } else if let parsedB, parsedA == nil {
                    parsed = parsedB
                    payload = a
                } else if let parsedA, parsedB != nil {
                    // Both parse — the shorter one is the response container.
                    if a.count <= b.count { parsed = parsedA; payload = b }
                    else { parsed = parsedB; payload = a }
                } else {
                    parsed = nil
                    payload = a.isEmpty ? b : a
                }

                guard let parsed else {
                    c.resume(throwing: PTPError.badContainer("no response container in reply"))
                    return
                }
                c.resume(returning: PTPResponse(
                    code: parsed.code,
                    parameters: parsed.parameters,
                    data: Self.stripDataHeader(payload)
                ))
            }
        }

        if throwOnError, !response.isOK {
            throw PTPError.deviceResponse(code: response.code)
        }
        return response
    }

    /// ImageCaptureCore sometimes hands back the data phase still wrapped in its 12-byte
    /// container header and sometimes hands back the bare payload. Detect and strip.
    private static func stripDataHeader(_ data: Data) -> Data {
        guard data.count >= 12 else { return data }
        var r = PTPReader(data)
        guard let length = try? r.u32(), let type = try? r.u16() else { return data }
        guard type == PTPContainerType.data, Int(length) <= data.count, length >= 12 else {
            return data
        }
        return data.subdata(in: 12..<Int(length))
    }
}

// MARK: - ICDeviceBrowserDelegate

extension PTPTransport: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        if let cam = device as? ICCameraDevice, !devices.contains(where: { $0 === cam }) {
            devices.append(cam)
        }
        if !moreComing { notifyDevices() }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        devices.removeAll { $0 === device }
        if device === openDevice {
            openDevice = nil
            isSessionOpen = false
            DispatchQueue.main.async { self.onDisconnect?() }
        }
        if !moreGoing { notifyDevices() }
    }

    private func notifyDevices() {
        let list = discovered
        DispatchQueue.main.async { self.onDevicesChanged?(list) }
    }
}

// MARK: - ICDeviceDelegate / ICCameraDeviceDelegate

extension PTPTransport: ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { resumeOpen(.failure(error)) } else { resumeOpen(.success(())) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        isSessionOpen = false
    }

    func didRemove(_ device: ICDevice) {
        if device === openDevice {
            openDevice = nil
            isSessionOpen = false
            DispatchQueue.main.async { self.onDisconnect?() }
        }
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        // Non-fatal; transaction-level errors surface through the send() continuation.
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        DispatchQueue.main.async { self.onPTPEvent?(eventData) }
    }

    // Content-catalog callbacks: unused, we only speak pass-through PTP.
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: Error?
    ) {}
    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: Error?
    ) {}
}
