import Foundation

/// A single-channel intensity frame, normalised to 0...1 where 1.0 is sensor full scale.
struct BeamFrame {
    var width: Int
    var height: Int
    var pixels: [Float]
    var timestamp: Date

    init(width: Int, height: Int, pixels: [Float], timestamp: Date = Date()) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.timestamp = timestamp
    }

    var count: Int { width * height }

    @inline(__always)
    func at(_ x: Int, _ y: Int) -> Float { pixels[y * width + x] }
}

/// Which channel of a colour frame to measure.
///
/// The a7C has a Bayer CFA, so every channel is spatially undersampled. Green has twice the
/// sampling density of red or blue and is usually the best single-channel choice; luma is
/// smoother but mixes channels with different spectral responses, which matters if the beam
/// is monochromatic.
enum MeasurementChannel: String, CaseIterable, Identifiable, Codable {
    case luma = "Luma"
    case green = "Green"
    case red = "Red"
    case blue = "Blue"
    case maxRGB = "Max RGB"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .luma: return "Rec.709 weighted sum. Smoothest, but mixes channels."
        case .green: return "Highest Bayer sampling density. Best default for 500–580 nm."
        case .red: return "Use for 600–700 nm sources."
        case .blue: return "Use for 400–490 nm sources."
        case .maxRGB: return "Per-pixel channel maximum. Widest spectral coverage, non-linear."
        }
    }
}

/// Rectangular integration aperture in pixel coordinates.
struct Aperture: Equatable {
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int

    var width: Int { max(0, x1 - x0) }
    var height: Int { max(0, y1 - y0) }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    static func full(width: Int, height: Int) -> Aperture {
        Aperture(x0: 0, y0: 0, x1: width, y1: height)
    }

    func clamped(toWidth w: Int, height h: Int) -> Aperture {
        Aperture(
            x0: max(0, min(x0, w)),
            y0: max(0, min(y0, h)),
            x1: max(0, min(x1, w)),
            y1: max(0, min(y1, h))
        )
    }
}
