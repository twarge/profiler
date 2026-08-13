// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Renders the app icon into the asset catalog:
//
//   make icon
//
// The icon is the app's own picture — an astigmatic Gaussian through the same Turbo
// lookup table the beam view offers, cropped by the icon's own edges, with the D4σ
// ellipse dashed over it. Colormap.swift is compiled in rather than having its anchors
// copied here, so the icon's colours cannot drift from the app's.
//
// The PNGs are committed, so this only needs running when the design changes.
// Both platforms share one image set: the iOS entry is full-bleed because the
// system masks it, while the mac entries carry their own rounded body, inset and
// shadow, which is what the Dock expects.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design

/// The beam, in unit coordinates over the icon's content area, y downward.
struct Beam {
    /// Centred.
    var centerX = 0.5
    var centerY = 0.5
    /// 1/e² radii as a fraction of the icon's width. Large enough that the beam runs off
    /// the edges: the icon is a crop of a picture, not a specimen mounted in a frame.
    var waistX = 0.390
    var waistY = 0.293
    /// Major-axis azimuth, lab convention — the same tilt the synthetic source uses,
    /// so the icon shows an astigmatic beam rather than a circular blob.
    var angleDegrees = 22.0
    /// Peak as a fraction of full scale. A little under it, as the synthetic source's
    /// 0.55 is and as any properly exposed beam is, which also keeps the core off the
    /// very top of the Turbo ramp where it turns dark.
    var peak = 0.75
}

enum Palette {
    /// Ground, lit from the beam outwards. Close to the measurement area's own
    /// near-black, which is the ground the colormaps are designed against.
    static let groundInner: [CGFloat] = [0.086, 0.094, 0.129, 1]
    static let groundOuter: [CGFloat] = [0.020, 0.024, 0.039, 1]
    /// The contour. White, because Turbo owns every hue it might otherwise have used.
    static let overlay: [CGFloat] = [1, 1, 1, 1]
    /// Laid under the contour, so it reads as drawn on top of the beam rather than as
    /// another band of the colormap.
    static let overlayShadow: [CGFloat] = [0.020, 0.024, 0.039, 0.55]
    /// Hairline along the mac body's edge, so it stays a shape on a dark desktop.
    static let rim: [CGFloat] = [1, 1, 1, 0.10]
}

enum Icon {

    /// Fraction of the mac canvas the icon body occupies, and its corner radius —
    /// the proportions of Apple's macOS icon grid (824 and 185.4 on a 1024 canvas).
    static let macBodyFraction = 0.805
    static let macCornerFraction = 0.2250

    static let space = CGColorSpaceCreateDeviceRGB()

    static func color(_ c: [CGFloat]) -> CGColor { CGColor(colorSpace: space, components: c)! }

    enum Idiom { case mac, ios }

    // MARK: Beam bitmap

