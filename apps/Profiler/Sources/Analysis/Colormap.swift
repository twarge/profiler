import CoreGraphics
import Foundation

/// False-colour lookup tables for the beam image.
enum Colormap: String, CaseIterable, Identifiable, Codable {
    case grayscale = "Grayscale"
    case inferno = "Inferno"
    case viridis = "Viridis"
    case turbo = "Turbo"

    var id: String { rawValue }

    private var anchors: [(Double, Double, Double)] {
        switch self {
        case .grayscale:
            return [(0, 0, 0), (1, 1, 1)]
        case .inferno:
            return [
                (0.001, 0.000, 0.014), (0.159, 0.044, 0.329), (0.397, 0.083, 0.433),
                (0.622, 0.165, 0.388), (0.832, 0.284, 0.259), (0.961, 0.488, 0.084),
                (0.988, 0.745, 0.212), (0.988, 0.998, 0.645),
            ]
        case .viridis:
            return [
                (0.267, 0.005, 0.329), (0.283, 0.141, 0.458), (0.254, 0.265, 0.530),
                (0.207, 0.372, 0.553), (0.164, 0.471, 0.558), (0.128, 0.567, 0.551),
                (0.135, 0.659, 0.518), (0.267, 0.749, 0.441), (0.478, 0.821, 0.318),
                (0.741, 0.873, 0.150), (0.993, 0.906, 0.144),
            ]
        case .turbo:
            return [
                (0.190, 0.072, 0.232), (0.276, 0.383, 0.836), (0.180, 0.702, 0.900),
                (0.146, 0.912, 0.611), (0.529, 0.995, 0.246), (0.866, 0.887, 0.176),
                (0.988, 0.652, 0.211), (0.941, 0.313, 0.089), (0.720, 0.094, 0.024),
                (0.479, 0.012, 0.013),
            ]
        }
    }

    /// 256-entry BGRA table matching CGImage's little-endian premultiplied-first layout.
    func lookupTable() -> [UInt8] {
        let points = anchors
        var table = [UInt8](repeating: 255, count: 256 * 4)
        let segments = Double(points.count - 1)

        for i in 0..<256 {
            let t = Double(i) / 255.0
            let position = t * segments
            let index = min(points.count - 2, max(0, Int(position)))
            let localT = position - Double(index)
            let a = points[index]
            let b = points[index + 1]

            let r = a.0 + (b.0 - a.0) * localT
            let g = a.1 + (b.1 - a.1) * localT
            let bl = a.2 + (b.2 - a.2) * localT

            table[i * 4 + 0] = UInt8(max(0, min(255, bl * 255)))
            table[i * 4 + 1] = UInt8(max(0, min(255, g * 255)))
            table[i * 4 + 2] = UInt8(max(0, min(255, r * 255)))
            table[i * 4 + 3] = 255
        }
        return table
    }
}

enum BeamImageRenderer {

    /// Renders an intensity frame through a colormap.
    ///
    /// - Parameters:
    ///   - logarithmic: compresses the display range to reveal wings without changing
    ///     the measurement, which always runs on linear data.
    ///   - markSaturation: paints pixels at or above full scale pure red, so clipping is
    ///     visible rather than merely implied by the colormap's top entry.
    static func makeImage(
        frame: BeamFrame,
        colormap: Colormap,
        displayGain: Double = 1.0,
        logarithmic: Bool = false,
        markSaturation: Bool = true
    ) -> CGImage? {
        let w = frame.width
        let h = frame.height
        guard w > 0, h > 0, frame.pixels.count == w * h else { return nil }

        let lut = colormap.lookupTable()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)

        let logDenominator = log10(1 + 999.0)
        for i in 0..<(w * h) {
            let raw = frame.pixels[i]
            var v = Double(raw) * displayGain
            v = max(0, min(1, v))
            if logarithmic {
                v = log10(1 + 999.0 * v) / logDenominator
            }

            if markSaturation, raw >= 0.99 {
                bytes[i * 4 + 0] = 40
                bytes[i * 4 + 1] = 40
                bytes[i * 4 + 2] = 255
                bytes[i * 4 + 3] = 255
                continue
            }

            let index = min(255, max(0, Int(v * 255))) * 4
            bytes[i * 4 + 0] = lut[index + 0]
            bytes[i * 4 + 1] = lut[index + 1]
            bytes[i * 4 + 2] = lut[index + 2]
            bytes[i * 4 + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
