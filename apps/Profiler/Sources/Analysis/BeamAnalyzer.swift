import Foundation

struct AnalysisSettings {
    /// Physical size of one pixel in the measurement plane.
    var micronsPerPixel: Double = 5.94
    /// Pixels below (background + k·σ) are zeroed before taking moments. ISO 11146-3 calls
    /// for baseline correction; without it the second moment is dominated by sensor noise
    /// integrated over the whole frame.
    var noiseSigmaMultiplier: Double = 3.0
    /// Integration aperture size as a multiple of the measured beam diameter.
    /// ISO 11146-1 recommends approximately 3.
    var apertureFactor: Double = 3.0
    var maxIterations: Int = 8
    var convergenceTolerance: Double = 0.005
    var subtractDarkFrame: Bool = true
    /// Restricts analysis to a user-drawn region. Nil means start from the full frame.
    var userROI: Aperture?
    var channel: MeasurementChannel = .green
}

struct BeamMetrics {
    // Position and size, in pixels. Convert with `micronsPerPixel`.
    var centroidX: Double = 0
    var centroidY: Double = 0
    var d4SigmaX: Double = 0
    var d4SigmaY: Double = 0
    var majorDiameter: Double = 0
    var minorDiameter: Double = 0

    /// d_minor / d_major, in 0...1. ISO 11146 treats a beam as circular above 0.87.
    var ellipticity: Double = 1
    /// Major-axis azimuth in degrees, CCW positive from the horizontal, in lab convention
    /// (y up). Normalised to (-90, 90].
    var angleDegrees: Double = 0

    var peak: Double = 0
    var totalPower: Double = 0
    var backgroundMean: Double = 0
    var backgroundSigma: Double = 0
    var saturatedPixels: Int = 0
    var saturatedFraction: Double = 0

    var aperture: Aperture = Aperture(x0: 0, y0: 0, x1: 0, y1: 0)
    var converged: Bool = false
    var iterations: Int = 0
    var hasBeam: Bool = false

    var profileX: [Float] = []
    var profileY: [Float] = []
    var fitX: GaussianFit.Result?
    var fitY: GaussianFit.Result?
    var measuredFWHMX: Double?
    var measuredFWHMY: Double?

    var isCircular: Bool { ellipticity > 0.87 }

    /// Saturation invalidates the second moment: clipped pixels remove exactly the
    /// high-intensity core that dominates the ∑I·r² sum, biasing every width low.
    var isSaturated: Bool { saturatedFraction > 0.001 }
}

enum BeamAnalyzer {

