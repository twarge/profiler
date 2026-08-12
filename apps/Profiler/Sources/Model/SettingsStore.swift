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
    var channel: MeasurementChannel = .green
    var noiseSigmaMultiplier: Double = 3.0
    var apertureFactor: Double = 3.0
    var subtractDarkFrame: Bool = true

    // Gain servo
    var autoGainEnabled: Bool = false
    var targetPeak: Double = 0.70

    // Display
    var colormap: Colormap = .inferno
    var logarithmic: Bool = false
    var displayGain: Double = 1.0
    var showCrosshair: Bool = true
    var showEllipse: Bool = true
    var showAperture: Bool = true
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
