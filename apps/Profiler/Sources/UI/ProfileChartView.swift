import SwiftUI

/// Integrated beam profile with the Gaussian fit overlaid.
///
/// Drawn with Canvas rather than Swift Charts: these are 1000–2000 point series redrawn
/// at the frame rate, which Charts is not built for.
struct ProfileChartView: View {

    enum Orientation {
        /// Profile along x, plotted left to right. Sits above the image with its baseline on
        /// the lower edge, so the curve grows away from the picture.
        case horizontal
        /// Profile along y, plotted top to bottom to align with the image rows. Sits to the
        /// right of the image with its baseline on the left edge.
        case vertical
    }

    var profile: [Float]
    var fit: GaussianFit.Result?
    var centroid: Double
    var d4Sigma: Double
    var orientation: Orientation
    /// Full-scale value for the amplitude axis. Both charts are given the same number so
    /// their heights are directly comparable — with each normalised to its own peak, a
    /// round beam and a 2:1 elliptical one look identical.
    var amplitudeMax: Double?

    var body: some View {
        Canvas { context, size in
            guard profile.count > 1 else { return }
            let maxValue = amplitudeMax ?? (profile.max().map(Double.init) ?? 0)
            guard maxValue > 0 else { return }

            let n = profile.count
            // The pane is sized to the image's fitted extent by the layout, so the profile
            // spans the full pane and registers with the picture by construction.
            let span = orientation == .horizontal ? size.width : size.height

            // Position along the profile axis; amplitude perpendicular to it.
            // Sampled at pixel centres so the mapping matches how the image is drawn.
            func position(_ index: Double) -> CGFloat {
                CGFloat((index + 0.5) / Double(n)) * span
            }
            func amplitude(_ value: Double) -> CGFloat {
                let t = value / maxValue
                return orientation == .horizontal
                    ? size.height - CGFloat(t) * (size.height - 2) - 0.5
                    : CGFloat(t) * (size.width - 2) + 0.5
            }
            func point(_ index: Double, _ value: Double) -> CGPoint {
                orientation == .horizontal
                    ? CGPoint(x: position(index), y: amplitude(value))
                    : CGPoint(x: amplitude(value), y: position(index))
            }

            // Baseline along the image edge the chart sits against.
            var baseline = Path()
            if orientation == .horizontal {
                baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
                baseline.addLine(to: CGPoint(x: span, y: size.height - 0.5))
            } else {
                baseline.move(to: CGPoint(x: 0.5, y: 0))
                baseline.addLine(to: CGPoint(x: 0.5, y: span))
            }
            context.stroke(baseline, with: .color(.primary.opacity(0.2)), lineWidth: 1)

            // Measured profile
            var curve = Path()
            // Subsample when the series is longer than the pixels available to draw it.
            let step = max(1, Int(Double(n) / Double(max(1, Int(span)))))
            var first = true
            for i in stride(from: 0, to: n, by: step) {
                let p = point(Double(i), Double(profile[i]))
                if first { curve.move(to: p); first = false } else { curve.addLine(to: p) }
            }
            // Primary label colour: black data on the light window ground, white on dark.
            context.stroke(curve, with: .color(.primary), lineWidth: 1.4)

            // Gaussian fit
            if let fit, fit.waistRadius > 0 {
                var fitted = Path()
                var started = false
                for i in stride(from: 0, to: n, by: step) {
                    let u = Double(i) - fit.center
                    let value = fit.amplitude
                        * exp(-2 * u * u / (fit.waistRadius * fit.waistRadius)) + fit.offset
                    let p = point(Double(i), max(0, value))
                    if !started { fitted.move(to: p); started = true } else { fitted.addLine(to: p) }
                }
                // The system highlight colour, as the ellipse is: what is drawn in it is
                // what the app derived, against the measured data in the primary colour.
                context.stroke(
                    fitted,
                    with: .color(.accentColor),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
        }
    }
}
