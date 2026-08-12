import SwiftUI

/// Live measured values. Read-only by design — nothing here changes the measurement,
/// so it stays visually distinct from the settings sidebar.
struct MetricsInspector: View {
    var model: ProfilerModel

    private var scale: Double { model.settings.micronsPerPixel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.metrics.isSaturated {
                    Label(
                        "Saturated — widths are biased low until this clears.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red, in: RoundedRectangle(cornerRadius: 6))
                }

                if !model.metrics.hasBeam {
                    ContentUnavailableView(
                        "No beam",
                        systemImage: "circle.dashed",
                        description: Text("Nothing above the noise threshold yet.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    group("Position") {
                        row("Centroid X", microns(model.metrics.centroidX))
                        row("Centroid Y", microns(model.metrics.centroidY))
                    }

                    group("Size (D4σ)") {
                        row("Horizontal", microns(model.metrics.d4SigmaX))
                        row("Vertical", microns(model.metrics.d4SigmaY))
                        row("Major", microns(model.metrics.majorDiameter))
                        row("Minor", microns(model.metrics.minorDiameter))
                    }

                    group("Shape") {
                        row(
                            "Ellipticity",
                            String(format: "%.3f", model.metrics.ellipticity),
                            detail: model.metrics.isCircular ? "circular" : "elliptical"
                        )
                        row("Angle", String(format: "%.2f°", model.metrics.angleDegrees))
                    }

                    group("Cross-checks") {
                        if let fwhm = model.metrics.measuredFWHMX {
                            row("FWHM X", microns(fwhm))
                        }
                        if let fwhm = model.metrics.measuredFWHMY {
                            row("FWHM Y", microns(fwhm))
                        }
                        if let fit = model.metrics.fitX {
                            row("Fit 2w X", microns(fit.d4SigmaEquivalent),
                                detail: String(format: "R²=%.4f", fit.rSquared))
                        }
                        if let fit = model.metrics.fitY {
                            row("Fit 2w Y", microns(fit.d4SigmaEquivalent),
                                detail: String(format: "R²=%.4f", fit.rSquared))
                        }
                    }

                    group("Signal") {
                        row("Peak", String(format: "%.1f%% FS", model.metrics.peak * 100))
                        row("Clipped", String(format: "%.3f%%",
                                              model.metrics.saturatedFraction * 100))
                        row("Background", String(format: "%.4f", model.metrics.backgroundMean),
                            detail: String(format: "σ = %.4f", model.metrics.backgroundSigma))
                    }

                    group("Integration") {
                        row("Aperture",
                            "\(model.metrics.aperture.width)×\(model.metrics.aperture.height) px")
                        row("Iterations", "\(model.metrics.iterations)",
                            detail: model.metrics.converged ? "converged" : "did not converge")
                    }
                }

                if let truth = model.syntheticTruth, model.sourceKind == .synthetic {
                    group("Ground truth") {
                        Text("Simulator values, for validating the analyser.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        row("D4σ X", microns(truth.d4SigmaX))
                        row("D4σ Y", microns(truth.d4SigmaY))
                        row("Ellipticity", String(format: "%.3f", truth.ellipticity))
                        row("Angle", String(format: "%.2f°", truth.majorAngle))
                    }
                }
            }
            .padding(14)
        }
        .navigationTitle("Measurement")
    }

    @ViewBuilder
    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ label: String, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(value)
                    .font(.callout.monospacedDigit())
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func microns(_ pixels: Double) -> String {
        let value = pixels * scale
        return value >= 1000
            ? String(format: "%.3f mm", value / 1000)
            : String(format: "%.1f µm", value)
    }
}
