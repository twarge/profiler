import SwiftUI

extension View {
    /// Makes a readout row itself the plot toggle. A light tint replaces the removed icon
    /// as the persistent indication that the quantity is currently being plotted.
    func plottableRow(quantity: PlotQuantity, model: ProfilerModel) -> some View {
        let isPlotted = model.plottedQuantities.contains(quantity)
        return frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlot(quantity) }
            .listRowBackground(isPlotted ? Color.accentColor.opacity(0.12) : Color.clear)
            .help(isPlotted
                  ? "Stop plotting \(quantity.label)"
                  : "Plot \(quantity.label) over time")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isPlotted ? "Plotted" : "Not plotted")
            .accessibilityAction { model.togglePlot(quantity) }
    }
}

/// Time series for every quantity currently selected, below the measurement view.
///
/// One chart per quantity rather than one chart with many series: these are different
/// physical units — microns, degrees, a bare ratio — and overlaying them on a shared axis
/// would either flatten the interesting one to a line or require normalising the numbers
/// into meaninglessness. Each chart runs the full width of the pane — time resolution is
/// the whole point of these. The active charts divide all available height evenly.
struct TimeSeriesPanel: View {
    var model: ProfilerModel

    private var quantities: [PlotQuantity] {
        PlotQuantity.allCases.filter { model.plottedQuantities.contains($0) }
    }

    var body: some View {
        GeometryReader { geometry in
            let dividerHeight = CGFloat(max(0, quantities.count - 1))
            let rowHeight = quantities.isEmpty
                ? 0
                : max(0, (geometry.size.height - dividerHeight) / CGFloat(quantities.count))

            VStack(spacing: 0) {
                ForEach(quantities) { quantity in
                    chartRow(for: quantity)
                        .frame(height: rowHeight)
                    if quantity != quantities.last {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func chartRow(for quantity: PlotQuantity) -> some View {
        let points = model.timeSeries.series[quantity] ?? []
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(quantity.label)
                    .font(.headline)
                Spacer(minLength: 4)
                if model.showPlotReadout, let last = points.last {
                    // The number being watched, readable from across the bench — these plots
                    // exist to be glanced at during alignment, not leaned into.
                    Text(quantity.format(last.value, figures: model.significantFigures))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Button {
                    model.togglePlot(quantity)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                        .iconButtonTarget()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop plotting \(quantity.label)")
            }

            TimeSeriesTrace(
                points: points, quantity: quantity,
                significantFigures: model.significantFigures
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// The trace itself.
///
/// Canvas rather than Swift Charts, matching `ProfileChartView`: this redraws whenever a
/// measurement lands, and the axis range has to be recomputed each time because a drifting
/// beam walks off any fixed scale.
struct TimeSeriesTrace: View {
    var points: [PlotSample]
    var quantity: PlotQuantity
    var significantFigures: Int

    var body: some View {
        Canvas { context, size in
            guard points.count > 1,
                  let first = points.first?.time,
                  let last = points.last?.time
            else { return }

            let values = points.map(\.value)
            var low = values.min() ?? 0
            var high = values.max() ?? 0

            // A dead-flat series has zero range, which would divide by zero and also draw a
            // line pinned to one edge. Give it a small symmetric band so it reads as steady
            // rather than as missing.
            if high - low < 1e-12 {
                let pad = max(abs(high) * 0.01, 1e-6)
                low -= pad
                high += pad
            }

            let span = max(last.timeIntervalSince(first), 1e-6)
            func point(_ sample: PlotSample) -> CGPoint {
                let x = CGFloat(sample.time.timeIntervalSince(first) / span) * size.width
                let t = (sample.value - low) / (high - low)
                return CGPoint(x: x, y: size.height * (1 - CGFloat(t)))
            }

            var path = Path()
            path.move(to: point(points[0]))
            for sample in points.dropFirst() {
                path.addLine(to: point(sample))
            }
            // Primary label colour, matching the profile charts: black data on the light
            // canvas, white on dark.
            context.stroke(path, with: .color(.primary), lineWidth: 1.5)

            // Where the series is *now*: a dot on the newest sample, with its level carried
            // across the window as a dotted rule. The rule is what makes drift legible —
            // the eye compares the trace against a flat reference instead of judging the
            // slope of a wiggling line.
            let current = point(points[points.count - 1])
            var level = Path()
            level.move(to: CGPoint(x: 0, y: current.y))
            level.addLine(to: CGPoint(x: size.width, y: current.y))
            context.stroke(
                level,
                with: .color(.accentColor.opacity(0.6)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
            let dot = CGRect(x: current.x - 2.5, y: current.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(.accentColor))

            // Range labels, so the trace has a scale without a full axis. System body
            // size, like every other label on the graph, so they track the user's text
            // size instead of a hand-picked point count.
            context.draw(
                Text(quantity.format(high, figures: significantFigures))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: 2, y: 2), anchor: .topLeading
            )
            context.draw(
                Text(quantity.format(low, figures: significantFigures))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: 2, y: size.height - 2), anchor: .bottomLeading
            )
        }
    }
}
