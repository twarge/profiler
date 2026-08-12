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
    var label: String
    /// Where the image's drawn extent begins along this chart's profile axis, and how long
    /// it is. The image is aspect-fitted inside its pane, so without these the chart would
    /// spread the profile across the letterbox margins too and nothing would register with
    /// the picture above it.
    var plotStart: CGFloat = 0
    var plotLength: CGFloat?
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
            let span = plotLength ?? (orientation == .horizontal ? size.width : size.height)

            // Position along the profile axis; amplitude perpendicular to it.
            // Sampled at pixel centres so the mapping matches how the image is drawn.
            func position(_ index: Double) -> CGFloat {
                plotStart + CGFloat((index + 0.5) / Double(n)) * span
            }
            func amplitude(_ value: Double) -> CGFloat {
                let t = value / maxValue
                return orientation == .horizontal
                    ? size.height - CGFloat(t) * (size.height - 4) - 2
                    : CGFloat(t) * (size.width - 4) + 2
            }
            func point(_ index: Double, _ value: Double) -> CGPoint {
                orientation == .horizontal
                    ? CGPoint(x: position(index), y: amplitude(value))
                    : CGPoint(x: amplitude(value), y: position(index))
            }

            // Baseline, drawn only across the image's extent so the chart reads as
            // belonging to the picture rather than to the whole pane.
            var baseline = Path()
            if orientation == .horizontal {
                baseline.move(to: CGPoint(x: plotStart, y: size.height - 2))
                baseline.addLine(to: CGPoint(x: plotStart + span, y: size.height - 2))
            } else {
                baseline.move(to: CGPoint(x: 2, y: plotStart))
                baseline.addLine(to: CGPoint(x: 2, y: plotStart + span))
            }
            context.stroke(baseline, with: .color(.instrumentGridline), lineWidth: 1)

            // D4σ span markers
            if d4Sigma > 0 {
                for edge in [centroid - d4Sigma / 2, centroid + d4Sigma / 2] {
                    guard edge >= 0, edge <= Double(n - 1) else { continue }
                    var marker = Path()
                    let p = position(edge)
                    if orientation == .horizontal {
                        marker.move(to: CGPoint(x: p, y: 0))
                        marker.addLine(to: CGPoint(x: p, y: size.height))
                    } else {
                        marker.move(to: CGPoint(x: 0, y: p))
                        marker.addLine(to: CGPoint(x: size.width, y: p))
                    }
                    context.stroke(
                        marker,
                        with: .color(.orange.opacity(0.5)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                }
            }

            // Measured profile
            var curve = Path()
            // Subsample when the series is longer than the pixels available to draw it.
            let step = max(1, Int(Double(n) / Double(max(1, Int(span)))))
            var first = true
            for i in stride(from: 0, to: n, by: step) {
                let p = point(Double(i), Double(profile[i]))
                if first { curve.move(to: p); first = false } else { curve.addLine(to: p) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 1.4)

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
                context.stroke(
                    fitted,
                    with: .color(.yellow.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
        }
        .overlay(alignment: orientation == .horizontal ? .topLeading : .topLeading) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(Color.instrumentForeground)
                .padding(4)
        }
        .background(Color.instrumentBackground)
    }
}
