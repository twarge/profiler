import Foundation

/// Nominal sensor geometry for cameras likely to be on the other end of the cable.
///
/// Pitch is stored as *sensor width and native pixel count* rather than as a µm figure,
/// because that is the pair that survives the stream being downscaled. A body reporting a
/// 1024-wide live view has the same 35.6 mm imager as when it writes a 6000-wide raw, so the
/// effective pitch is `width / streamed pixels` — nearly six times the native figure. Storing
/// only the native pitch would invite reading it straight off the label and being 6× wrong.
///
/// These are manufacturer figures for the imaging area, good to about a percent. They are a
/// starting point, not a calibration: for real work, measure a known target. The note in the
/// sidebar says which preset matched so the number in the field is never anonymous.
struct SensorPreset: Identifiable, Hashable {
    /// Substring matched case-insensitively against the device name the camera reports.
    /// Sony bodies enumerate as their model code (`ILCE-7C`), not their marketing name.
    var match: String
    var displayName: String
    /// Imaging area width in millimetres.
    var sensorWidthMM: Double
    /// Full-resolution pixel width, for the native pitch.
    var nativePixelWidth: Int

    var id: String { match }

    /// Pitch at full sensor resolution.
    var nativePitchMicrons: Double {
        sensorWidthMM * 1000 / Double(nativePixelWidth)
    }

    /// Pitch for a stream of the given width, which is what the analyser actually needs.
    /// A live-view frame is the same imager sampled more coarsely.
    func pitchMicrons(forFrameWidth width: Int) -> Double {
        guard width > 0 else { return nativePitchMicrons }
        return sensorWidthMM * 1000 / Double(width)
    }
}

enum SensorLibrary {

    /// Ordered most specific first: `ILCE-7RM4` has to be tested before `ILCE-7`, or every
    /// R body would match the plain a7 entry.
    static let presets: [SensorPreset] = [
        // Sony full frame
        SensorPreset(match: "ILCE-7RM5", displayName: "Sony α7R V",
                     sensorWidthMM: 35.7, nativePixelWidth: 9504),
        SensorPreset(match: "ILCE-7RM4", displayName: "Sony α7R IV",
                     sensorWidthMM: 35.7, nativePixelWidth: 9504),
        SensorPreset(match: "ILCE-7RM3", displayName: "Sony α7R III",
                     sensorWidthMM: 35.9, nativePixelWidth: 7952),
        SensorPreset(match: "ILCE-7SM3", displayName: "Sony α7S III",
                     sensorWidthMM: 35.6, nativePixelWidth: 4240),
        SensorPreset(match: "ILCE-7M4", displayName: "Sony α7 IV",
                     sensorWidthMM: 35.9, nativePixelWidth: 7008),
        SensorPreset(match: "ILCE-7M3", displayName: "Sony α7 III",
                     sensorWidthMM: 35.6, nativePixelWidth: 6000),
        // ILCE-7CR and ILCE-7CM2 must precede ILCE-7C: the plain a7C's match string is a
        // prefix of both, and a 61 MP body silently taking the 24 MP pitch would put every
        // reported width out by a factor of 1.6.
        SensorPreset(match: "ILCE-7CR", displayName: "Sony α7CR",
                     sensorWidthMM: 35.7, nativePixelWidth: 9504),
        SensorPreset(match: "ILCE-7CM2", displayName: "Sony α7C II",
                     sensorWidthMM: 35.9, nativePixelWidth: 7008),
        SensorPreset(match: "ILCE-7C", displayName: "Sony α7C",
                     sensorWidthMM: 35.6, nativePixelWidth: 6000),
        SensorPreset(match: "ILCE-1", displayName: "Sony α1",
                     sensorWidthMM: 35.9, nativePixelWidth: 8640),

        // Sony APS-C. Same 24 MP imager across this generation.
        SensorPreset(match: "ILCE-6700", displayName: "Sony α6700",
                     sensorWidthMM: 23.5, nativePixelWidth: 6192),
        SensorPreset(match: "ILCE-6600", displayName: "Sony α6600",
                     sensorWidthMM: 23.5, nativePixelWidth: 6000),
        SensorPreset(match: "ILCE-6400", displayName: "Sony α6400",
                     sensorWidthMM: 23.5, nativePixelWidth: 6000),
        SensorPreset(match: "ZV-E10", displayName: "Sony ZV-E10",
                     sensorWidthMM: 23.5, nativePixelWidth: 6000),
    ]

    /// First preset whose match string appears in the device name, or nil.
    static func preset(forDeviceName name: String?) -> SensorPreset? {
        guard let name, !name.isEmpty else { return nil }
        let haystack = name.uppercased()
        return presets.first { haystack.contains($0.match.uppercased()) }
    }
}
