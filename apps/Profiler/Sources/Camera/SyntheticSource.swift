import Foundation

/// A simulated elliptical Gaussian beam with realistic gain, noise and drift.
///
/// This exists to validate the analyser against known ground truth: the true width,
/// ellipticity and angle are set here and displayed alongside the measured values,
/// so any bias in the moment calculation is directly visible. It also exercises the
/// auto-gain servo without needing a camera or a laser.
final class SyntheticSource: FrameSource {

    struct Truth {
        var waistX: Double = 90      // 1/e² radius in pixels
        var waistY: Double = 55
        var angleDegrees: Double = 22
        var centerX: Double = 512
        var centerY: Double = 340
        var driftAmplitude: Double = 6
        var driftPeriod: Double = 11  // seconds

        var d4SigmaX: Double { 2 * waistX }
        var d4SigmaY: Double { 2 * waistY }
        /// Ellipticity of the rotated ellipse, matching the analyser's major/minor convention.
        var ellipticity: Double { min(waistX, waistY) / max(waistX, waistY) }
        /// Major-axis azimuth, lab convention.
        var majorAngle: Double {
            let raw = waistX >= waistY ? angleDegrees : angleDegrees + 90
            var d = raw
            while d <= -90 { d += 180 }
            while d > 90 { d -= 180 }
            return d
        }
    }

    let displayName = "Synthetic beam"
    var onFrame: ((BeamFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var measurementChannel: MeasurementChannel = .green

    var truth = Truth()
    /// Fraction of full scale the beam peak reaches at the reference ISO.
    ///
    /// Sits a little under the servo's 70% target, so the simulated beam is properly
    /// exposed the moment it starts — visible without touching display gain — while the
    /// auto-gain loop still has somewhere to move.
    var referenceAmplitude = 0.55
    private let referenceISO = 800.0

    private let width = 1024
    private let height = 680
    private var iso: Int = 800
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "synthetic.source")
    private var startTime = Date()

    private let isoLadder: [Int] = [
        100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000,
        2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 51200,
    ]

    func start() async throws {
        startTime = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.emit() }
        timer = t
        t.resume()
        onStatus?("Synthetic source running at 30 fps.")
    }

    func stop() async {
        timer?.cancel()
        timer = nil
    }

    func gainState() async -> GainState {
        GainState(
            canReadISO: true,
            canSetISO: true,
            currentISO: iso,
            availableISO: isoLadder,
            shutterLabel: "1/60s",
            apertureLabel: "—",
            advisoryOnly: false,
            note: "Simulated sensor."
        )
    }

    func setISO(_ value: Int) async throws {
        iso = isoLadder.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    // MARK: - Generation

    private func emit() {
        let elapsed = Date().timeIntervalSince(startTime)
        let phase = 2 * Double.pi * elapsed / truth.driftPeriod
        let cx = truth.centerX + truth.driftAmplitude * cos(phase)
        let cy = truth.centerY + truth.driftAmplitude * sin(phase * 0.7)

        let theta = -truth.angleDegrees * .pi / 180  // lab CCW → image coords
        let cosT = cos(theta)
        let sinT = sin(theta)

        let gain = Double(iso) / referenceISO
        let amplitude = referenceAmplitude * gain
        let readNoise = 0.0016 * (0.4 + 0.6 * gain)

        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let dy = Double(y) - cy
            for x in 0..<width {
                let dx = Double(x) - cx
                let u = dx * cosT + dy * sinT
                let v = -dx * sinT + dy * cosT
                let exponent = -2 * (u * u / (truth.waistX * truth.waistX)
                    + v * v / (truth.waistY * truth.waistY))
                let signal = exponent > -50 ? amplitude * exp(exponent) : 0

                // Shot noise scales as √signal; read noise is additive.
                let noise = gaussianNoise() * (readNoise + 0.05 * signal.squareRoot())
                let value = signal + noise + 0.004
                pixels[y * width + x] = Float(max(0, min(1, value)))
            }
        }

        let frame = BeamFrame(width: width, height: height, pixels: pixels)
        onFrame?(frame)
    }

    /// Precomputed normal deviates.
    ///
    /// Box–Muller per pixel costs a log, a sqrt and a cos — 700k times per frame, which
    /// dominated the generator and starved the analyser. Drawing from a table with a
    /// coprime stride visits every entry before repeating and is indistinguishable from
    /// fresh deviates for a simulator.
    private static let noiseTable: [Double] = {
        var table = [Double](repeating: 0, count: 8192)
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s >> 11) / Double(1 << 53)
        }
        for i in 0..<table.count {
            let u1 = max(1e-12, next())
            let u2 = next()
            table[i] = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        return table
    }()

    private var noiseCursor = 0

    @inline(__always)
    private func gaussianNoise() -> Double {
        noiseCursor = (noiseCursor &+ 4099) & 8191
        return Self.noiseTable[noiseCursor]
    }
}
