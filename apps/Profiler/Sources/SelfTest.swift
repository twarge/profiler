import Foundation

/// Validates the ISO 11146 moment calculation against analytically-known beams.
///
/// Run with `make test`, or `Profiler --self-test`. Every case builds a rotated elliptical Gaussian
/// whose true D4σ, ellipticity and azimuth are known in closed form, then checks what the
/// analyser recovers. This is the regression test for the measurement core — if the
/// convention for the angle or the aperture iteration ever breaks, this catches it.
enum SelfTest {

    struct Case {
        var name: String
        var waistX: Double      // 1/e² radius along the beam's own x axis, pixels
        var waistY: Double
        var angleDegrees: Double  // lab convention: CCW positive, y up
        var centerX: Double
        var centerY: Double
        var amplitude: Double
        var noiseSigma: Double
        var pedestal: Double
    }

    static func run() -> Int32 {
        let cases: [Case] = [
            Case(name: "Circular, centred, noiseless",
                 waistX: 80, waistY: 80, angleDegrees: 0,
                 centerX: 512, centerY: 340, amplitude: 0.8,
                 noiseSigma: 0, pedestal: 0),
            Case(name: "Elliptical 2:1 at 0°",
                 waistX: 120, waistY: 60, angleDegrees: 0,
                 centerX: 512, centerY: 340, amplitude: 0.7,
                 noiseSigma: 0, pedestal: 0),
            Case(name: "Elliptical 2:1 at +30°",
                 waistX: 120, waistY: 60, angleDegrees: 30,
                 centerX: 500, centerY: 330, amplitude: 0.7,
                 noiseSigma: 0, pedestal: 0),
            Case(name: "Elliptical 2:1 at -40°",
                 waistX: 110, waistY: 55, angleDegrees: -40,
                 centerX: 520, centerY: 360, amplitude: 0.7,
                 noiseSigma: 0, pedestal: 0),
            Case(name: "Off-centre, noisy, with pedestal",
                 waistX: 70, waistY: 45, angleDegrees: 15,
                 centerX: 380, centerY: 250, amplitude: 0.55,
                 noiseSigma: 0.004, pedestal: 0.02),
        ]

        let width = 1024
        let height = 680
        var failures = 0

        print("")
        print("Beam analyser self-test — \(width)×\(height) synthetic frames")
        print(String(repeating: "─", count: 78))

        for testCase in cases {
            let frame = generate(testCase, width: width, height: height)
            var settings = AnalysisSettings()
            settings.micronsPerPixel = 1.0
            settings.subtractDarkFrame = false
            let metrics = BeamAnalyzer.analyze(frame: frame, settings: settings)

            let trueD4X = 2 * testCase.waistX
            let trueD4Y = 2 * testCase.waistY
            let trueMajor = 2 * max(testCase.waistX, testCase.waistY)
            let trueMinor = 2 * min(testCase.waistX, testCase.waistY)
            let trueEllipticity = trueMinor / trueMajor
            var trueAngle = testCase.waistX >= testCase.waistY
                ? testCase.angleDegrees
                : testCase.angleDegrees + 90
            while trueAngle <= -90 { trueAngle += 180 }
            while trueAngle > 90 { trueAngle -= 180 }

            // For a rotated ellipse the lab-frame marginal widths are not the beam's own
            // waists; derive the expected projections from the covariance matrix.
            let (expectedD4X, expectedD4Y) = projectedWidths(testCase)

            print("")
            print(testCase.name)
            var localFailures = 0
            localFailures += check("D4σ X", metrics.d4SigmaX, expectedD4X, tolerance: 0.02, relative: true)
            localFailures += check("D4σ Y", metrics.d4SigmaY, expectedD4Y, tolerance: 0.02, relative: true)
            localFailures += check("Major", metrics.majorDiameter, trueMajor, tolerance: 0.02, relative: true)
            localFailures += check("Minor", metrics.minorDiameter, trueMinor, tolerance: 0.02, relative: true)
            localFailures += check("Ellipticity", metrics.ellipticity, trueEllipticity, tolerance: 0.02, relative: true)
            localFailures += check("Centroid X", metrics.centroidX, testCase.centerX, tolerance: 1.0, relative: false)
            localFailures += check("Centroid Y", metrics.centroidY, testCase.centerY, tolerance: 1.0, relative: false)

            // Angle is meaningless for a circular beam, so only check it when elliptical.
            if abs(testCase.waistX - testCase.waistY) > 1 {
                localFailures += checkAngle("Angle", metrics.angleDegrees, trueAngle, tolerance: 1.0)
            }

            // The Gaussian fit should agree with the moment width for a true Gaussian.
            if let fit = metrics.fitX {
                localFailures += check(
                    "Fit 2w X", fit.d4SigmaEquivalent, expectedD4X, tolerance: 0.04, relative: true)
            }

            failures += localFailures
            print("  \(localFailures == 0 ? "PASS" : "FAIL (\(localFailures) checks)")")
        }

        print("")
        print(String(repeating: "─", count: 78))
        if failures == 0 {
            print("All checks passed.")
        } else {
            print("\(failures) check(s) failed.")
        }
        print("")
        return failures == 0 ? 0 : 1
    }

