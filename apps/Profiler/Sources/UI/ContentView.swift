import SwiftUI

struct ContentView: View {
    @State private var model = ProfilerModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Which column a collapsed (iPhone-width) split view shows. Starts on the instrument;
    /// once the user pops back to the settings list, the sidebar's own top row is the only
    /// way forward again, and it works by setting this back to `.detail`.
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var showInspector = true
    /// Space pauses only while the instrument pane holds focus, so it stays free for the
    /// sidebar's own controls — where Space is how macOS activates whatever Tab landed on.
    @FocusState private var beamHasFocus: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// One screen, so the metrics cannot be a trailing column and present as a sheet.
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// Where the metrics readout lives: a trailing column in regular widths, a sheet in
    /// compact. `nil` while a size-class change is in flight.
    private enum ReadoutContainer { case column, sheet }

    /// Deliberately not derived from the size class inside the bindings: that flips a
    /// dismissal and a presentation into the same render pass in which the split view
    /// collapses, and UIKit's column re-parenting mid-transition then finds view
    /// controllers where it does not expect them (a crash when narrowing an iPad window).
    /// Instead `readoutHandoff` retires the old container first, lets the collapse or
    /// expansion finish undisturbed, and only then raises the readout in its new home.
    @State private var readoutContainer: ReadoutContainer?

    private var inspectorPresented: Binding<Bool> {
        Binding(get: { showInspector && readoutContainer == .column },
                set: { showInspector = $0 })
    }

    private var sheetPresented: Binding<Bool> {
        Binding(get: { showInspector && readoutContainer == .sheet },
                set: { showInspector = $0 })
    }

    #if os(iOS)
    /// The readout sheet opens tall — most of the screen — so the full metrics list is
    /// readable at a glance; `.medium` stays available as a stop to drag down to when the
    /// beam behind it matters more. Reset on dismissal so every presentation opens tall.
    @State private var sheetDetent: PresentationDetent = .large
    #endif

    private func readoutHandoff() async {
        let target: ReadoutContainer = isCompact ? .sheet : .column
        guard let current = readoutContainer else {
            // First appearance: no transition running, adopt the container directly.
            readoutContainer = target
            lowerReadoutIfSheet(target)
            return
        }
        guard current != target else { return }
        readoutContainer = nil
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        readoutContainer = target
        lowerReadoutIfSheet(target)
    }

    /// The sheet never raises itself — at phone widths it covers the whole instrument, so
    /// launching (or narrowing an iPad window) into it would hide the beam behind numbers.
    /// It waits for the toolbar's Measurement toggle instead. The column keeps presenting
    /// on its own: at regular widths the readout sits beside the beam, not over it.
    private func lowerReadoutIfSheet(_ target: ReadoutContainer) {
        if target == .sheet { showInspector = false }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility,
                            preferredCompactColumn: $preferredColumn) {
            SettingsSidebar(model: model, preferredColumn: $preferredColumn,
                            isCollapsed: isCompact)
                .navigationSplitViewColumnWidth(min: 210, ideal: 300, max: 620)
        } detail: {
            MeasurementView(model: model)
                // No focus ring: the pane is the whole instrument, and a border drawn round
                // it would read as a state of the measurement rather than of the keyboard.
                .focusable()
                .focusEffectDisabled()
                .focused($beamHasFocus)
                .onKeyPress(.space) {
                    guard model.isRunning else { return .ignored }
                    model.frozen.toggle()
                    return .handled
                }
                #if os(macOS)
                .navigationTitle(model.windowTitle)
                .navigationSubtitle(captureStateSubtitle)
                #else
                // No title on iOS: the camera's name already labels the sidebar row that
                // leads here, and dropping it frees the full height for the instrument —
                // the canvas runs to the top edge with the toolbar floating over it.
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                #endif
                .toolbar { toolbarContent }
                .inspector(isPresented: inspectorPresented) {
                    MetricsInspector(model: model)
                        .inspectorColumnWidth(min: 210, ideal: 280, max: 480)
                }
                #if os(iOS)
                // In compact widths the readout is a real sheet, not the inspector's own
                // sheet fallback: that fallback never writes a swipe-dismiss back into its
                // binding, leaving the toolbar toggle out of phase — pressing it then hides
                // an already-hidden sheet, and only the second press shows it again.
                .sheet(isPresented: sheetPresented) {
                    MetricsInspector(model: model)
                        .presentationDetents([.medium, .large], selection: $sheetDetent)
                        .presentationDragIndicator(.visible)
                        // The readout should not silence the instrument behind it: dragged
                        // down to half height the beam stays visible and Pause / Export
                        // stay pressable.
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        .onDisappear { sheetDetent = .large }
                }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
        .defaultFocus($beamHasFocus, true)
        .task { await model.restoreAndAutostart() }
        // Re-fires on every width-class change, cancelling a handoff still in its settling
        // sleep, so rapid resizes keep the readout down until the last transition wins.
        .task(id: isCompact) { await readoutHandoff() }
    }

