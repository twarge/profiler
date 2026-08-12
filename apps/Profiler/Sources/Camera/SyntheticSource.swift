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
    /// Fraction of full scale the beam peak would reach at the reference ISO.
    var referenceAmplitude = 0.02
    private let referenceISO = 800.0

    private let width = 1024
    private let height = 680
    private var iso: Int = 800
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "synthetic.source")
    private var startTime = Date()
    private var rngState: UInt64 = 0x2545_F491_4F6C_DD1D

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

    /// Box–Muller on a xorshift stream. Fast enough to run per pixel at 30 fps.
    private func gaussianNoise() -> Double {
        let u1 = max(1e-12, nextUniform())
        let u2 = nextUniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    private func nextUniform() -> Double {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return Double(rngState >> 11) / Double(1 << 53)
    }
}
