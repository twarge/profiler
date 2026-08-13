import CoreGraphics
import Foundation

/// What the live view needs to render a frame, snapshotted so the render can run off the
/// main actor without reading UI state.
struct DisplaySettings {
    var colormap: Colormap = .inferno
    var displayGain: Double = 1.0
    var logarithmic: Bool = false
}

/// Runs analysis off the main thread and drops frames rather than queueing them.
///
/// Two lanes, each latest-wins. The *live* lane renders the colormapped image and the raw
/// marginal profiles — one pass over the frame — so the picture tracks the capture rate.
/// The *analysis* lane runs the full ISO 11146 measurement and can lag behind; its results
/// overlay the live view when they land. Dropping rather than queueing keeps both lanes
/// honest about the present: a beam profiler wants the latest measurement, not every one.
final class AnalysisPipeline {

    private let queue = DispatchQueue(label: "beam.analysis", qos: .userInitiated)
    private let liveQueue = DispatchQueue(label: "beam.liveview", qos: .userInteractive)
    private let lock = NSLock()

    private var _settings = AnalysisSettings()
    private var _display = DisplaySettings()
    private var _darkFrame: [Float]?
    private var _frozen = false
    private var busy = false
    private var liveBusy = false

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
    /// Fires for every frame the live lane keeps up with: the rendered image and the raw
    /// marginal profiles, well before the measurement of the same beam exists.
    var onLiveView: ((CGImage?, [Float], [Float]) -> Void)?
    var onDarkFrameProgress: ((Int, Int) -> Void)?
    var onDarkFrameReady: (() -> Void)?

    var settings: AnalysisSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    var displaySettings: DisplaySettings {
        get { lock.withLock { _display } }
        set { lock.withLock { _display = newValue } }
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
        let settings = _settings
        let display = _display
        let dark = _darkFrame
        let collectingDark = darkFramesRemaining > 0

        let takeLive = !liveBusy
        if takeLive { liveBusy = true }
        let takeAnalysis = !busy
        if takeAnalysis { busy = true } else { _dropped += 1 }
        lock.unlock()

        if takeLive {
            liveQueue.async { [weak self] in
                guard let self else { return }
                let image = BeamImageRenderer.makeImage(
                    frame: frame,
                    colormap: display.colormap,
                    displayGain: display.displayGain,
                    logarithmic: display.logarithmic
                )
                let profiles = BeamAnalyzer.quickProfiles(
                    frame: frame, darkFrame: dark, subtractDark: settings.subtractDarkFrame)
                self.onLiveView?(image, profiles.x, profiles.y)
                self.lock.withLock { self.liveBusy = false }
            }
        }

        guard takeAnalysis else { return }
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