    /// The run state, where the eye already goes for the window's subject: a dot and one
    /// word. Green means frames are flowing; the beam view itself is the rest of the story.
    private var captureStateSubtitle: Text {
        let (color, label): (Color, String) = model.isRunning
            ? (model.frozen ? (.orange, "Paused") : (.green, "Capturing"))
            : (.secondary, "Idle")
        return Text(Image(systemName: "circle.fill"))
            .font(.system(size: 8))
            .foregroundStyle(color)
            + Text(" \(label)")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        // The split view's own reopen toggle never appears while an inspector is attached
        // to the detail column (attaching the inspector to the split view instead restores
        // it, but then a hidden readout presents itself at launch anyway and writes `true`
        // back through its binding — so the readout stays where it is and this button fills
        // in). Shown only while the sidebar is actually gone: in compact widths the
        // collapsed stack's back button covers this, and while the sidebar is visible its
        // own header carries the system toggle. `!= .all` rather than `== .detailOnly`:
        // if the system ever hands the binding `.automatic` for a hidden sidebar, the
        // failure is a redundant button, not an unreachable sidebar.
        if !isCompact, columnVisibility != .all {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation { columnVisibility = .all }
                } label: {
                    Label("Show Sidebar", systemImage: "sidebar.leading")
                }
                .help("Show the settings sidebar")
            }
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            // Start and stop live beside the Backend picker in the sidebar. Pause stays here:
            // it is used while watching the beam, not while setting the source up.
            Toggle(isOn: $model.frozen) {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!model.isRunning)
            .help(model.frozen
                ? "Resume live frames (Space)"
                : "Hold the current frame without stopping the source (Space)")

            if !model.plottedQuantities.isEmpty {
                Button {
                    model.resetTimeHistory()
                } label: {
                    Label("Reset History", systemImage: "arrow.counterclockwise")
                }
                .help("Clear the retained time-series history")
            }

            if let export = model.currentExport {
                ShareLink(items: export.shareFiles) { file in
                    SharePreview(file.filename, icon: file.previewIcon(thumbnail: model.displayImage))
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Share the beam image, the profiles, and the metrics")
            } else {
                Button {} label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(true)
            }

            Toggle(isOn: $showInspector) {
                Label("Measurement", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the measurement readout")
        }
    }
}

/// The instrument display: beam image, both integrated profiles, and a status strip.
///
/// The instrument first defines one outer box with the camera image's aspect ratio. The
/// profile-size fraction is then removed from the box's top and right, scaling the image
/// uniformly into the bottom-left remainder. The X and Y profiles occupy those reserved
/// bands, separated from the image by a small fixed gutter.
struct MeasurementView: View {
    var model: ProfilerModel
    private let profileGap: CGFloat = 4
    private let splitHandleHeight: CGFloat = 9
    @AppStorage("mainTimeSeriesSplit.v1") private var mainSplitFraction = 0.70
    @State private var splitDragStart: Double?
    #if os(macOS)
    @AppStorage(StatusBarPreference.key) private var showStatusBar = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if model.plottedQuantities.isEmpty {
                instrumentPane
            } else {
                GeometryReader { geometry in
                    let availableHeight = max(1, geometry.size.height - splitHandleHeight)
                    let mainHeight = availableHeight * CGFloat(clampedSplitFraction)

                    VStack(spacing: 0) {
                        instrumentPane
                            .frame(height: mainHeight)
                        splitHandle(availableHeight: availableHeight)
                        TimeSeriesPanel(model: model)
                            .frame(height: availableHeight - mainHeight)
                    }
                }
            }

