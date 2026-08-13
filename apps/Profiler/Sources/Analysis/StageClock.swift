import Foundation

/// Per-stage timing for the analyser, used by `--benchmark`.
///
/// Frame rate is a feature of an instrument, not an implementation detail: a beam profiler
/// that drops four frames in five is showing the operator a stale beam. So the analyser
/// carries a permanent way to ask where its time goes, rather than requiring a profiler
/// and a hand-built harness every time that question comes up.
///
/// When no recorder is installed — which is always, outside the benchmark — the cost is one
/// nil check per stage, not per pixel.
struct StageClock {
    /// Installed by the benchmark. Receives a stage name and its duration in milliseconds.
    nonisolated(unsafe) static var recorder: ((String, Double) -> Void)?

    private let recording: Bool
    private var last: UInt64

    init() {
        recording = Self.recorder != nil
        last = recording ? DispatchTime.now().uptimeNanoseconds : 0
    }

    /// Attributes everything since the previous mark to `name`.
    mutating func mark(_ name: String) {
        guard recording else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        Self.recorder?(name, Double(now &- last) / 1_000_000)
        last = now
    }
}
