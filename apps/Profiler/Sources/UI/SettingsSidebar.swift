import SwiftUI

/// Controls, as a proper source list. Everything here is an *input*; measured values live in
/// the trailing inspector so the two never get confused for each other.
///
/// The sections collapse. Only two of them matter once a measurement is running, so the
/// ones you set up once — calibration, background, display — start closed and stay out of
/// the way.
struct SettingsSidebar: View {
    @Bindable var model: ProfilerModel
    /// The collapsed split view's visible column. Only written here, never read: the top
    /// row sets it back to `.detail` because a collapsed sidebar is otherwise a dead end —
    /// the system gives the instrument a back button to here, but nothing pointing forward.
    @Binding var preferredColumn: NavigationSplitViewColumn
    /// Whether the split view is one screen. Passed in from outside the split view: the
    /// sidebar cannot ask its own environment, because an expanded split view still gives
    /// its sidebar *column* a compact width — the window's class is the collapse signal.
    var isCollapsed: Bool

    private enum Panel: String {
        case source, gain, calibration, background, display
    }

    var body: some View {
        List {
            #if os(iOS)
            if isCollapsed {
                mainViewRow
            }
            #endif
            sourceSection
            gainSection
            calibrationSection
            displaySection
            backgroundSection
            #if os(iOS)
            if model.isRunning {
                fpsRow
            }
            #endif
        }
        .listStyle(.sidebar)
        .headerProminence(.standard)
        #if os(iOS)
        // iOS switches otherwise use their independent green treatment; keep the controls
        // in this list on the app's single system tint. Scoped to the list rather than the
        // whole split view so it does not reach the toolbar, whose glyphs are meant to be
        // label-coloured and take the accent only as the selected highlight. macOS controls
        // retain native AppKit styling, particularly menu-style pickers whose labels are
        // not accent-coloured.
        .tint(Color.accentColor)
        #endif
    }

    // MARK: - Main view (collapsed widths only)

