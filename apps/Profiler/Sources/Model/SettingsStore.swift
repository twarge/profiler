import Foundation

/// Everything worth remembering about one physical camera.
///
/// Keyed per device because the settings that matter most — µm/pixel above all — describe
/// the *optical setup* that camera sits in, not a global preference. Swapping between a
/// bare-sensor a7C and a lensed webcam should not silently carry a calibration across.
struct DeviceProfile: Codable {
    var deviceName: String = ""
    var lastSeen: Date = Date()

    // Analysis
    var micronsPerPixel: Double = 5.94
    /// Derive the pitch from the streamed frame width instead of the field above, for a
    /// sensor with the lens off. Stored per device because it describes that camera's setup.
    var useBareSensorPitch: Bool = true
    var channel: MeasurementChannel = .green
    var noiseSigmaMultiplier: Double = 3.0
    var apertureFactor: Double = 3.0
    var subtractDarkFrame: Bool = true
    var fitProfiles: Bool = true

    // Gain servo
    var autoGainEnabled: Bool = true
    var targetPeak: Double = 0.70

    // Display
    var colormap: Colormap = .turbo
    var logarithmic: Bool = false
    var displayGain: Double = 1.0
    var showCrosshair: Bool = true
    var showEllipse: Bool = true
    var showMajorAxis: Bool = true
    var showProfiles: Bool = true
    var showPlotReadout: Bool = true
    var significantFigures: Int = 3
    var plotWindow: Double = 60
    var profileChartFraction: Double = 0.18

    // Sidebar presentation, stored with the source just like its measurement settings.
    var expandedSettingsSections: [String] = ["source", "gain"]
    var expandedMetricSections: [String] = [
        "position", "size", "shape", "signal", "truth"
    ]

    /// Which quantities the time-series panel is plotting. Per device because what is worth
    /// watching is a property of the setup: drift on a bench beam, ISO on a camera whose
    /// servo is hunting.
    var plottedQuantities: [PlotQuantity] = []
}

extension DeviceProfile {

    /// Decodes a stored profile field by field, taking the default for anything absent.
    ///
    /// A profile written by an earlier build has none of the keys added since, and the
    /// synthesised decoder treats a missing key as an error no matter how the property is
    /// defaulted. That error is silent here — the store falls back to a fresh profile — and
    /// it would take the µm/pixel calibration with it, which is the one setting in here that
    /// cannot be guessed again. So adding a field must never invalidate what is on disk.
    init(from decoder: Decoder) throws {
        let stored = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = DeviceProfile()

        deviceName = stored.value(.deviceName, fresh.deviceName)
        lastSeen = stored.value(.lastSeen, fresh.lastSeen)

        micronsPerPixel = stored.value(.micronsPerPixel, fresh.micronsPerPixel)
        useBareSensorPitch = stored.value(.useBareSensorPitch, fresh.useBareSensorPitch)
        channel = stored.value(.channel, fresh.channel)
        noiseSigmaMultiplier = stored.value(.noiseSigmaMultiplier, fresh.noiseSigmaMultiplier)
        apertureFactor = stored.value(.apertureFactor, fresh.apertureFactor)
        subtractDarkFrame = stored.value(.subtractDarkFrame, fresh.subtractDarkFrame)
        fitProfiles = stored.value(.fitProfiles, fresh.fitProfiles)

        autoGainEnabled = stored.value(.autoGainEnabled, fresh.autoGainEnabled)
        targetPeak = stored.value(.targetPeak, fresh.targetPeak)

        colormap = stored.value(.colormap, fresh.colormap)
        logarithmic = stored.value(.logarithmic, fresh.logarithmic)
        displayGain = stored.value(.displayGain, fresh.displayGain)
        showCrosshair = stored.value(.showCrosshair, fresh.showCrosshair)
        showEllipse = stored.value(.showEllipse, fresh.showEllipse)
        showMajorAxis = stored.value(.showMajorAxis, fresh.showMajorAxis)
        showProfiles = stored.value(.showProfiles, fresh.showProfiles)
        showPlotReadout = stored.value(.showPlotReadout, fresh.showPlotReadout)
        significantFigures = stored.value(.significantFigures, fresh.significantFigures)
        plotWindow = stored.value(.plotWindow, fresh.plotWindow)
        profileChartFraction = stored.value(.profileChartFraction, fresh.profileChartFraction)
        plottedQuantities = stored.value(.plottedQuantities, fresh.plottedQuantities)
        expandedSettingsSections = stored.value(
            .expandedSettingsSections, fresh.expandedSettingsSections)
        expandedMetricSections = stored.value(
            .expandedMetricSections, fresh.expandedMetricSections)
    }
}

private extension KeyedDecodingContainer {
    /// The stored value, or the fallback when the key is absent or unreadable. `try?`
    /// flattens the optional the missing-key case would otherwise add.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// App-level state, restored on launch regardless of which camera is attached.
struct AppState: Codable {
    var sourceKind: String = ProfilerModel.SourceKind.synthetic.rawValue
    var selectedPTPCameraID: String?
    var selectedUVCDeviceID: String?
    var autostart: Bool = true
}

/// JSON-in-UserDefaults. Small, atomic, and survives the app being force-quit, which a
/// hand-rolled file in Application Support would not without more care than this warrants.
final class SettingsStore {
    private let defaults: UserDefaults
    private let profilesKey = "deviceProfiles.v1"
    private let appStateKey = "appState.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - App state

    var appState: AppState {
        get {
            guard let data = defaults.data(forKey: appStateKey),
                  let decoded = try? JSONDecoder().decode(AppState.self, from: data)
            else { return AppState() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: appStateKey)
        }
    }

    // MARK: - Per-device profiles

    private var profiles: [String: DeviceProfile] {
        get {
            guard let data = defaults.data(forKey: profilesKey),
                  let decoded = try? JSONDecoder().decode([String: DeviceProfile].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: profilesKey)
        }
    }

    func profile(for key: String) -> DeviceProfile? {
        profiles[key]
    }

    func save(_ profile: DeviceProfile, for key: String) {
        var all = profiles
        var stamped = profile
        stamped.lastSeen = Date()
        all[key] = stamped
        profiles = all
    }

    /// Names of remembered devices, newest first — for showing the operator what is stored.
    func knownDevices() -> [(key: String, name: String, lastSeen: Date)] {
        profiles
            .map { ($0.key, $0.value.deviceName, $0.value.lastSeen) }
            .sorted { $0.2 > $1.2 }
    }

    func forget(key: String) {
        var all = profiles
        all.removeValue(forKey: key)
        profiles = all
    }

    func forgetAll() {
        defaults.removeObject(forKey: profilesKey)
    }
}