    /// Marginal (lab-axis) D4σ widths for a rotated elliptical Gaussian.
    ///
    /// σ_xx = σ_u²cos²θ + σ_v²sin²θ with σ = w/2, and D4σ_x = 4√σ_xx.
    private static func projectedWidths(_ c: Case) -> (Double, Double) {
        let sigmaU = c.waistX / 2
        let sigmaV = c.waistY / 2
        let theta = c.angleDegrees * .pi / 180
        let cosT = cos(theta)
        let sinT = sin(theta)
        let sxx = sigmaU * sigmaU * cosT * cosT + sigmaV * sigmaV * sinT * sinT
        let syy = sigmaU * sigmaU * sinT * sinT + sigmaV * sigmaV * cosT * cosT
        return (4 * sxx.squareRoot(), 4 * syy.squareRoot())
    }

    private static func generate(_ c: Case, width: Int, height: Int) -> BeamFrame {
        // Lab angle → image angle: image rows run downward.
        let theta = -c.angleDegrees * .pi / 180
        let cosT = cos(theta)
        let sinT = sin(theta)
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        var pixels = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            let dy = Double(y) - c.centerY
            for x in 0..<width {
                let dx = Double(x) - c.centerX
                let u = dx * cosT + dy * sinT
                let v = -dx * sinT + dy * cosT
                let exponent = -2 * (u * u / (c.waistX * c.waistX)
                    + v * v / (c.waistY * c.waistY))
                var value = exponent > -60 ? c.amplitude * exp(exponent) : 0
                value += c.pedestal
                if c.noiseSigma > 0 {
                    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                    let u1 = max(1e-12, Double(rng >> 11) / Double(1 << 53))
                    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                    let u2 = Double(rng >> 11) / Double(1 << 53)
                    value += (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2) * c.noiseSigma
                }
                pixels[y * width + x] = Float(max(0, min(1, value)))
            }
        }
        return BeamFrame(width: width, height: height, pixels: pixels)
    }

    private static func check(
        _ name: String, _ measured: Double, _ expected: Double,
        tolerance: Double, relative: Bool
    ) -> Int {
        let error = relative
            ? abs(measured - expected) / max(abs(expected), 1e-12)
            : abs(measured - expected)
        let ok = error <= tolerance
        let errorText = relative
            ? String(format: "%+.2f%%", (measured - expected) / max(abs(expected), 1e-12) * 100)
            : String(format: "%+.3f px", measured - expected)
        print(String(
            format: "  %-12@ measured %10.3f  expected %10.3f  %@  %@",
            name as NSString, measured, expected, errorText as NSString,
            (ok ? "ok" : "OUT OF TOLERANCE") as NSString))
        return ok ? 0 : 1
    }

    private static func checkAngle(
        _ name: String, _ measured: Double, _ expected: Double, tolerance: Double
    ) -> Int {
        // Axis azimuth is defined modulo 180°.
        var delta = measured - expected
        while delta <= -90 { delta += 180 }
        while delta > 90 { delta -= 180 }
        let ok = abs(delta) <= tolerance
        print(String(
            format: "  %-12@ measured %10.3f  expected %10.3f  %+.3f°  %@",
            name as NSString, measured, expected, delta,
            (ok ? "ok" : "OUT OF TOLERANCE") as NSString))
        return ok ? 0 : 1
    }
}
