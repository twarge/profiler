import Foundation

/// Runs analysis off the main thread and drops frames rather than queueing them.
///
/// Beam profiling wants the *latest* measurement, not every measurement. If analysis
/// falls behind the capture rate, queueing would grow unbounded latency and show stale
/// numbers; dropping keeps the display honest about the present.
final class AnalysisPipeline {

    private let queue = DispatchQueue(label: "beam.analysis", qos: .userInitiated)
    private let lock = NSLock()

    private var _settings = AnalysisSettings()
    private var _darkFrame: [Float]?
    private var _frozen = false
    private var busy = false

    private var _received = 0
    private var _analysed = 0
    private var _dropped = 0

    /// Frames arriving from the source, frames actually measured, and frames discarded
    /// because analysis was still busy. The gap between the first two is what makes a
    /// nominally steady capture rate look uneven on screen.
    struct Counters {
        var received = 0
        var analysed = 0
        var dropped = 0
    }

    var counters: Counters {
        lock.withLock { Counters(received: _received, analysed: _analysed, dropped: _dropped) }
    }

    /// Held here rather than on the model so the capture thread can honour it without a
    /// hop to the main actor for every single frame.
    var isFrozen: Bool {
        get { lock.withLock { _frozen } }
        set { lock.withLock { _frozen = newValue } }
    }

    private var darkAccumulator: [Double]?
    private var darkFramesRemaining = 0
    private var darkFrameTotal = 0

    var onResult: ((BeamFrame, BeamMetrics) -> Void)?
    var onDarkFrameProgress: ((Int, Int) -> Void)?
    var onDarkFrameReady: (() -> Void)?

    var settings: AnalysisSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    var darkFrame: [Float]? {
        lock.withLock { _darkFrame }
    }

    var hasDarkFrame: Bool {
        lock.withLock { _darkFrame != nil }
    }

    func clearDarkFrame() {
        lock.withLock {
            _darkFrame = nil
            darkAccumulator = nil
            darkFramesRemaining = 0
        }
    }

    /// Averages `count` frames into a dark reference. Averaging beats a single frame
    /// because it drives the read-noise contribution down by √count, leaving the fixed
    /// pattern that actually matters.
    func beginDarkCapture(frames count: Int) {
        lock.withLock {
            darkAccumulator = nil
            darkFramesRemaining = count
            darkFrameTotal = count
        }
    }

    func submit(_ frame: BeamFrame) {
        lock.lock()
        _received += 1
        if _frozen {
            lock.unlock()
            return
        }
        if busy {
            _dropped += 1
            lock.unlock()
            return
        }
        busy = true
        let settings = _settings
        let dark = _darkFrame
        let collectingDark = darkFramesRemaining > 0
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }

            if collectingDark {
                self.accumulateDark(frame)
                self.lock.withLock { self.busy = false }
                return
            }

            let metrics = BeamAnalyzer.analyze(
                frame: frame, settings: settings, darkFrame: dark)
            self.onResult?(frame, metrics)
            self.lock.withLock {
                self.busy = false
                self._analysed += 1
            }
        }
    }

    private func accumulateDark(_ frame: BeamFrame) {
        lock.lock()
        if darkAccumulator == nil || darkAccumulator?.count != frame.pixels.count {
            darkAccumulator = [Double](repeating: 0, count: frame.pixels.count)
            darkFramesRemaining = darkFrameTotal
        }
        for i in 0..<frame.pixels.count {
            darkAccumulator![i] += Double(frame.pixels[i])
        }
        darkFramesRemaining -= 1
        let remaining = darkFramesRemaining
        let total = darkFrameTotal

        var finished = false
        if remaining <= 0, let accumulator = darkAccumulator {
            _darkFrame = accumulator.map { Float($0 / Double(total)) }
            darkAccumulator = nil
            finished = true
        }
        lock.unlock()

        onDarkFrameProgress?(total - remaining, total)
        if finished { onDarkFrameReady?() }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
