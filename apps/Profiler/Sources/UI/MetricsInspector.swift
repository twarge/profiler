import SwiftUI

/// Live measured values. Read-only by design — nothing here changes the measurement, so it
/// stays visually distinct from the settings sidebar.
///
/// Position, size, shape and signal are what you watch while aligning, so they start open.
/// The cross-checks and the integration detail are what you consult when a number looks
/// wrong, so they start closed.
struct MetricsInspector: View {
    @Bindable var model: ProfilerModel

    private enum Panel: String {
        case position, size, shape, crossChecks, signal, truth
    }

    private var scale: Double { model.settings.micronsPerPixel }
    private var metrics: BeamMetrics { model.metrics }
    private var figures: Int { model.significantFigures }

    var body: some View {
        List {
            if metrics.isSaturated {
                saturationWarning
            }

            if metrics.hasBeam {
                positionSection
                sizeSection
                shapeSection
                crossCheckSection
                signalSection
            } else {
                ContentUnavailableView(
                    "No beam",
                    systemImage: "circle.dashed",
                    description: Text("Nothing above the noise threshold yet.")
                )
                .listRowSeparator(.hidden)
            }

            if let truth = model.syntheticTruth, model.sourceKind == .synthetic {
                groundTruthSection(truth)
            }
        }
        .listStyle(.sidebar)
        .headerProminence(.standard)
    }

    // MARK: - Sections

    private var saturationWarning: some View {
        Label(
            "Saturated — widths are biased low until this clears.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red, in: RoundedRectangle(cornerRadius: 6))
        .listRowSeparator(.hidden)
    }

    private var positionSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedMetricSections[contains: Panel.position.rawValue]
        ) {
            metric("Centroid X", microns(metrics.centroidX), plot: .centroidX)
            metric("Centroid Y", microns(metrics.centroidY), plot: .centroidY)
        } header: {
            Text("Position")
        }
    }

    private var sizeSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedMetricSections[contains: Panel.size.rawValue]
        ) {
            metric("Horizontal", microns(metrics.d4SigmaX), plot: .d4SigmaX)
            metric("Vertical", microns(metrics.d4SigmaY), plot: .d4SigmaY)
            metric("Major", microns(metrics.majorDiameter), plot: .majorDiameter)
            metric("Minor", microns(metrics.minorDiameter), plot: .minorDiameter)
        } header: {
            Text("Size (D4σ)")
        }
    }

    private var shapeSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedMetricSections[contains: Panel.shape.rawValue]
        ) {
            metric(
                "Ellipticity",
                MeasurementFormat.significant(metrics.ellipticity, figures: figures),
                detail: metrics.isCircular ? "circular" : "elliptical",
                plot: .ellipticity
            )
            metric(
                "Angle",
                MeasurementFormat.significant(metrics.angleDegrees, figures: figures) + "°",
                plot: .angle
            )
        } header: {
            Text("Shape")
        }
    }

    private var crossCheckSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedMetricSections[contains: Panel.crossChecks.rawValue]
        ) {
            if let fwhm = metrics.measuredFWHMX {
                metric("FWHM X", microns(fwhm))
            }
            if let fwhm = metrics.measuredFWHMY {
                metric("FWHM Y", microns(fwhm))
            }
            if let fit = metrics.fitX {
                metric("Fit 2w X", microns(fit.d4SigmaEquivalent),
                       detail: String(format: "R²=%.4f", fit.rSquared))
            }
            if let fit = metrics.fitY {
                metric("Fit 2w Y", microns(fit.d4SigmaEquivalent),
                       detail: String(format: "R²=%.4f", fit.rSquared))
            }
        } header: {
            Text("Cross-Checks")
        }
    }

    private var signalSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedMetricSections[contains: Panel.signal.rawValue]
        ) {
            metric(
                "Peak",
                MeasurementFormat.significant(metrics.peak * 100, figures: figures) + "% FS",
                plot: .peak
            )
            metric(
                "Clipped",
                MeasurementFormat.significant(
                    metrics.saturatedFraction * 100, figures: figures) + "%",
                plot: .clippedFraction
            )
            metric(
                "Background",
                MeasurementFormat.significant(metrics.backgroundMean, figures: figures),
                detail: "σ = " + MeasurementFormat.significant(
                    metrics.backgroundSigma, figures: figures),
                plot: .background
            )
        } header: {
            Text("Signal")
        }
    }

    private func groundTruthSection(_ truth: SyntheticSource.Truth) -> some View {
        CollapsibleListSection(
            isExpanded: $model.expandedMetricSections[contains: Panel.truth.rawValue]
        ) {
            metric("D4σ X", microns(truth.d4SigmaX))
            metric("D4σ Y", microns(truth.d4SigmaY))
            metric(
                "Ellipticity",
                MeasurementFormat.significant(truth.ellipticity, figures: figures)
            )
            metric(
                "Angle",
                MeasurementFormat.significant(truth.majorAngle, figures: figures) + "°"
            )
        } header: {
            Text("Ground Truth")
                .help("Simulator values, for validating the analyser.")
        }
    }

    // MARK: - Row shape

    /// One measured value. `LabeledContent` is the native label/value pair, and carries the
    /// right secondary styling for the label without setting it by hand.
    @ViewBuilder
    private func metric(
        _ label: String,
        _ value: String,
        detail: String? = nil,
        plot: PlotQuantity? = nil
    ) -> some View {
        if let plot {
            metricContent(label, value, detail: detail)
                .plottableRow(quantity: plot, model: model)
        } else {
            metricContent(label, value, detail: detail)
        }
    }

    private func metricContent(
        _ label: String,
        _ value: String,
        detail: String?
    ) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func microns(_ pixels: Double) -> String {
        MeasurementFormat.length(pixels: pixels, micronsPerPixel: scale, figures: figures)
    }
}
