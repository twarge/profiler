import SwiftUI

struct ContentView: View {
    @State private var model = ProfilerModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 300, max: 620)
        } detail: {
            MeasurementView(model: model)
                .navigationTitle(model.windowTitle)
                .navigationSubtitle(model.status)
                .toolbar { toolbarContent }
                .inspector(isPresented: $showInspector) {
                    MetricsInspector(model: model)
                        .inspectorColumnWidth(min: 210, ideal: 280, max: 480)
                }
        }
        .frame(minWidth: 980, minHeight: 640)
        .task { await model.restoreAndAutostart() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task {
                    if model.isRunning { await model.stop() } else { await model.start() }
                }
            } label: {
                Label(
                    model.isRunning ? "Stop" : "Start",
                    systemImage: model.isRunning ? "stop.fill" : "play.fill"
                )
            }
            .help(model.isRunning ? "Stop capture" : "Start capture")

            Toggle(isOn: $model.frozen) {
                Label("Freeze", systemImage: "snowflake")
            }
            .disabled(!model.isRunning)
            .help("Hold the current frame without stopping the source")

            Spacer()

            Toggle(isOn: $showInspector) {
                Label("Measurement", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the measurement readout")
        }
    }
}

/// The instrument display: beam image, both integrated profiles, and a status strip.
///
/// The image is aspect-fitted, so its drawn extent is computed once here and handed to both
/// charts. That keeps a feature at image column `x` directly above its peak in the
/// horizontal profile, and at row `y` directly beside its peak in the vertical one.
struct MeasurementView: View {
    var model: ProfilerModel

    private let chartThickness: CGFloat = 130

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let imageWidth = max(1, geometry.size.width - chartThickness - 1)
                let imageHeight = max(1, geometry.size.height - chartThickness - 1)
                let fitted = BeamImageView.fittedRect(
                    imageSize: imageSize,
                    in: CGSize(width: imageWidth, height: imageHeight)
                )

                VStack(spacing: 0) {
                    // X profile sits directly above the image, baseline against it.
                    HStack(spacing: 0) {
                        ProfileChartView(
                            profile: model.metrics.profileX,
                            fit: model.metrics.fitX,
                            centroid: model.metrics.centroidX,
                            d4Sigma: model.metrics.d4SigmaX,
                            orientation: .horizontal,
                            label: "X",
                            plotStart: fitted.minX,
                            plotLength: fitted.width,
                            amplitudeMax: sharedAmplitudeMax
                        )
                        .frame(width: imageWidth, height: chartThickness)

                        Divider()

                        Color.instrumentBackground
                            .frame(width: chartThickness, height: chartThickness)
                    }

                    Divider()

                    // Y profile sits directly right of the image, baseline against it.
                    HStack(spacing: 0) {
                        BeamImageView(model: model)
                            .frame(width: imageWidth, height: imageHeight)

                        Divider()

                        ProfileChartView(
                            profile: model.metrics.profileY,
                            fit: model.metrics.fitY,
                            centroid: model.metrics.centroidY,
                            d4Sigma: model.metrics.d4SigmaY,
                            orientation: .vertical,
                            label: "Y",
                            plotStart: fitted.minY,
                            plotLength: fitted.height,
                            amplitudeMax: sharedAmplitudeMax
                        )
                        .frame(width: chartThickness, height: imageHeight)
                    }
                }
            }

            Divider()
            statusBar
        }
        .background(Color.instrumentBackground)
    }

    private var imageSize: CGSize {
        guard let image = model.displayImage else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    /// One full-scale value for both charts, so their amplitudes mean the same thing.
    ///
    /// The two marginals genuinely differ in peak height: integrating a beam of waists
    /// (wx, wy) gives peaks in the ratio wy:wx, so on a shared scale an elliptical beam
    /// shows the narrow axis taller. That is the honest picture — normalising each to its
    /// own maximum would draw every beam as though it were round.
    private var sharedAmplitudeMax: Double? {
        let peakX = model.metrics.profileX.max().map(Double.init) ?? 0
        let peakY = model.metrics.profileY.max().map(Double.init) ?? 0
        let peak = max(peakX, peakY)
        return peak > 0 ? peak : nil
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(model.isRunning ? "Capturing" : "Idle")
                .font(.caption)
            if model.frozen {
                Label("Frozen", systemImage: "snowflake")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.isRunning {
                Divider().frame(height: 12)
                Text(String(
                    format: "capture %.1f · analysed %.1f fps",
                    model.captureFPS, model.fps))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("A gap between these means analysis is dropping frames.")
                if model.droppedFrames > 0 {
                    Text("· \(model.droppedFrames) dropped")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
            Text("D4σ per ISO 11146")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
