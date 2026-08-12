import Foundation

/// Levenberg–Marquardt fit of I(x) = A·exp(-2(x-x₀)²/w²) + C to a 1-D profile.
///
/// The fit is reported alongside the second-moment width because the two disagree in
/// informative ways: a clean TEM₀₀ beam gives 2w ≈ D4σ, while a beam with wings or a
/// flat top gives D4σ > 2w. ISO 11146 mandates the second moment; the fit is diagnostic.
enum GaussianFit {

    struct Result {
        var amplitude: Double
        var center: Double
        /// 1/e² radius in pixels.
        var waistRadius: Double
        var offset: Double
        var rSquared: Double
        var converged: Bool

        /// Diameter comparable to D4σ for an ideal Gaussian.
        var d4SigmaEquivalent: Double { 2 * waistRadius }
        var fwhm: Double { waistRadius * (2 * log(2)).squareRoot() }
    }

    /// - Parameters:
    ///   - profile: sampled intensities, index = pixel coordinate.
    ///   - seedCenter: initial centroid guess in pixels.
    ///   - seedWidth: initial 1/e² radius guess in pixels.
    static func fit(
        profile: [Float],
        seedCenter: Double,
        seedWidth: Double,
        maxIterations: Int = 60
    ) -> Result? {
        let n = profile.count
        guard n >= 8 else { return nil }

        let values = profile.map { Double($0) }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        guard maxValue > minValue else { return nil }

        // p = [A, x0, w, C]
        var p: [Double] = [
            maxValue - minValue,
            seedCenter.isFinite ? seedCenter : Double(n) / 2,
            max(1.0, seedWidth.isFinite ? seedWidth : Double(n) / 8),
            minValue,
        ]

        var lambda = 1e-3
        var previousCost = cost(values, p)
        var converged = false

        for _ in 0..<maxIterations {
            var jtj = [Double](repeating: 0, count: 16)
            var jtr = [Double](repeating: 0, count: 4)

            let w = p[2]
            guard w != 0 else { break }

            for i in 0..<n {
                let x = Double(i)
                let u = x - p[1]
                let e = exp(-2 * u * u / (w * w))
                let model = p[0] * e + p[3]
                let residual = values[i] - model

                let j0 = e
                let j1 = p[0] * e * (4 * u / (w * w))
                let j2 = p[0] * e * (4 * u * u / (w * w * w))
                let j3 = 1.0
                let j = [j0, j1, j2, j3]

                for a in 0..<4 {
                    jtr[a] += j[a] * residual
                    for b in 0..<4 { jtj[a * 4 + b] += j[a] * j[b] }
                }
            }

            var stepTaken = false
            for _ in 0..<12 {
                var augmented = jtj
                for d in 0..<4 { augmented[d * 4 + d] *= (1 + lambda) }

                guard let delta = solve4x4(augmented, jtr) else {
                    lambda *= 10
                    continue
                }

                var candidate = p
                for a in 0..<4 { candidate[a] += delta[a] }
                candidate[2] = abs(candidate[2])

                guard candidate.allSatisfy({ $0.isFinite }), candidate[2] > 0.25 else {
                    lambda *= 10
                    continue
                }

                let candidateCost = cost(values, candidate)
                if candidateCost < previousCost {
                    let improvement = (previousCost - candidateCost) / max(previousCost, 1e-30)
                    p = candidate
                    previousCost = candidateCost
                    lambda = max(lambda / 10, 1e-12)
                    stepTaken = true
                    if improvement < 1e-8 { converged = true }
                    break
                } else {
                    lambda *= 10
                }
            }

            if !stepTaken || converged { converged = converged || !stepTaken; break }
        }

        let mean = values.reduce(0, +) / Double(n)
        let totalSS = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let rSquared = totalSS > 0 ? max(0, 1 - previousCost / totalSS) : 0

        guard p.allSatisfy({ $0.isFinite }), p[2] > 0 else { return nil }

        return Result(
            amplitude: p[0],
            center: p[1],
            waistRadius: p[2],
            offset: p[3],
            rSquared: rSquared,
            converged: converged
        )
    }

    private static func cost(_ values: [Double], _ p: [Double]) -> Double {
        let w = p[2]
        guard w != 0 else { return .infinity }
        var sum = 0.0
        for i in 0..<values.count {
            let u = Double(i) - p[1]
            let model = p[0] * exp(-2 * u * u / (w * w)) + p[3]
            let r = values[i] - model
            sum += r * r
        }
        return sum
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve4x4(_ a: [Double], _ b: [Double]) -> [Double]? {
        var m = a
        var v = b

        for col in 0..<4 {
            var pivot = col
            var best = abs(m[col * 4 + col])
            for row in (col + 1)..<4 {
                let candidate = abs(m[row * 4 + col])
                if candidate > best { best = candidate; pivot = row }
            }
            guard best > 1e-18 else { return nil }

            if pivot != col {
                for k in 0..<4 { m.swapAt(col * 4 + k, pivot * 4 + k) }
                v.swapAt(col, pivot)
            }

            let diagonal = m[col * 4 + col]
            for row in (col + 1)..<4 {
                let factor = m[row * 4 + col] / diagonal
                guard factor != 0 else { continue }
                for k in col..<4 { m[row * 4 + k] -= factor * m[col * 4 + k] }
                v[row] -= factor * v[col]
            }
        }

        var x = [Double](repeating: 0, count: 4)
        for row in stride(from: 3, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<4 { sum -= m[row * 4 + k] * x[k] }
            let diagonal = m[row * 4 + row]
            guard abs(diagonal) > 1e-18 else { return nil }
            x[row] = sum / diagonal
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }

    /// Width between half-maximum crossings, interpolated, measured directly from the data.
    /// Independent of any fit, so it stays meaningful for non-Gaussian beams.
    static func measuredFWHM(profile: [Float]) -> Double? {
        guard profile.count >= 3 else { return nil }
        let values = profile.map { Double($0) }
        guard let peak = values.max(), let floor = values.min(), peak > floor else { return nil }
        let half = floor + (peak - floor) / 2
        guard let peakIndex = values.firstIndex(of: peak) else { return nil }

        var left: Double?
        var i = peakIndex
        while i > 0 {
            if values[i - 1] <= half, values[i] >= half {
                let span = values[i] - values[i - 1]
                left = Double(i - 1) + (span > 0 ? (half - values[i - 1]) / span : 0)
                break
            }
            i -= 1
        }

        var right: Double?
        var j = peakIndex
        while j < values.count - 1 {
            if values[j] >= half, values[j + 1] <= half {
                let span = values[j] - values[j + 1]
                right = Double(j) + (span > 0 ? (values[j] - half) / span : 0)
                break
            }
            j += 1
        }

        guard let l = left, let r = right, r > l else { return nil }
        return r - l
    }
}