    static func analyze(
        frame: BeamFrame,
        settings: AnalysisSettings,
        darkFrame: [Float]? = nil
    ) -> BeamMetrics {
        var metrics = BeamMetrics()
        let w = frame.width
        let h = frame.height
        guard w > 4, h > 4, frame.pixels.count == w * h else { return metrics }

        // --- Saturation and peak, measured on the raw frame -------------------------
        var saturated = 0
        var histogram = [Int](repeating: 0, count: 1024)
        for v in frame.pixels {
            if v >= 0.99 { saturated += 1 }
            let bin = min(1023, max(0, Int(v * 1023)))
            histogram[bin] += 1
        }
        metrics.saturatedPixels = saturated
        metrics.saturatedFraction = Double(saturated) / Double(frame.count)
        metrics.peak = robustPeak(histogram: histogram, total: frame.count)

        // --- Background estimate ----------------------------------------------------
        var subtracted = frame.pixels
        if settings.subtractDarkFrame, let dark = darkFrame, dark.count == subtracted.count {
            for i in 0..<subtracted.count { subtracted[i] -= dark[i] }
        }

        let (bgMean, bgSigma) = estimateBackground(subtracted, width: w, height: h)
        metrics.backgroundMean = Double(bgMean)
        metrics.backgroundSigma = Double(bgSigma)

        // Two buffers with distinct jobs.
        //
        // `subtracted` has only the baseline removed, so noise stays symmetric about zero
        // and the beam keeps its true wings. All reported moments come from this.
        //
        // `masked` is hard-clipped below the noise floor and is used *only* to locate the
        // beam and size the integration aperture. Computing moments on clipped data biases
        // every width low: a 3σ cut on a beam whose noise floor sits at 5% of peak truncates
        // the Gaussian near 1.2w and costs about 9% of D4σ.
        let threshold = Float(settings.noiseSigmaMultiplier) * bgSigma
        var masked = [Float](repeating: 0, count: subtracted.count)
        for i in 0..<subtracted.count {
            let v = subtracted[i] - bgMean
            subtracted[i] = v
            masked[i] = v > threshold ? v - threshold : 0
        }

        // --- Iterative aperture, per ISO 11146 --------------------------------------
        let roi = settings.userROI?.clamped(toWidth: w, height: h)
        var aperture = roi ?? Aperture.full(width: w, height: h)
        var previous: Moments?
        var iterations = 0
        var converged = false

        func apertureAround(_ m: Moments, limit: Aperture?) -> Aperture? {
            let halfWidth = max(4.0, settings.apertureFactor * m.d4x / 2)
            let halfHeight = max(4.0, settings.apertureFactor * m.d4y / 2)
            var next = Aperture(
                x0: Int((m.cx - halfWidth).rounded(.down)),
                y0: Int((m.cy - halfHeight).rounded(.down)),
                x1: Int((m.cx + halfWidth).rounded(.up)),
                y1: Int((m.cy + halfHeight).rounded(.up))
            ).clamped(toWidth: w, height: h)

            // A user ROI is a hard boundary; never expand past it.
            for bound in [roi, limit].compactMap({ $0 }) {
                next = Aperture(
                    x0: max(next.x0, bound.x0), y0: max(next.y0, bound.y0),
                    x1: min(next.x1, bound.x1), y1: min(next.y1, bound.y1)
                )
            }
            return next.isEmpty ? nil : next
        }

        var foundSignal = false
        for _ in 0..<max(1, settings.maxIterations) {
            iterations += 1
            guard let m = moments(masked, width: w, height: h, aperture: aperture) else { break }
            foundSignal = true

            if let p = previous {
                let scale = max(m.d4x, m.d4y, 1)
                let centroidShift = max(abs(m.cx - p.cx), abs(m.cy - p.cy)) / scale
                let widthChange = max(
                    abs(m.d4x - p.d4x) / max(p.d4x, 1e-9),
                    abs(m.d4y - p.d4y) / max(p.d4y, 1e-9)
                )
                if centroidShift < settings.convergenceTolerance,
                   widthChange < settings.convergenceTolerance {
                    converged = true
                    break
                }
            }
            previous = m

            guard let next = apertureAround(m, limit: nil) else { break }
            aperture = next
        }

        // The clipped widths that sized this aperture are themselves biased low, so refine
        // it against the unclipped moments. Expansion is capped relative to the clipped
        // aperture so a bad baseline estimate can't run the aperture away to the frame edge.
        let expansionLimit = Aperture(
            x0: aperture.x0 - aperture.width, y0: aperture.y0 - aperture.height,
            x1: aperture.x1 + aperture.width, y1: aperture.y1 + aperture.height
        ).clamped(toWidth: w, height: h)

        var moment = moments(subtracted, width: w, height: h, aperture: aperture)
        for _ in 0..<3 {
            guard let m = moment, m.power > 0,
                  let next = apertureAround(m, limit: expansionLimit),
                  next != aperture
            else { break }
            iterations += 1
            aperture = next
            moment = moments(subtracted, width: w, height: h, aperture: aperture)
        }

        // Without anything above the noise floor there is no beam to measure. Falling
        // through here would return full-frame moments of the ambient scene, which look
        // like confident millimetre readings for what is actually nothing.
        guard foundSignal, let m = moment, m.power > 0 else {
            metrics.aperture = aperture
            metrics.iterations = iterations
            return metrics
        }

        metrics.hasBeam = true
        metrics.converged = converged
        metrics.iterations = iterations
        metrics.aperture = aperture
        metrics.centroidX = m.cx
        metrics.centroidY = m.cy
        metrics.d4SigmaX = m.d4x
        metrics.d4SigmaY = m.d4y
        metrics.totalPower = m.power

        // --- Principal axes ---------------------------------------------------------
        // ISO 11146-1:  d = 2√2 · { (σxx + σyy) ± [(σxx − σyy)² + 4σxy²]^½ }^½
        let discriminant = ((m.sxx - m.syy) * (m.sxx - m.syy) + 4 * m.sxy * m.sxy).squareRoot()
        let sum = m.sxx + m.syy
        let major = 2 * (2.0).squareRoot() * max(0, sum + discriminant).squareRoot()
        let minor = 2 * (2.0).squareRoot() * max(0, sum - discriminant).squareRoot()
        metrics.majorDiameter = major
        metrics.minorDiameter = minor
        metrics.ellipticity = major > 0 ? minor / major : 1

        // Image rows run downward, so the lab-frame azimuth is the negated image-frame one.
        let angleImage = 0.5 * atan2(2 * m.sxy, m.sxx - m.syy)
        var degrees = -angleImage * 180 / .pi
        while degrees <= -90 { degrees += 180 }
        while degrees > 90 { degrees -= 180 }
        metrics.angleDegrees = degrees

        // --- Marginal profiles ------------------------------------------------------
        // Integrated across the aperture in the perpendicular axis, but spanning the full
        // frame along the profile axis so the display shows the wings.
        var profileX = [Float](repeating: 0, count: w)
        for y in aperture.y0..<aperture.y1 {
            let row = y * w
            for x in 0..<w { profileX[x] += subtracted[row + x] }
        }
        var profileY = [Float](repeating: 0, count: h)
        for y in 0..<h {
            let row = y * w
            var sum: Float = 0
            for x in aperture.x0..<aperture.x1 { sum += subtracted[row + x] }
            profileY[y] = sum
        }
        metrics.profileX = profileX
        metrics.profileY = profileY

        metrics.fitX = GaussianFit.fit(
            profile: profileX, seedCenter: m.cx, seedWidth: max(1, m.d4x / 2))
        metrics.fitY = GaussianFit.fit(
            profile: profileY, seedCenter: m.cy, seedWidth: max(1, m.d4y / 2))
        metrics.measuredFWHMX = GaussianFit.measuredFWHM(profile: profileX)
        metrics.measuredFWHMY = GaussianFit.measuredFWHM(profile: profileY)

        return metrics
    }

