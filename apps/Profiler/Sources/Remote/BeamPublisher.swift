import CoreGraphics
import Foundation

/// One camera window's measurements, published on the local network for other devices
/// running Profiler to show: a Vision Pro, an iPad, another Mac.
///
/// A thin layer over `LabcastPublisher` that knows this app's topics. Safe to call from any
/// thread — the picture is published from the live-view queue, the rest from the main actor.
final class BeamPublisher: @unchecked Sendable {

    /// The Bonjour name viewers choose this publisher by.
    let name: String
    private let publisher: LabcastPublisher

    /// A viewer asks for an ISO. Throwing sends the reason back to it.
    var onSetISO: (@Sendable (Int) async throws -> Void)? {
        didSet {
            let handler = onSetISO
            publisher.setRequestHandler { request in
                guard request.topic == BeamWire.Topic.setISO, let handler else {
                    throw LabcastError.remote("Profiler does not accept “\(request.topic)”.")
                }
                guard let iso = BeamWire.decode(Int.self, from: request.payload) else {
                    throw LabcastError.remote("The ISO was not a number.")
                }
                try await handler(iso)
                return Data()
            }
        }
    }

    /// - Parameter port: fixed TCP port, or nil for one the system picks.
    init(name: String, passcode: String?, port: UInt16? = nil) {
        self.name = name
        publisher = LabcastPublisher(configuration: .init(
            name: name,
            appID: BeamWire.appID,
            passcode: passcode?.isEmpty == false ? passcode : nil,
            port: port
        ))
    }

    /// Starts listening and advertising, and returns the TCP port.
    @discardableResult
    func start() async throws -> UInt16 {
        try await publisher.start()
    }

    func stop() {
        publisher.stop()
    }

    /// Called with the number of connected viewers whenever it changes.
    func onViewersChanged(_ handler: (@Sendable (Int) -> Void)?) {
        publisher.setSubscribersChangedHandler(handler)
    }

    func publish(state: BeamRemoteState) {
        guard let data = BeamWire.encode(state) else { return }
        publisher.publish(
            BeamWire.Topic.state, payload: data, contentType: "application/json",
            retain: true, droppable: false)
    }

    func publish(metrics: BeamMetrics) {
        guard let data = BeamWire.encode(metrics) else { return }
        publisher.publish(
            BeamWire.Topic.metrics, payload: data, contentType: "application/json",
            retain: false, droppable: false)
    }

    /// Encodes and sends the preview, if anybody is there to see it.
    func publish(image: CGImage) {
        guard publisher.subscriberCount(for: BeamWire.Topic.image) > 0,
              let jpeg = BeamWire.previewJPEG(from: image) else { return }
        publisher.publish(
            BeamWire.Topic.image, payload: jpeg, contentType: "image/jpeg",
            retain: false, droppable: true)
    }
}

/// Hands the live-view queue whichever publisher the window has at the moment, without a
/// hop to the main actor for every picture.
final class BeamPublisherTap: @unchecked Sendable {
    private let lock = NSLock()
    private var _publisher: BeamPublisher?

    var publisher: BeamPublisher? {
        get { lock.withLock { _publisher } }
        set { lock.withLock { _publisher = newValue } }
    }
}
