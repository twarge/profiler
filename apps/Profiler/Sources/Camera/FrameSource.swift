import CoreGraphics
import CoreVideo
import Foundation

/// What the active source can tell us, and let us change, about sensor gain.
struct GainState {
    var canReadISO = false
    var canSetISO = false
    var currentISO: Int?
    var availableISO: [Int] = []
    var shutterLabel: String?
    var apertureLabel: String?
    /// Set when the source knows the gain but can't change it, e.g. UVC streaming where
    /// exposure lives on the camera body. The UI turns the servo into an advisory.
    var advisoryOnly = false
    var note: String?
}

protocol FrameSource: AnyObject {
    var displayName: String { get }
    var onFrame: ((BeamFrame) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var measurementChannel: MeasurementChannel { get set }

    func start() async throws
    func stop() async
    func gainState() async -> GainState
    func setISO(_ value: Int) async throws
}

extension FrameSource {
    func gainState() async -> GainState { GainState() }
    func setISO(_ value: Int) async throws {}
}

/// Converts captured images into single-channel float frames.
enum FrameConverter {

    static func beamFrame(
        from image: CGImage,
        channel: MeasurementChannel
    ) -> BeamFrame? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var pixels = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4 + 0]) / 255
            let g = Float(rgba[i * 4 + 1]) / 255
            let b = Float(rgba[i * 4 + 2]) / 255
            pixels[i] = combine(r: r, g: g, b: b, channel: channel)
        }
        return BeamFrame(width: w, height: h, pixels: pixels)
    }

    static func beamFrame(
        from pixelBuffer: CVPixelBuffer,
        channel: MeasurementChannel
    ) -> BeamFrame? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }

        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            // The luma plane is full resolution and already demosaiced by the camera,
            // so for luma measurements this is the cleanest path — no colour conversion.
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)

            // Video range packs 16...235; rescale so full scale means full scale.
            let isVideoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let offset: Float = isVideoRange ? 16 : 0
            let span: Float = isVideoRange ? 219 : 255

            var pixels = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = y * stride
                for x in 0..<w {
                    let v = (Float(ptr[row + x]) - offset) / span
                    pixels[y * w + x] = max(0, min(1, v))
                }
            }
            return BeamFrame(width: w, height: h, pixels: pixels)

        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            var pixels = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = y * stride
                for x in 0..<w {
                    let b = Float(ptr[row + x * 4 + 0]) / 255
                    let g = Float(ptr[row + x * 4 + 1]) / 255
                    let r = Float(ptr[row + x * 4 + 2]) / 255
                    pixels[y * w + x] = combine(r: r, g: g, b: b, channel: channel)
                }
            }
            return BeamFrame(width: w, height: h, pixels: pixels)

        default:
            return nil
        }
    }

    @inline(__always)
    private static func combine(
        r: Float, g: Float, b: Float, channel: MeasurementChannel
    ) -> Float {
        switch channel {
        case .luma: return 0.2126 * r + 0.7152 * g + 0.0722 * b
        case .green: return g
        case .red: return r
        case .blue: return b
        case .maxRGB: return max(r, max(g, b))
        }
    }
}
