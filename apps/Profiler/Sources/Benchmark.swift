import CoreGraphics
import Foundation

/// Measures where a frame's time goes, stage by stage.
///
/// Run with `make bench`, or `Profiler --benchmark`. The analyser runs on a frame the
/// self-test already validates, so a speed change and a correctness change are measured
/// against the same beam.
///
/// The display and capture sections are listed separately because they are not on the
/// analyser's thread: rendering happens on the main actor and conversion on the capture
/// thread, so they compete for cores with analysis rather than adding to its latency.
enum Benchmark {

    static func run() -> Int32 {
        let width = 1024
        let height = 680
        let iterations = 30

        let testCase = SelfTest.Case(
            name: "Elliptical 2:1 at +30°",
            waistX: 120, waistY: 60, angleDegrees: 30,
            centerX: 500, centerY: 330, amplitude: 0.7,
            noiseSigma: 0.004, pedestal: 0.02
        )
        let frame = SelfTest.generate(testCase, width: width, height: height)

        var settings = AnalysisSettings()
        settings.micronsPerPixel = 1.0
        settings.subtractDarkFrame = false

        print("")
        print("Analyser benchmark — \(width)×\(height), \(iterations) iterations")
        print(String(repeating: "─", count: 78))

        // Warm up, so first-touch page faults and any lazy initialisation are not
        // attributed to whichever stage happens to run first.
        for _ in 0..<3 {
            _ = BeamAnalyzer.analyze(frame: frame, settings: settings)
        }

        var totals: [String: Double] = [:]
        var order: [String] = []
        StageClock.recorder = { name, milliseconds in
            if totals[name] == nil { order.append(name) }
            totals[name, default: 0] += milliseconds
        }

        let analyseTotal = time(iterations) {
            _ = BeamAnalyzer.analyze(frame: frame, settings: settings)
        }
        StageClock.recorder = nil

        let stageSum = totals.values.reduce(0, +) / Double(iterations)
        print("")
        print(pad("Stage", 34) + pad("mean ms", 12) + "share")
        print(String(repeating: "─", count: 78))
        for name in order.sorted(by: { totals[$0]! > totals[$1]! }) {
            let mean = totals[name]! / Double(iterations)
            print(pad(name, 34)
                + pad(String(format: "%.2f", mean), 12)
                + String(format: "%.1f%%", 100 * mean / max(stageSum, 1e-9)))
        }
        print(String(repeating: "─", count: 78))
        print(pad("analyse total", 34)
            + pad(String(format: "%.2f", analyseTotal), 12)
            + String(format: "→ %.1f fps", 1000 / max(analyseTotal, 1e-9)))

        // --- Off the analyser's thread ---------------------------------------------
        // The live lane is what bounds the displayed frame rate: image render plus raw
        // profiles, per frame, concurrent with the analysis above.
        let image = BeamImageRenderer.makeImage(frame: frame, colormap: .inferno)
        let renderTime = time(iterations) {
            _ = BeamImageRenderer.makeImage(frame: frame, colormap: .inferno)
        }
        let quickTime = time(iterations) {
            _ = BeamAnalyzer.quickProfiles(frame: frame)
        }

        var convertTime = 0.0
        if let image {
            convertTime = time(iterations) {
                _ = FrameConverter.beamFrame(from: image, channel: .green)
            }
        }

        print("")
        print("Off the analyser's thread")
        print(String(repeating: "─", count: 78))
        print(pad("colormap render (live lane)", 34)
            + pad(String(format: "%.2f", renderTime), 12)
            + String(format: "→ %.1f fps", 1000 / max(renderTime, 1e-9)))
        print(pad("raw profiles (live lane)", 34)
            + pad(String(format: "%.2f", quickTime), 12)
            + String(format: "→ %.1f fps", 1000 / max(quickTime, 1e-9)))
        print(pad("live lane total", 34)
            + pad(String(format: "%.2f", renderTime + quickTime), 12)
            + String(format: "→ %.1f fps", 1000 / max(renderTime + quickTime, 1e-9)))
        print(pad("frame conversion (capture)", 34)
            + pad(String(format: "%.2f", convertTime), 12)
            + String(format: "→ %.1f fps", 1000 / max(convertTime, 1e-9)))
        print("")

        return 0
    }

    /// Mean wall-clock milliseconds per iteration.
    private static func time(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000 / Double(iterations)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
