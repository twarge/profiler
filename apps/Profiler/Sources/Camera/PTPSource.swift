import CoreGraphics
import Foundation
import ImageIO

/// Live-view capture and ISO control over Sony PC Remote PTP.
final class PTPSource: FrameSource {

    let displayName = "Sony PC Remote (PTP)"
    var onFrame: ((BeamFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var measurementChannel: MeasurementChannel = .green

    let transport = PTPTransport()
    private var session: SonySession?
    private var pollTask: Task<Void, Never>?
    private var selectedCameraID: String?

    /// Published to the UI so the operator can pick which camera to open.
    var onDevicesChanged: (([PTPTransport.DiscoveredCamera]) -> Void)?

    init() {
        transport.onDevicesChanged = { [weak self] devices in
            self?.onDevicesChanged?(devices)
        }
        transport.onDisconnect = { [weak self] in
            self?.onStatus?("Camera disconnected.")
            Task { await self?.stop() }
        }
    }

    func beginDiscovery() {
        transport.startBrowsing()
    }

    var discoveredCameras: [PTPTransport.DiscoveredCamera] { transport.discovered }

    func select(cameraID: String?) {
        selectedCameraID = cameraID
    }

    func start() async throws {
        let cameras = transport.discovered
        guard !cameras.isEmpty else { throw PTPError.noCameraFound }

        let chosen = cameras.first { $0.id == selectedCameraID }
            ?? cameras.first { $0.acceptsPTP }
            ?? cameras[0]
        guard chosen.acceptsPTP else { throw PTPError.cameraRejectsPTP(chosen.name) }
        let id = chosen.id

        // A camera that has just enumerated is often still busy, and a half-completed
        // handshake leaves the session open — which makes the *next* attempt fail too.
        // Each attempt therefore tears the session down before the next one starts.
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await connectOnce(id: id, attempt: attempt)
                return
            } catch {
                lastError = error
                await teardown()
                if attempt < 3 {
                    onStatus?("Attempt \(attempt) failed: \(error.localizedDescription) Retrying…")
                    try? await Task.sleep(for: .milliseconds(600 * attempt))
                }
            }
        }
        throw lastError ?? PTPError.notConnected
    }

    private func connectOnce(id: String, attempt: Int) async throws {
        onStatus?(attempt == 1 ? "Opening session…" : "Opening session (attempt \(attempt))…")
        try await transport.openSession(cameraID: id)

        // Let the device settle before the vendor handshake; sending SDIOConnect the
        // instant the session opens is the most common way to get a DeviceBusy back.
        try? await Task.sleep(for: .milliseconds(250))

        let session = SonySession(transport: transport)
        onStatus?("Running PC Remote handshake…")
        try await session.connect()
        self.session = session

        let isoText = session.currentISO.map { "ISO \($0.label)" } ?? "ISO unknown"
        onStatus?("Connected. \(isoText), \(session.properties.count) properties.")

        startPolling()
    }

    func stop() async {
        await teardown()
    }

    /// Synchronous teardown for app termination. A session left open when the process dies
    /// keeps the camera claimed, and the next launch cannot open it until it is replugged —
    /// which is exactly what "connecting is unreliable" usually turns out to be.
    func closeImmediately() {
        pollTask?.cancel()
        pollTask = nil
        session = nil
        transport.closeSession()
    }

    /// Always leaves the transport with no session open, so the next connect starts clean.
    private func teardown() async {
        pollTask?.cancel()
        // Wait for the loop to actually exit. Closing the session while a PTP transaction
        // is still in flight is a reliable way to wedge the device until it is replugged.
        _ = await pollTask?.value
        pollTask = nil
        session = nil
        transport.closeSession()
    }

    /// Target frame interval. PTP live view over pass-through tops out well below 30 fps,
    /// so the loop aims for a steady cadence rather than going as fast as possible —
    /// a uniform interval matters more than peak rate for a measurement instrument.
    private let frameInterval: Duration = .milliseconds(50)
    /// Property polling is on wall-clock time, deliberately decoupled from the frame
    /// counter: at "every N frames" a slow patch makes refreshes bunch up exactly when
    /// the link is already struggling.
    private let propertyInterval: Duration = .milliseconds(1000)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var consecutiveFailures = 0
            var reportedStall = false
            let clock = ContinuousClock()
            var nextPropertyRefresh = clock.now

            while !Task.isCancelled {
                guard let self, let session = self.session else { break }
                let cycleStart = clock.now

                do {
                    let jpeg = try await session.liveViewJPEG()
                    consecutiveFailures = 0
                    if reportedStall {
                        reportedStall = false
                        self.onStatus?("Live view recovered.")
                    }

                    if let image = Self.decodeJPEG(jpeg),
                       let frame = FrameConverter.beamFrame(
                        from: image, channel: self.measurementChannel) {
                        self.onFrame?(frame)
                    }
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures == 3, !reportedStall {
                        reportedStall = true
                        self.onStatus?(
                            "Live view not responding: \(error.localizedDescription) "
                            + "Check that the camera is in PC Remote mode and not in playback.")
                    }
                    if consecutiveFailures > 40 {
                        self.onStatus?("Live view gave up after 40 consecutive failures.")
                        break
                    }
                    // Back off gently and cap it, rather than paying a flat 250 ms for
                    // every single miss.
                    let backoff = min(50 * consecutiveFailures, 400)
                    try? await Task.sleep(for: .milliseconds(backoff))
                }

                if clock.now >= nextPropertyRefresh {
                    nextPropertyRefresh = clock.now.advanced(by: propertyInterval)
                    try? await session.refreshProperties()
                }

                // Sleep only the remainder of the budget. Sleeping a fixed amount *after*
                // a variable-length transaction makes the period equal transaction time
                // plus the constant, so every slow frame directly becomes a long interval.
                let elapsed = clock.now - cycleStart
                if elapsed < self.frameInterval {
                    try? await Task.sleep(for: self.frameInterval - elapsed)
                }
            }
        }
    }

    // MARK: - Gain

    func gainState() async -> GainState {
        guard let session else { return GainState() }
        let available = session.availableISOValues.map(\.value)
        return GainState(
            canReadISO: session.currentISO != nil,
            canSetISO: session.isoIsWritable && !available.isEmpty,
            currentISO: session.currentISO.flatMap { $0.isAuto ? nil : $0.value },
            availableISO: available,
            shutterLabel: session.shutterSpeedLabel,
            apertureLabel: session.apertureLabel,
            advisoryOnly: !session.isoIsWritable,
            note: session.isoIsWritable
                ? nil
                : "ISO is locked by the camera. Set the mode dial to M or S and turn ISO off AUTO."
        )
    }

    func setISO(_ value: Int) async throws {
        guard let session else { throw PTPError.notConnected }
        guard let match = session.availableISOValues.min(by: {
            abs(log(Double($0.value)) - log(Double(value)))
                < abs(log(Double($1.value)) - log(Double(value)))
        }) else { return }
        try await session.setISO(match)
    }

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