    /// The beam, rendered once at a comfortable resolution and scaled into each icon,
    /// which is what keeps the small sizes smooth.
    ///
    /// Row 0 is the top row, matching the y-downward coordinates everything else here
    /// is written in; `drawGlow` undoes the context flip so it lands that way up.
    static func beamGlow(resolution: Int, beam: Beam) -> CGImage? {
        let lut = Colormap.turbo.lookupTable()  // BGRA
        var bytes = [UInt8](repeating: 0, count: resolution * resolution * 4)

        let theta = -beam.angleDegrees * .pi / 180  // lab CCW → y-downward image coords
        let cosT = cos(theta)
        let sinT = sin(theta)

        for py in 0..<resolution {
            let y = (Double(py) + 0.5) / Double(resolution)
            for px in 0..<resolution {
                let x = (Double(px) + 0.5) / Double(resolution)
                let dx = x - beam.centerX
                let dy = y - beam.centerY
                let u = dx * cosT + dy * sinT
                let v = -dx * sinT + dy * cosT
                let exponent = -2 * (u * u / (beam.waistX * beam.waistX)
                    + v * v / (beam.waistY * beam.waistY))
                let intensity = beam.peak * (exponent > -50 ? exp(exponent) : 0)

                // A display gamma, as the beam view's log option is: it lifts the wings
                // so the spot spreads its rainbow over a real area rather than showing
                // as a red core with the whole ramp crowded into its edge.
                let display = pow(intensity, 0.45)
                let index = min(255, max(0, Int(display * 255))) * 4
                let b = Double(lut[index + 0]) / 255
                let g = Double(lut[index + 1]) / 255
                let r = Double(lut[index + 2]) / 255

                // Opacity has to come from the intensity, not from the colour's own
                // luminance: Turbo's ends are both dark, so a luminance rule would punch
                // a hole through the middle of the beam. Fully opaque well outside the
                // 1/e² contour and gone soon after, which keeps the colours solid to the
                // edge of the spot instead of washing them into the ground.
                let alpha = min(1, max(0, (display - 0.10) / 0.18))

                let o = (py * resolution + px) * 4
                bytes[o + 0] = UInt8(max(0, min(255, r * 255)))
                bytes[o + 1] = UInt8(max(0, min(255, g * 255)))
                bytes[o + 2] = UInt8(max(0, min(255, b * 255)))
                bytes[o + 3] = UInt8(max(0, min(255, alpha * 255)))
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: resolution,
            height: resolution,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: resolution * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: Drawing

    static func drawGround(_ ctx: CGContext, in rect: CGRect) {
        let colors = [color(Palette.groundInner), color(Palette.groundOuter)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])
        else { return }
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.40)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: rect.width * 0.78,
            options: [.drawsAfterEndLocation]
        )
    }

    /// `CGContext.draw` puts an image's first row at the top of the rect *in user
    /// space*, which in this y-downward context is the bottom of the icon — so the
    /// beam needs its own flip to come out the way it was generated.
    static func drawGlow(_ ctx: CGContext, _ glow: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(glow, in: rect)
        ctx.restoreGState()
    }

    /// Strokes twice, the white line over a wider dark copy of itself, so it stays a white
    /// line wherever it crosses the beam's own bright bands.
    static func strokeShadowed(_ ctx: CGContext, _ path: CGPath, lineWidth: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color(Palette.overlayShadow))
        ctx.setLineWidth(lineWidth * 1.8)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setStrokeColor(color(Palette.overlay))
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }

    /// The 1/e² contour, where the analyser draws its D4σ ellipse.
    ///
    /// Dashed, as the analyser's own axis and span markers are: a dashed contour reads as
    /// something drawn over the picture, where a solid ring of a colour the beam does not
    /// contain reads as part of it. The dashes scale with the stroke, so the pattern looks
    /// the same at every size instead of turning into a dotted line at the small ones.
    static func drawEllipse(_ ctx: CGContext, in rect: CGRect, beam: Beam, lineWidth: CGFloat) {
        let center = CGPoint(
            x: rect.minX + rect.width * beam.centerX,
            y: rect.minY + rect.height * beam.centerY
        )
        var transform = CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: CGFloat(-beam.angleDegrees * .pi / 180))  // lab CCW → y downward
        let semiMajor = CGFloat(beam.waistX) * rect.width
        let semiMinor = CGFloat(beam.waistY) * rect.height
        let box = CGRect(
            x: -semiMajor, y: -semiMinor,
            width: semiMajor * 2, height: semiMinor * 2
        )

        ctx.saveGState()
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: [lineWidth * 2.6, lineWidth * 1.9])
        strokeShadowed(ctx, CGPath(ellipseIn: box, transform: &transform), lineWidth: lineWidth)
        ctx.restoreGState()
    }

    static func render(pixels: Int, idiom: Idiom) -> CGImage? {
        // At 32 px and below the dashed contour collapses into a dotted smear over the
        // beam, so it drops out rather than turning to mush and the beam carries the icon
        // on its own — which it can, being the whole picture either way.
        let detailed = pixels >= 48
        let beam = Beam()
        guard let glow = beamGlow(resolution: 768, beam: beam) else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Work y-downward, matching the beam view's image coordinates.
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        let canvas = Double(pixels)
        // One rect for the ground, the beam and the contour alike. The beam is meant to
        // run off the edges, so an inset "safe area" would only put a dark border between
        // it and the crop — and the contour has to stay at the beam's own 1/e² radius,
        // which it cannot do if the two are laid out in rects of different sizes.
        let content: CGRect
        let bodyPath: CGPath

        switch idiom {
        case .ios:
            // Full bleed, because iOS and iPadOS mask the icon themselves.
            content = CGRect(x: 0, y: 0, width: canvas, height: canvas)
            bodyPath = CGPath(rect: content, transform: nil)
        case .mac:
            let side = (canvas * macBodyFraction).rounded()
            let inset = ((canvas - side) / 2).rounded()
            content = CGRect(x: inset, y: inset, width: side, height: side)
            bodyPath = CGPath(
                roundedRect: content,
                cornerWidth: side * macCornerFraction,
                cornerHeight: side * macCornerFraction,
                transform: nil
            )
            // The Dock's icons sit on the shelf rather than floating over it.
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: canvas * 0.010),
                blur: canvas * 0.020,
                color: CGColor(colorSpace: space, components: [0, 0, 0, 0.45])!
            )
            ctx.addPath(bodyPath)
            ctx.setFillColor(color(Palette.groundOuter))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()

        drawGround(ctx, in: content)
        drawGlow(ctx, glow, in: content)

        if detailed {
            drawEllipse(ctx, in: content, beam: beam, lineWidth: max(1, content.width * 0.018))
        }

        ctx.restoreGState()

        if idiom == .mac, detailed {
            ctx.addPath(bodyPath)
            ctx.setStrokeColor(color(Palette.rim))
            ctx.setLineWidth(max(1, canvas * 0.0035))
            ctx.strokePath()
        }

        return ctx.makeImage()
    }
}

