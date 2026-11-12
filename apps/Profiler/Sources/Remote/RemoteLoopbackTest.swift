import CoreGraphics
import Foundation

/// Publishes a synthetic beam on 127.0.0.1 and watches it through `RemoteSource`, the way
/// a Vision Pro watches a Mac, checking that what arrives is what was sent.
///
/// Part of `--self-test`. The publishing side is wired as a camera window wires it —
/// source, pipeline, publisher — and the viewing side is the app's own remote source, so
/// the whole path is covered: encoding, the Labcast link, decoding, and the ISO request
/// going back the other way.
enum RemoteLoopbackTest {

    static func run() -> Int {
        print("")
        print("Remote source loopback")

        // The self-test runs before the app, on the main thread, with nothing else on it.
        let done = DispatchSemaphore(value: 0)
        let failures = Collected<Int>()
        Task.detached {
            failures.append(await check())
            done.signal()
        }
        done.wait()
        return failures.values.first ?? 1
    }

    private static func check() async -> Int {
        var failures = 0
        func expect(_ name: String, _ ok: Bool, _ detail: String) {
            print("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                  + "\(detail)  \(ok ? "ok" : "FAILED")")
            if !ok { failures += 1 }
        }

        // --- Publishing side ----------------------------------------------------------
        let synthetic = SyntheticSource()
        let pipeline = AnalysisPipeline()
        var settings = AnalysisSettings()
        settings.micronsPerPixel = 3.3
        settings.subtractDarkFrame = false
        pipeline.settings = settings

        let publisher = BeamPublisher(
            name: "Profiler self-test \(ProcessInfo.processInfo.processIdentifier)", passcode: nil)
        let state = BeamRemoteState(
            sourceName: synthetic.displayName,
            sourceKind: ProfilerModel.SourceKind.synthetic.rawValue,
            isRunning: true,
            isPaused: false,
            interruption: nil,
            micronsPerPixel: settings.micronsPerPixel,
            channel: settings.channel,
            frameWidth: 1024,
            frameHeight: 680,
            gain: await synthetic.gainState(),
            autoGain: false
        )
        publisher.publish(state: state)

        let sent = Collected<BeamMetrics>()
        pipeline.onResult = { _, metrics in
            sent.append(metrics)
            publisher.publish(metrics: metrics)
        }
        pipeline.onLiveView = { image, _, _ in
            if let image { publisher.publish(image: image) }
        }
        publisher.onSetISO = { iso in
            guard iso > 0 else { throw LabcastError.remote("No such ISO.") }
            try await synthetic.setISO(iso)
            var next = state
            next.gain = await synthetic.gainState()
            publisher.publish(state: next)
        }

        let port: UInt16
        do {
            port = try await publisher.start()
        } catch {
            expect("Publisher", false, "did not start: \(error)")
            return failures
        }
        defer { publisher.stop() }

        // --- Viewing side -------------------------------------------------------------
        let remote = RemoteSource(host: "127.0.0.1", port: port)
        let receivedStates = Collected<BeamRemoteState>()
        let received = Collected<BeamMetrics>()
        let images = Collected<CGImage>()
        remote.onState = { receivedStates.append($0) }
        remote.onMeasurement = { received.append($0) }
        remote.onImage = { images.append($0) }
        try? await remote.start()

        // The state was published before anyone was listening: it arrives because it is
        // retained, as it would for a viewer joining mid-measurement.
        await wait(seconds: 60) { !receivedStates.values.isEmpty }
        expect("State", receivedStates.values.first == state,
              "retained state reaches a late joiner unchanged")

        synthetic.onFrame = { pipeline.submit($0) }
        try? await synthetic.start()
        // A debug build analyses about one frame a second, and far fewer on a busy machine:
        // the wait ends with the third measurement, the limit only bounds a broken link.
        let wanted = 3
        await wait(seconds: 600) { received.values.count >= wanted && !images.values.isEmpty }
        await synthetic.stop()

        // Every value from the first one received on, in order and bit for bit — profiles,
        // fits and all. The viewer may have subscribed a frame or two into the run.
        let got = received.values
        let all = sent.values
        if got.count >= wanted, let start = all.firstIndex(of: got[0]),
           all.count >= start + got.count {
            let same = Array(all[start..<(start + got.count)]) == got
            let profiles = got.allSatisfy { $0.profileX.count == 1024 && $0.profileY.count == 680 }
            expect("Metrics", same && profiles && got.allSatisfy(\.hasBeam),
                  "\(got.count) measurements received equal to those published")
        } else {
            expect("Metrics", false,
                  "received \(got.count) of \(all.count) published, expected at least \(wanted)")
        }

        if let image = images.values.first {
            expect("Image", image.width == 1024 && image.height == 680,
                  "preview decodes to \(image.width)×\(image.height)")
        } else {
            expect("Image", false, "no preview arrived")
        }

        // --- Control ------------------------------------------------------------------
        do {
            try await remote.setISO(400)
            await wait(seconds: 60) { receivedStates.values.last?.gain.currentISO == 400 }
            let applied = await synthetic.gainState().currentISO
            expect("Set ISO", applied == 400 && receivedStates.values.last?.gain.currentISO == 400,
                  "request reaches the source and comes back in the state")
        } catch {
            expect("Set ISO", false, "request failed: \(error.localizedDescription)")
        }

        do {
            try await remote.setISO(-1)
            expect("Refusal", false, "an impossible ISO was accepted")
        } catch {
            expect("Refusal", error.localizedDescription == "No such ISO.",
                  "the publisher's reason reaches the viewer")
        }

        await remote.stop()
        return failures
    }

    /// Polls until `condition` holds or the time runs out.
    private static func wait(seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Values gathered from the callbacks' own threads.
    private final class Collected<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [T] = []

        var values: [T] { lock.withLock { _values } }
        func append(_ value: T) { lock.withLock { _values.append(value) } }
    }
}
