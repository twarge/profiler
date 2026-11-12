import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a publishing window sends over Labcast, and how it is encoded.
///
/// The viewer shows the publisher's numbers: the metrics travel whole and exact, and the
/// picture is only a picture — a compressed preview nothing is measured from.
enum BeamWire {
    /// Labcast app ID: Bonjour browsers filter on it.
    static let appID = "profiler"

    enum Topic {
        /// `BeamMetrics` for every analysed frame, profiles included. Every one is delivered,
        /// in order: the viewer's time series is a record of them.
        static let metrics = "beam/metrics"
        /// JPEG preview of the beam image as the publisher renders it. Droppable, and only
        /// encoded while somebody subscribes.
        static let image = "beam/image"
        /// `BeamRemoteState`, retained: what a viewer needs to label the numbers.
        static let state = "state"
        /// Request: set the camera's ISO. The body is the ISO as a JSON integer.
        static let setISO = "set-iso"
    }

    /// Longest side of the preview, in pixels. A PTP live view fits unscaled.
    static let previewMaxDimension = 1024
    static let previewQuality = 0.7

    // A measurement can carry a non-finite number — a fit that ran away, say — which plain
    // JSON refuses, taking the whole message with it.
    private static let infinity = "inf", negativeInfinity = "-inf", nan = "nan"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: infinity, negativeInfinity: negativeInfinity, nan: nan)
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: infinity, negativeInfinity: negativeInfinity, nan: nan)
        return try? decoder.decode(type, from: data)
    }

    static func previewJPEG(from image: CGImage) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: previewQuality
        ]
        if max(image.width, image.height) > previewMaxDimension {
            options[kCGImageDestinationImageMaxPixelSize] = previewMaxDimension
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decoded here, off the main thread, rather than lazily when first drawn.
    static func image(fromJPEG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

/// Everything about a publishing window that is state rather than measurement. Retained,
/// so a viewer that joins late labels its first numbers correctly.
struct BeamRemoteState: Codable, Equatable {
    /// The camera, as the publisher names it.
    var sourceName: String
    /// `ProfilerModel.SourceKind` raw value of the publisher's backend.
    var sourceKind: String
    var isRunning: Bool
    /// The publisher's operator is holding the frame.
    var isPaused: Bool
    /// Why the publisher's frames have stopped, in its own words.
    var interruption: String?
    /// Sensor scale: every length in `BeamMetrics` is in pixels of this size.
    var micronsPerPixel: Double
    var channel: MeasurementChannel
    /// Size of the analysed frame, which the metrics' pixel coordinates refer to. The
    /// preview image may be smaller.
    var frameWidth: Int
    var frameHeight: Int
    var gain: GainState
    /// The publisher's servo is driving the ISO, so a viewer's request would be refused.
    var autoGain: Bool
}

// MARK: - BeamMetrics on the wire

/// Hand-written so the two profiles — a float per pixel column and row, most of the
/// message — travel as packed little-endian Float32 (base64 in the JSON) rather than as
/// thousands of decimal numbers. Bit-exact, like everything else here.
extension BeamMetrics: Codable {
    private enum CodingKeys: String, CodingKey {
        case centroidX, centroidY, d4SigmaX, d4SigmaY, majorDiameter, minorDiameter
        case ellipticity, angleDegrees
        case peak, totalPower, backgroundMean, backgroundSigma
        case saturatedPixels, saturatedFraction
        case aperture, converged, iterations, hasBeam
        case profileX, profileY, fitX, fitY, measuredFWHMX, measuredFWHMY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        centroidX = try c.decode(Double.self, forKey: .centroidX)
        centroidY = try c.decode(Double.self, forKey: .centroidY)
        d4SigmaX = try c.decode(Double.self, forKey: .d4SigmaX)
        d4SigmaY = try c.decode(Double.self, forKey: .d4SigmaY)
        majorDiameter = try c.decode(Double.self, forKey: .majorDiameter)
        minorDiameter = try c.decode(Double.self, forKey: .minorDiameter)
        ellipticity = try c.decode(Double.self, forKey: .ellipticity)
        angleDegrees = try c.decode(Double.self, forKey: .angleDegrees)
        peak = try c.decode(Double.self, forKey: .peak)
        totalPower = try c.decode(Double.self, forKey: .totalPower)
        backgroundMean = try c.decode(Double.self, forKey: .backgroundMean)
        backgroundSigma = try c.decode(Double.self, forKey: .backgroundSigma)
        saturatedPixels = try c.decode(Int.self, forKey: .saturatedPixels)
        saturatedFraction = try c.decode(Double.self, forKey: .saturatedFraction)
        aperture = try c.decode(Aperture.self, forKey: .aperture)
        converged = try c.decode(Bool.self, forKey: .converged)
        iterations = try c.decode(Int.self, forKey: .iterations)
        hasBeam = try c.decode(Bool.self, forKey: .hasBeam)
        profileX = Self.unpack(try c.decode(Data.self, forKey: .profileX))
        profileY = Self.unpack(try c.decode(Data.self, forKey: .profileY))
        fitX = try c.decodeIfPresent(GaussianFit.Result.self, forKey: .fitX)
        fitY = try c.decodeIfPresent(GaussianFit.Result.self, forKey: .fitY)
        measuredFWHMX = try c.decodeIfPresent(Double.self, forKey: .measuredFWHMX)
        measuredFWHMY = try c.decodeIfPresent(Double.self, forKey: .measuredFWHMY)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(centroidX, forKey: .centroidX)
        try c.encode(centroidY, forKey: .centroidY)
        try c.encode(d4SigmaX, forKey: .d4SigmaX)
        try c.encode(d4SigmaY, forKey: .d4SigmaY)
        try c.encode(majorDiameter, forKey: .majorDiameter)
        try c.encode(minorDiameter, forKey: .minorDiameter)
        try c.encode(ellipticity, forKey: .ellipticity)
        try c.encode(angleDegrees, forKey: .angleDegrees)
        try c.encode(peak, forKey: .peak)
        try c.encode(totalPower, forKey: .totalPower)
        try c.encode(backgroundMean, forKey: .backgroundMean)
        try c.encode(backgroundSigma, forKey: .backgroundSigma)
        try c.encode(saturatedPixels, forKey: .saturatedPixels)
        try c.encode(saturatedFraction, forKey: .saturatedFraction)
        try c.encode(aperture, forKey: .aperture)
        try c.encode(converged, forKey: .converged)
        try c.encode(iterations, forKey: .iterations)
        try c.encode(hasBeam, forKey: .hasBeam)
        try c.encode(Self.pack(profileX), forKey: .profileX)
        try c.encode(Self.pack(profileY), forKey: .profileY)
        try c.encodeIfPresent(fitX, forKey: .fitX)
        try c.encodeIfPresent(fitY, forKey: .fitY)
        try c.encodeIfPresent(measuredFWHMX, forKey: .measuredFWHMX)
        try c.encodeIfPresent(measuredFWHMY, forKey: .measuredFWHMY)
    }

    private static func pack(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func unpack(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return (0..<(bytes.count / 4)).map { i in
            let bits = UInt32(bytes[4 * i]) | UInt32(bytes[4 * i + 1]) << 8
                | UInt32(bytes[4 * i + 2]) << 16 | UInt32(bytes[4 * i + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}
