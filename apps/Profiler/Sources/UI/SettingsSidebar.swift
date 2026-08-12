import SwiftUI

/// Controls, as a proper macOS source list. Everything here is an *input*; measured
/// values live in the trailing inspector so the two never get confused for each other.
struct SettingsSidebar: View {
    @Bindable var model: ProfilerModel

    var body: some View {
        List {
            sourceSection
            gainSection
            calibrationSection
            backgroundSection
            displaySection
            exportSection
        }
        .listStyle(.sidebar)
        .navigationTitle("Setup")
    }

    // MARK: - Source

    private var sourceSection: some View {
        Section("Source") {
            Picker("Backend", selection: $model.sourceKind) {
                ForEach(ProfilerModel.SourceKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .disabled(model.isRunning)

            Text(model.sourceKind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.sourceKind {
            case .ptp:
                if model.ptpCameras.isEmpty {
                    HStack {
                        Text("Searching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Rescan") { model.beginPTPDiscovery() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    Text("Set USB Connection Mode to PC Remote on the camera. "
                         + "It appears here automatically once connected.")
                        .font(.caption)
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
                    }
                    .buttonStyle(.borderless)
                }

            case .synthetic:
                EmptyView()
            }

            Picker("Channel", selection: $model.settings.channel) {
                ForEach(MeasurementChannel.allCases) { channel in
                    Text(channel.rawValue).tag(channel)
                }
            }
            Text(model.settings.channel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Start automatically on launch", isOn: $model.autostart)

            if let name = model.activeProfileName {
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings saved for \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Reset") { model.forgetCurrentDevice() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Forget the stored settings for this device and use defaults.")
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Gain

    private var gainSection: some View {
        Section("Gain / ISO") {
            LabeledContent("ISO") {
                Text(model.gain.currentISO.map(String.init) ?? "—")
                    .monospacedDigit()
            }
            if let shutter = model.gain.shutterLabel {
                LabeledContent("Shutter") { Text(shutter).monospacedDigit() }
            }
            if let aperture = model.gain.apertureLabel {
                LabeledContent("Aperture") { Text(aperture).monospacedDigit() }
            }

            Toggle("Auto-gain servo", isOn: $model.autoGainEnabled)
                .disabled(!model.isRunning)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Target peak").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%% FS", model.targetPeak * 100))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $model.targetPeak, in: 0.30...0.90)
            }

            if model.gain.canSetISO, !model.gain.availableISO.isEmpty {
                Picker("Set ISO", selection: Binding(
                    get: { model.gain.currentISO ?? model.gain.availableISO.first ?? 100 },
                    set: { value in Task { await model.setISOManually(value) } }
                )) {
                    ForEach(model.gain.availableISO, id: \.self) { iso in
                        Text("\(iso)").tag(iso)
                    }
                }
                .disabled(model.autoGainEnabled)
            }

            if let note = model.gain.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let advisory = model.advisory {
                Label(advisory, systemImage: "arrow.up.arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Calibration

    private var calibrationSection: some View {
        Section("Calibration") {
            LabeledContent("µm / pixel") {
                TextField(
                    "",
                    value: $model.settings.micronsPerPixel,
                    format: .number.precision(.fractionLength(0...4))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .multilineTextAlignment(.trailing)
            }

            Text(
                "Every reported size scales with this. The a7C's native pitch is 5.94 µm at "
                + "6000 px wide; a downscaled stream multiplies that by 6000 / frame width."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Use bare-sensor pitch") {
                model.settings.micronsPerPixel = model.assumedBareSensorScale()
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(model.displayImage == nil)
            .help("Set µm/pixel to 35600 / current frame width, for a lens-free sensor.")
        }
    }

    // MARK: - Background

    private var backgroundSection: some View {
        Section("Background") {
            HStack {
                Button("Capture dark frame") { model.captureDarkFrame() }
                    .disabled(!model.isRunning)
                if model.hasDarkFrame {
                    Button("Clear") { model.clearDarkFrame() }
                        .buttonStyle(.link)
                }
            }
            if let status = model.darkFrameStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.hasDarkFrame ? .green : .secondary)
            }
            Toggle("Subtract dark frame", isOn: $model.settings.subtractDarkFrame)
                .disabled(!model.hasDarkFrame)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Noise threshold").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1fσ", model.settings.noiseSigmaMultiplier))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $model.settings.noiseSigmaMultiplier, in: 0...6)
                Text("Locates the beam and sizes the aperture. Moments run on unclipped data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Aperture factor").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", model.settings.apertureFactor))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $model.settings.apertureFactor, in: 1.5...6)
                Text("ISO 11146 recommends 3× the beam diameter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            Picker("Colormap", selection: $model.colormap) {
                ForEach(Colormap.allCases) { map in
                    Text(map.rawValue).tag(map)
                }
            }
            Toggle("Logarithmic scale", isOn: $model.logarithmic)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Display gain").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", model.displayGain))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $model.displayGain, in: 1...50)
                Text("Affects the picture only, never the measurement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Centroid crosshair", isOn: $model.showCrosshair)
            Toggle("1/e² ellipse", isOn: $model.showEllipse)
            Toggle("Integration aperture", isOn: $model.showAperture)
        }
    }

    private var exportSection: some View {
        Section("Export") {
            Button("Save measurement…") { model.exportMeasurement() }
                .disabled(model.displayImage == nil)
            Text("Writes a PNG, a CSV of both profiles, and a JSON of the metrics.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