    // MARK: - Internals

    private struct Moments {
        var power: Double
        var cx: Double
        var cy: Double
        var sxx: Double
        var syy: Double
        var sxy: Double
        var d4x: Double
        var d4y: Double
    }

    /// Two-pass central moments: centroid first, then spreads about it. Accumulating
    /// ∑I·x² and subtracting the mean squared loses precision when the beam sits far
    /// from the origin, which it usually does.
    private static func moments(
        _ buffer: [Float], width: Int, height: Int, aperture: Aperture
    ) -> Moments? {
        let a = aperture.clamped(toWidth: width, height: height)
        guard !a.isEmpty else { return nil }

        var power = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for y in a.y0..<a.y1 {
            let row = y * width
            var rowPower = 0.0
            var rowSumX = 0.0
            for x in a.x0..<a.x1 {
                let i = Double(buffer[row + x])
                // Negative samples are kept: after baseline subtraction the noise is
                // symmetric about zero, and discarding one sign would bias the result.
                if i == 0 { continue }
                rowPower += i
                rowSumX += i * Double(x)
            }
            power += rowPower
            sumX += rowSumX
            sumY += rowPower * Double(y)
        }
        guard power > 0 else { return nil }

        let cx = sumX / power
        let cy = sumY / power

        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for y in a.y0..<a.y1 {
            let row = y * width
            let dy = Double(y) - cy
            for x in a.x0..<a.x1 {
                let i = Double(buffer[row + x])
                if i == 0 { continue }
                let dx = Double(x) - cx
                sxx += i * dx * dx
                syy += i * dy * dy
                sxy += i * dx * dy
            }
        }
        sxx /= power
        syy /= power
        sxy /= power

        return Moments(
            power: power, cx: cx, cy: cy,
            sxx: sxx, syy: syy, sxy: sxy,
            d4x: 4 * max(0, sxx).squareRoot(),
            d4y: 4 * max(0, syy).squareRoot()
        )
    }

    /// Mean and standard deviation over four corner patches, which are assumed
    /// beam-free. If the beam fills the frame this over-estimates the baseline —
    /// the UI flags that case via the dark-frame control.
    private static func estimateBackground(
        _ buffer: [Float], width: Int, height: Int
    ) -> (mean: Float, sigma: Float) {
        let pw = max(8, width / 8)
        let ph = max(8, height / 8)
        let corners = [
            (0, 0), (width - pw, 0), (0, height - ph), (width - pw, height - ph),
        ]

        var sum = 0.0
        var sumSquares = 0.0
        var n = 0
        for (ox, oy) in corners {
            for y in max(0, oy)..<min(height, oy + ph) {
                let row = y * width
                for x in max(0, ox)..<min(width, ox + pw) {
                    let v = Double(buffer[row + x])
                    sum += v
                    sumSquares += v * v
                    n += 1
                }
            }
        }
        guard n > 1 else { return (0, 0) }
        let mean = sum / Double(n)
        let variance = max(0, sumSquares / Double(n) - mean * mean)
        return (Float(mean), Float(variance.squareRoot()))
    }

    /// 99.9th percentile rather than the true maximum, so one hot pixel doesn't
    /// drive the auto-gain servo.
    private static func robustPeak(histogram: [Int], total: Int) -> Double {
        guard total > 0 else { return 0 }
        let target = Int(Double(total) * 0.999)
        var running = 0
        for (bin, count) in histogram.enumerated() {
            running += count
            if running >= target { return Double(bin) / 1023.0 }
        }
        return 1.0
    }
}
