import CoreGraphics
import Foundation
import Network

/// A camera window on another device, watched over Labcast.
///
/// A `FrameSource` in everything but frames: it starts, stops, reports interruptions and
/// carries the ISO like the camera backends, so a window drives it the same way. But it
/// never calls `onFrame`. Raw frames stay with the device that owns the camera, and what
/// arrives here is that device's finished measurement (`onMeasurement`), a preview of its
/// picture (`onImage`) and the state that labels them (`onState`) — shown as they are, not
/// measured again from a compressed copy.
final class RemoteSource: FrameSource {

    let displayName: String
    /// Never called: see above.
    var onFrame: ((BeamFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var onInterruption: ((SourceInterruption?) -> Void)?
    /// The publisher's choice, not this window's; setting it changes nothing.
    var measurementChannel: MeasurementChannel = .green

    /// The publisher's measurement of one frame, complete with profiles.
    var onMeasurement: ((BeamMetrics) -> Void)?
    var onImage: ((CGImage) -> Void)?
    var onState: ((BeamRemoteState) -> Void)?

    private let subscriber: LabcastSubscriber
    private var tasks: [Task<Void, Never>] = []

    private let lock = NSLock()
    private var connected = false
    private var state: BeamRemoteState?
    private var reported: String?

    /// A publisher by its Bonjour name, as the picker lists it. The name alone is enough to
    /// connect, so a window restored before browsing has found anything still reaches it.
    convenience init(publisherNamed name: String, passcode: String?) {
        self.init(
            endpoint: .service(name: name, type: Labcast.serviceType, domain: "local.", interface: nil),
            name: name, passcode: passcode)
    }

    /// A publisher by address, for one Bonjour cannot reach.
    convenience init(host: String, port: UInt16, passcode: String? = nil) {
        self.init(
            endpoint: .hostPort(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 1),
            name: host, passcode: passcode)
    }

    private init(endpoint: NWEndpoint, name: String, passcode: String?) {
        displayName = name
        subscriber = LabcastSubscriber(
            endpoint: endpoint, passcode: passcode?.isEmpty == false ? passcode : nil)
    }

    deinit {
        tasks.forEach { $0.cancel() }
        subscriber.disconnect()
    }

    /// Returns at once: the link comes up, and comes back after a drop, in its own time,
    /// and says so through `onInterruption` meanwhile.
    func start() async throws {
        guard tasks.isEmpty else { return }
        // Subscribed before connecting, so the retained state is the first thing to arrive.
        let states = subscriber.subscribe(BeamWire.Topic.state)
        let metrics = subscriber.subscribe(BeamWire.Topic.metrics, buffer: 64)
        let images = subscriber.subscribe(BeamWire.Topic.image, buffer: 1)
        let link = subscriber.states()

        tasks = [
            Task { [weak self] in
                for await message in states {
                    guard let state = BeamWire.decode(BeamRemoteState.self, from: message.payload)
                    else { continue }
                    self?.received(state)
                }
            },
            Task { [weak self] in
                for await message in metrics {
                    guard let metrics = BeamWire.decode(BeamMetrics.self, from: message.payload)
                    else { continue }
                    self?.onMeasurement?(metrics)
                }
            },
            Task { [weak self] in
                for await message in images {
                    guard let image = BeamWire.image(fromJPEG: message.payload) else { continue }
                    self?.onImage?(image)
                }
            },
            Task { [weak self] in
                for await state in link { self?.linkChanged(state) }
            },
        ]
        onStatus?("Connecting to \(displayName)…")
        subscriber.connect()
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        subscriber.disconnect()
        lock.withLock {
            connected = false
            state = nil
            reported = nil
        }
    }

    /// The publisher's gain, as of its last state.
    func gainState() async -> GainState {
        lock.withLock { state?.gain } ?? GainState()
    }

    /// Asks the publisher to set its camera's ISO. Its refusal — the servo is on, the
    /// camera cannot — comes back as the error.
    func setISO(_ value: Int) async throws {
        do {
            _ = try await subscriber.request(
                BeamWire.Topic.setISO, payload: BeamWire.encode(value) ?? Data())
        } catch let error as LabcastError {
            throw RemoteError(error, publisher: displayName)
        }
    }

    // MARK: - Link and state

    private func received(_ newState: BeamRemoteState) {
        lock.withLock { state = newState }
        onState?(newState)
        reportInterruption()
    }

    private func linkChanged(_ link: LabcastSubscriber.State) {
        switch link {
        case .connected:
            lock.withLock { connected = true }
            onStatus?("Showing \(displayName).")
        case .connecting, .waiting, .idle, .disconnected:
            lock.withLock { connected = false }
        }
        reportInterruption()
    }

    /// One reason at a time, the nearest first: no link, then whatever has stopped the
    /// publisher's own frames. Reported only when it changes.
    private func reportInterruption() {
        let (reason, changed): (String?, Bool) = lock.withLock {
            let reason: String?
            if !connected {
                reason = "Waiting for \(displayName). If it asks for a passcode, check the one "
                    + "entered here."
            } else if let state {
                if let interruption = state.interruption {
                    reason = interruption
                } else if !state.isRunning {
                    reason = "\(displayName) is not capturing."
                } else if state.isPaused {
                    reason = "Paused at \(displayName)."
                } else {
                    reason = nil
                }
            } else {
                reason = nil
            }
            defer { reported = reason }
            return (reason, reason != reported)
        }
        guard changed else { return }
        onInterruption?(reason.map(SourceInterruption.paused))
    }

    struct RemoteError: LocalizedError {
        var errorDescription: String?

        init(_ error: LabcastError, publisher: String) {
            switch error {
            case let .remote(message): errorDescription = message
            case .timedOut: errorDescription = "\(publisher) did not answer."
            default: errorDescription = "Not connected to \(publisher)."
            }
        }
    }
}