// MARK: - Output

/// point size, scale — the sizes the Dock, Finder and About box ask for.
let macEntries: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

func contentsJSON() -> String {
    var images = [
        """
            {
              "filename" : "ios-1024.png",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            }
        """
    ]
    for entry in macEntries {
        images.append(
            """
                {
                  "filename" : "mac-\(entry.points * entry.scale).png",
                  "idiom" : "mac",
                  "scale" : "\(entry.scale)x",
                  "size" : "\(entry.points)x\(entry.points)"
                }
            """
        )
    }
    return """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "make-app-icon",
            "version" : 1
          }
        }

        """
}

let catalogContentsJSON = """
    {
      "info" : {
        "author" : "make-app-icon",
        "version" : 1
      }
    }

    """

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw Failure("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("cannot encode \(url.path)")
    }
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Entry point

@main
enum MakeAppIcon {

    static func main() {
        let catalog = URL(
            fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1]
                : "apps/Profiler/Assets.xcassets"
        )
        let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")

        do {
            try FileManager.default.createDirectory(
                at: iconSet, withIntermediateDirectories: true
            )

            var sizes = Set<Int>()
            for entry in macEntries {
                let pixels = entry.points * entry.scale
                // 32 pt @1x and 16 pt @2x are the same image.
                guard sizes.insert(pixels).inserted else { continue }
                guard let image = Icon.render(pixels: pixels, idiom: .mac) else {
                    throw Failure("cannot render mac \(pixels)")
                }
                try write(image, to: iconSet.appendingPathComponent("mac-\(pixels).png"))
            }

            guard let ios = Icon.render(pixels: 1024, idiom: .ios) else {
                throw Failure("cannot render ios 1024")
            }
            try write(ios, to: iconSet.appendingPathComponent("ios-1024.png"))

            try contentsJSON().write(
                to: iconSet.appendingPathComponent("Contents.json"),
                atomically: true, encoding: .utf8
            )
            try catalogContentsJSON.write(
                to: catalog.appendingPathComponent("Contents.json"),
                atomically: true, encoding: .utf8
            )

            print("==> Wrote \(sizes.count + 1) icons to \(iconSet.path)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