            #if os(macOS)
            if showStatusBar {
                Divider()
                statusBar
            }
            #endif
        }
        .background(Color.instrumentCanvas)
        #if os(iOS)
        // Run the instrument under the (backgroundless) navigation bar and status bar,
        // so the beam uses the whole screen height rather than stopping at the bar line.
        .ignoresSafeArea(.container, edges: .top)
        #endif
    }

    /// The aspect-fitted image/profile block within whatever share of the split it receives.
    private var instrumentPane: some View {
        GeometryReader { geometry in
            let box = BeamImageView.fittedRect(
                imageSize: imageSize,
                in: geometry.size
            ).size

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if model.showProfiles {
                        instrumentBlock(box: box)
                    } else {
                        BeamImageView(model: model)
                            .frame(width: box.width, height: box.height)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var clampedSplitFraction: Double {
        min(0.90, max(0.35, mainSplitFraction))
    }

    /// A generous hit target around a visually quiet split-view divider.
    private func splitHandle(availableHeight: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 36, height: 3)
        }
        .frame(height: splitHandleHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if splitDragStart == nil {
                        splitDragStart = clampedSplitFraction
                    }
                    let start = splitDragStart ?? clampedSplitFraction
                    let delta = Double(value.translation.height / availableHeight)
                    mainSplitFraction = min(0.90, max(0.35, start + delta))
                }
                .onEnded { _ in splitDragStart = nil }
        )
        .accessibilityLabel("Resize main view and time-series plots")
        .accessibilityValue("Main view \(Int(clampedSplitFraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                mainSplitFraction = min(0.90, clampedSplitFraction + 0.05)
            case .decrement:
                mainSplitFraction = max(0.35, clampedSplitFraction - 0.05)
            @unknown default:
                break
            }
        }
    }

    /// Subdivides the aspect-fitted outer box. Removing the same fraction on each axis
    /// leaves an image rectangle scaled uniformly from the box, hence with the source
    /// image's exact aspect ratio.
    private func instrumentBlock(box: CGSize) -> some View {
        let fraction = CGFloat(model.profileChartFraction)
        let imageWidth = max(1, box.width * (1 - fraction))
        let imageHeight = max(1, box.height * (1 - fraction))
        let profileWidth = max(0, box.width - imageWidth - profileGap)
        let profileHeight = max(0, box.height - imageHeight - profileGap)

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Live raw profiles, so the curves track the capture rate; the fit
                // comes from the latest analysis and may lag a few frames behind
                // the curve it annotates.
                ProfileChartView(
                    profile: model.liveProfileX,
                    fit: model.metrics.fitX,
                    centroid: model.metrics.centroidX,
                    d4Sigma: model.metrics.d4SigmaX,
                    orientation: .horizontal,
                    amplitudeMax: sharedAmplitudeMax
                )
                .frame(width: imageWidth, height: profileHeight)
                .measurementDrag(model.currentExport?.file(.profileX))

                // The empty corner is the intersection of the two reserved profile bands.
                Color.clear
                    .frame(width: profileWidth, height: profileHeight)
            }

            Color.clear
                .frame(height: profileGap)

            // Y is to the image's right, across the fixed profile gutter.
            HStack(spacing: 0) {
                BeamImageView(model: model)
                    .frame(width: imageWidth, height: imageHeight)

                Color.clear
                    .frame(width: profileGap, height: imageHeight)

                ProfileChartView(
                    profile: model.liveProfileY,
                    fit: model.metrics.fitY,
                    centroid: model.metrics.centroidY,
                    d4Sigma: model.metrics.d4SigmaY,
                    orientation: .vertical,
                    amplitudeMax: sharedAmplitudeMax
                )
                .frame(width: profileWidth, height: imageHeight)
                .measurementDrag(model.currentExport?.file(.profileY))
            }
        }
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
        let peakX = model.liveProfileX.max().map(Double.init) ?? 0
        let peakY = model.liveProfileY.max().map(Double.init) ?? 0
        let peak = max(peakX, peakY)
        return peak > 0 ? peak : nil
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isRunning {
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

extension View {
    /// Drag-out for a measurement artifact; inert until there is anything to drag.
    @ViewBuilder
    func measurementDrag(_ file: ExportFile?) -> some View {
        if let file {
            draggable(file)
        } else {
            self
        }
    }
}

extension ExportFile {
    /// Share-sheet thumbnail: the live beam picture for the image file — already rendered,
    /// so no encoder runs for a preview — and a glyph for the data files.
    func previewIcon(thumbnail: CGImage?) -> Image {
        if content == .image, let thumbnail {
            return Image(decorative: thumbnail, scale: 1)
        }
        return Image(systemName: iconSystemName)
    }
}