    #if os(iOS)
    /// The way back to the instrument when the sidebar is the whole screen. Labelled with
    /// the destination's own title, like any list row that pushes a screen; the manual
    /// chevron says "navigates" where a Button would otherwise read as an action.
    private var mainViewRow: some View {
        Section {
            Button {
                preferredColumn = .detail
            } label: {
                HStack {
                    Label {
                        Text(model.windowTitle)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "camera.metering.center.weighted")
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityLabel("Show \(model.windowTitle)")
            .accessibilityHint("Returns to the beam profile view")
        }
    }
    #endif

    // MARK: - Source

    private var sourceSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedSettingsSections[contains: Panel.source.rawValue]
        ) {
            // Run control sits with the backend it runs, rather than in the toolbar: the
            // picker it is beside is the thing that has to be settled before starting, and
            // is disabled by the same running state that flips this button to Stop.
            HStack {
                Picker("Backend", selection: $model.sourceKind) {
                    ForEach(ProfilerModel.SourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .disabled(model.isRunning)
                .help(model.sourceKind.detail)

                Button {
                    Task {
                        if model.isRunning { await model.stop() } else { await model.start() }
                    }
                } label: {
                    Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.primary)
                        .iconButtonTarget()
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityLabel(model.isRunning ? "Stop capture" : "Start capture")
                .help(model.isRunning ? "Stop capture" : "Start capture")
            }

            #if os(iOS)
            // iOS has no window subtitle, so the compact capture state lives with the
            // backend that owns it. Operational chatter such as auto-gain adjustments is
            // deliberately omitted here; the current ISO is already visible in Gain / ISO.
            LabeledContent("Status") {
                HStack(spacing: 5) {
                    Circle()
                        .fill(captureStateColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(captureStateLabel)
                }
            }
            #endif

            switch model.sourceKind {
            case .ptp:
                if model.ptpCameras.isEmpty {
                    HStack {
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Rescan") { model.beginPTPDiscovery() }
                            .inlineLinkStyle()
                    }
                    Text("Set USB Connection Mode to PC Remote on the camera.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Camera", selection: $model.selectedPTPCameraID) {
                        ForEach(model.ptpCameras) { camera in
                            Text(camera.name + (camera.acceptsPTP ? "" : " (no PTP)"))
                                .tag(Optional(camera.id))
                        }
                    }
                    .disabled(model.isRunning)
                }

            case .uvc:
                HStack {
                    Picker("Device", selection: $model.selectedUVCDeviceID) {
                        ForEach(model.uvcDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .disabled(model.isRunning)
                    Button {
                        model.refreshUVCDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .iconButtonTarget()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rescan for USB video devices")
                    .help("Rescan for USB video devices")
                }

            case .synthetic:
                EmptyView()
            }

            Picker("Channel", selection: $model.settings.channel) {
                ForEach(MeasurementChannel.allCases) { channel in
                    Text(channel.rawValue).tag(channel)
                }
            }
            .help(model.settings.channel.detail)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Source")
        }
    }

    // MARK: - Gain

    private var gainSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedSettingsSections[contains: Panel.gain.rawValue]
        ) {
            // One row, whether the ISO can be set or only read: on a source that can set it
            // the picker's own selection *is* the readout, so a separate value beside it was
            // the same number twice.
            LabeledContent("ISO") {
                if model.gain.canSetISO, !model.gain.availableISO.isEmpty {
                    Picker("", selection: Binding(
                        get: { model.gain.currentISO ?? model.gain.availableISO.first ?? 100 },
                        set: { value in Task { await model.setISOManually(value) } }
                    )) {
                        ForEach(model.gain.availableISO, id: \.self) { iso in
                            Text("\(iso)").tag(iso)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.autoGainEnabled)
                    .help(model.autoGainEnabled
                          ? "Turn the auto-gain servo off to set the ISO by hand."
                          : "Set the camera's ISO.")
                } else {
                    Text(model.gain.currentISO.map(String.init) ?? "—")
                        .monospacedDigit()
                }
            }
            .plottableRow(quantity: .iso, model: model)
            if let shutter = model.gain.shutterLabel {
                LabeledContent("Shutter") { Text(shutter).monospacedDigit() }
            }

            Toggle("Auto-Gain Servo", isOn: $model.autoGainEnabled)
                .disabled(!model.isRunning)
                .help(model.gain.note ?? "Adjusts gain to hold the beam at the target peak.")

            slider("Target Peak", value: $model.targetPeak, in: 0.30...0.90,
                   readout: String(format: "%.0f%% FS", model.targetPeak * 100),
                   help: "Peak signal level the auto-gain servo holds the beam to.")

            if let advisory = model.advisory {
                Label(advisory, systemImage: "arrow.up.arrow.down.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Gain / ISO")
        }
    }

    // MARK: - Calibration

    private var calibrationSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedSettingsSections[contains: Panel.calibration.rawValue]
        ) {
            LabeledContent("µm / pixel") {
                TextField(
                    "",
                    value: $model.settings.micronsPerPixel,
                    format: .number.precision(.fractionLength(0...4))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .multilineTextAlignment(.trailing)
                // Read-only while the bare-sensor pitch drives it, since anything typed here
                // would be overwritten by the next frame.
                .disabled(model.useBareSensorPitch)
            }
            .help("Every reported size scales with this. Pitch is the sensor width divided "
                  + "by the streamed frame width, so a downscaled live view has a much "
                  + "coarser pitch than the sensor's native figure.")

            sensorPresetNote

            if let preset = model.detectedSensor, let pitch = model.detectedSensorPitch {
                Button(String(format: "Use %@ Pitch (%.2f µm)", preset.displayName, pitch)) {
                    model.settings.micronsPerPixel = pitch
                }
                .inlineLinkStyle()
                .help("Set µm/pixel from the matched preset at the current frame width.")
            }

            // A checkbox rather than a button, because it is a standing choice about the
            // optical setup: with the lens off the pitch follows the stream width, and a
            // source that changes width mid-run has to carry the new pitch with it.
            Toggle("Use Bare-Sensor Pitch", isOn: $model.useBareSensorPitch)
                .disabled(model.streamedFrameWidth == nil)
                .help(model.streamedFrameWidth == nil
                      ? "Needs a frame: the pitch is 35600 µm divided by the streamed width."
                      : "Hold µm/pixel at 35600 / current frame width, for a lens-free sensor.")
        } header: {
            Text("Calibration")
        }
    }

    /// Says where the number in the field came from — or that nothing matched, which is
    /// itself worth stating: an unrecognised camera means the pitch is whatever was last
    /// entered, and a silent field looks identical to a calibrated one.
    @ViewBuilder
    private var sensorPresetNote: some View {
        if let preset = model.detectedSensor {
            let native = String(format: "%.2f", preset.nativePitchMicrons)
            let scaled = model.detectedSensorPitch.map { String(format: "%.2f", $0) }
            Label {
                Text("Matched **\(preset.displayName)** — \(native) µm native"
                     + (scaled.map { ", \($0) µm at this stream width" } ?? ""))
            } icon: {
                Image(systemName: "checkmark.seal")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.sourceKind != .synthetic {
            Label("No preset for this camera — set the pitch by hand.",
                  systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Background

    private var backgroundSection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedSettingsSections[contains: Panel.background.rawValue]
        ) {
            HStack {
                Button("Capture Dark Frame") { model.captureDarkFrame() }
                    .disabled(!model.isRunning)
                if model.hasDarkFrame {
                    Button("Clear") { model.clearDarkFrame() }
                        .inlineLinkStyle()
                }
            }
            if let status = model.darkFrameStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(model.hasDarkFrame ? .green : .secondary)
            }
            Toggle("Subtract Dark Frame", isOn: $model.settings.subtractDarkFrame)
                .disabled(!model.hasDarkFrame)

            slider("Noise Threshold", value: $model.settings.noiseSigmaMultiplier, in: 0...6,
                   readout: String(format: "%.1fσ", model.settings.noiseSigmaMultiplier),
                   help: "Locates the beam and sizes the aperture. "
                       + "Moments run on unclipped data.")

            slider("Aperture Factor", value: $model.settings.apertureFactor, in: 1.5...6,
                   readout: String(format: "%.1f×", model.settings.apertureFactor),
                   help: "ISO 11146 recommends 3× the beam diameter.")
        } header: {
            Text("Background")
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        CollapsibleListSection(
            isExpanded: $model.expandedSettingsSections[contains: Panel.display.rawValue]
        ) {
            // The picker itself stays text-only: a menu-style Picker flattens its rows to
            // labels, so a swatch placed inside one is silently dropped. The ramp goes
            // underneath instead, where it renders and is big enough to actually judge.
            Picker("Colormap", selection: $model.colormap) {
                ForEach(Colormap.allCases) { map in
                    Text(map.rawValue).tag(map)
                }
            }
            .help(model.colormap.detail)
            ColormapSwatch(colormap: model.colormap)

            Toggle("Logarithmic Scale", isOn: $model.logarithmic)

            slider("Display Gain", value: $model.displayGain, in: 1...50,
                   readout: String(format: "%.1f×", model.displayGain),
                   help: "Affects the picture only, never the measurement.")

            Toggle("X / Y Profiles", isOn: $model.showProfiles)

            slider("Profile Size", value: $model.profileChartFraction, in: 0.08...0.40,
                   readout: String(format: "%.0f%%", model.profileChartFraction * 100),
                   help: "How much of the pane the two profile graphs take, "
                       + "against the beam image.")
                .disabled(!model.showProfiles)

            Toggle("Centroid Crosshair", isOn: $model.showCrosshair)
            Toggle("1/e² Ellipse", isOn: $model.showEllipse)
            Toggle("Ellipse Long Axis", isOn: $model.showMajorAxis)
                .disabled(!model.showEllipse)
                .padding(.leading, 16)

            // Not a display option in the strict sense: with this off the fit is not run at
            // all. Nothing reported depends on it — every width is a second moment — so it
            // is the one piece of per-frame work that can simply be dropped.
            Toggle("Time-Series Readout", isOn: $model.showPlotReadout)
                .help("Shows each plotted quantity's current value in large type "
                      + "on its time-series row.")

            slider("Time-Series Window", value: $model.plotWindow, in: 10...600,
                   readout: String(format: "%.0f s", model.plotWindow),
                   help: "How much history the time-series plots keep. "
                       + "Shortening it drops the older points on the next sample.")

            Stepper(value: $model.significantFigures, in: 2...6) {
                HStack {
                    Text("Significant Figures")
                    Spacer()
                    Text("\(model.significantFigures)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .help("Digits shown for every measured value. "
                  + "Exports always carry full precision.")

            Toggle("Fit Profiles", isOn: $model.settings.fitProfiles)
                .help("Fits a Gaussian to each profile. Off skips the fit entirely; "
                      + "the measured widths are moments and never use it.")
        } header: {
            Text("Display")
        }
    }

    // MARK: - Shared row shapes

    #if os(iOS)
    private var fpsRow: some View {
        Text(String(
            format: "Capture %.1f · analysed %.1f fps",
            model.captureFPS, model.fps
        ))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var captureStateLabel: String {
        if !model.isRunning { return "Idle" }
        return model.frozen ? "Paused" : "Capturing"
    }

    private var captureStateColor: Color {
        if !model.isRunning { return .secondary }
        return model.frozen ? .orange : .green
    }
    #endif

    /// A slider with its value read out beside its label. `Slider`'s own label is not shown
    /// in a sidebar list, so the row above carries it; explanation goes in the tooltip.
    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        readout: String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(readout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        .help(help)
    }
}

/// A strip of the colormap itself, so choosing between nine names is a matter of looking
/// rather than remembering.
///
/// The pixels come from `swatchImage`, which is the same lookup table the beam image is
/// painted with — the swatch is a sample of the real thing, not a re-description of it.
struct ColormapSwatch: View {
    var colormap: Colormap
    var height: CGFloat = 12

    var body: some View {
        Group {
            if let image = colormap.swatchImage() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

/// `.link` is the small inline text button on macOS and does not exist on iOS, where
/// `.borderless` gives the same tinted-text appearance.
extension View {
    func inlineLinkStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// Hit target for a bare icon button: comfortable on touch platforms, compact on the
    /// Mac where the pointer is precise. Width stays under the full 44 pt so a readout row
    /// (label, value, button) still fits a narrow inspector column without wrapping; the
    /// row's own height carries the vertical target.
    func iconButtonTarget() -> some View {
        #if os(macOS)
        frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        #else
        frame(minWidth: 36, minHeight: 44)
            .contentShape(Rectangle())
        #endif
    }
}
