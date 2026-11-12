// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Writes the app icon: an Icon Composer bundle for macOS and iOS, and a solid image
// stack for visionOS, which takes nothing from the bundle.
//
//   make icon
//
// The icon is the app's own picture — an astigmatic Gaussian through the same Turbo
// lookup table the beam view offers, cropped by the icon's own edges, with the D4σ
// ellipse dashed over it. Colormap.swift is compiled in rather than having its anchors
// copied here, so the icon's colours cannot drift from the app's.
//
// The bundle, apps/Profiler/AppIcon.icon, is icon.json plus one SVG per layer. The asset
// compiler turns it into every size each platform needs and applies the system's shape
// and its glass, dark, clear and tinted treatments, so the artwork is full bleed and
// carries no mask, rim or shadow of its own. Back to front:
//
//   fill      the ground the colormaps are designed against
//   Beam      the Gaussian, flat: a picture on a screen, not an object
//   Contour   the dashed ellipse, glass, floating over the picture
//
// The clear and tinted appearances keep only a layer's brightness, and Turbo's does not
// rise with intensity: its red core is darker than its yellow, so the beam would show
// as a ring around a hole the picture never had. Those appearances get the same beam
// through the Grayscale table instead.
//
// The stack, apps/Profiler/Assets.xcassets/AppIcon.solidimagestack, is one 1024 px
// bitmap per layer. visionOS crops them to a circle, sets them apart in depth and lights
// them. Both icons go by the name AppIcon, and each platform's build takes the one it
// understands. Back to front:
//
//   Back      the ground with the beam on it, opaque
//   Front     the dashed ellipse
//
// The beam is painted onto the back layer rather than given one of its own. visionOS
// lights and shadows an upper layer along its edge, and the beam has no edge: it fades
// out. It is the picture here as well, and the contour is what stands off it.
//
// Both are committed, so this only needs running when the design changes. To look at
// the bundle without building:
//
//   "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//       apps/Profiler/AppIcon.icon --export-image --output-file icon.png \
//       --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// with Dark, TintedLight, TintedDark, ClearLight or ClearDark for the other renditions.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design

/// Icon Composer's canvas, in points, y downward. visionOS asks for layers of as many
/// pixels, so the bitmaps are drawn in the same coordinates at one pixel to the point.
let canvas = 1024.0

/// The beam, in unit coordinates over the canvas, y downward.
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
    /// A display gamma, as the beam view's log option is: it lifts the wings so the
    /// spot spreads its rainbow over a real area rather than showing as a red core
    /// with the whole ramp crowded into its edge.
    var gamma = 0.45

    /// What the beam view would show at `rho`, the distance from the centre in units of
    /// the 1/e² radius along whichever direction it is measured.
    func display(_ rho: Double) -> Double {
        pow(peak * exp(-2 * rho * rho), gamma)
    }

    /// Opacity has to come from the intensity, not from the colour's own luminance:
    /// Turbo's ends are both dark, so a luminance rule would punch a hole through the
    /// middle of the beam. Fully opaque well outside the 1/e² contour and gone soon
    /// after, which keeps the colours solid to the edge of the spot instead of washing
    /// them into the ground.
    static let clearBelow = 0.10
    static let opaqueAbove = 0.28

    func coverage(_ rho: Double) -> Double {
        min(1, max(0, (display(rho) - Beam.clearBelow) / (Beam.opaqueAbove - Beam.clearBelow)))
    }

    /// Where the beam has faded out altogether, in units of the 1/e² radius.
    var edge: Double {
        (log(pow(peak, gamma) / Beam.clearBelow) / (2 * gamma)).squareRoot()
    }
}

enum Palette {
    /// Ground, lit from the top down. Close to the measurement area's own near-black,
    /// which is the ground the colormaps are designed against. Given for the dark
    /// appearance too, where the system would otherwise swap in its own charcoal.
    static let groundTop = (0.086, 0.094, 0.129)
    static let groundBottom = (0.020, 0.024, 0.039)
    /// The contour. White, because Turbo owns every hue it might otherwise have used.
    static let contour = (1.0, 1.0, 1.0)
}

enum Contour {
    /// A dashed contour reads as something drawn over the picture, where a solid ring
    /// of a colour the beam does not contain reads as part of it. The count is a
    /// multiple of four and a dash is centred on the major axis, so the pattern closes
    /// on itself without a seam and a dash sits on each end of both axes.
    static let dashes = 24
    /// The share of each period that is dash rather than gap.
    static let duty = 0.58
    static let lineWidth = 22.0
}

// MARK: - Layers

func number(_ value: Double, places: Int = 2) -> String {
    var text = String(format: "%.\(places)f", value)
    if text.contains(".") {
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
    }
    return text == "-0" ? "0" : text
}

func svg(_ body: [String]) -> String {
    let size = number(canvas)
    return (["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size)\" height=\"\(size)\" "
        + "viewBox=\"0 0 \(size) \(size)\">"]
        + body.map { "  " + $0 }
        + ["</svg>", ""]).joined(separator: "\n")
}

/// The beam as one radial gradient, stretched and turned into the beam's ellipse. Each
/// stop is looked up in the app's own table the way the beam view looks a pixel up.
///
/// The gradient is laid out in user space and carries the whole transform itself. The
/// plainer way to write this, a turned ellipse filled with a bounding-box gradient, does
/// not survive Icon Composer: once the shape has a transform it draws the gradient at
/// about twice its size, and the ellipse ends halfway down the ramp.
func beamLayer(_ beam: Beam, through colormap: Colormap) -> String {
    let lut = colormap.lookupTable()  // BGRA
    let steps = 48
    let edge = beam.edge

    var body = [
        "<defs>",
        "  <radialGradient id=\"beam\" gradientUnits=\"userSpaceOnUse\" cx=\"0\" cy=\"0\" r=\"1\" "
            + "gradientTransform=\"translate(\(number(beam.centerX * canvas)) "
            + "\(number(beam.centerY * canvas))) "
            // Lab angles run counter-clockwise; SVG's run clockwise, y being downward.
            + "rotate(\(number(-beam.angleDegrees))) "
            + "scale(\(number(beam.waistX * canvas * edge)) "
            + "\(number(beam.waistY * canvas * edge)))\">",
    ]
    for step in 0...steps {
        let offset = Double(step) / Double(steps)
        let rho = offset * edge
        let index = min(255, max(0, Int(beam.display(rho) * 255))) * 4
        let color = String(format: "#%02X%02X%02X", lut[index + 2], lut[index + 1], lut[index])
        let coverage = step == steps ? 0 : beam.coverage(rho)
        let opacity = coverage < 1 ? " stop-opacity=\"\(number(coverage, places: 3))\"" : ""
        body.append(
            "    <stop offset=\"\(number(offset, places: 4))\" stop-color=\"\(color)\"\(opacity)/>"
        )
    }
    body += [
        "  </radialGradient>",
        "</defs>",
        "<rect width=\"\(number(canvas))\" height=\"\(number(canvas))\" fill=\"url(#beam)\"/>",
    ]
    return svg(body)
}

/// The 1/e² contour, where the analyser draws its D4σ ellipse, cut into dashes.
///
/// The dashes are laid out by arc length rather than left to a dash pattern, which
/// would start wherever the renderer starts the ellipse and end with whatever fraction
/// of a dash is left over.
struct Dashes {
    /// The ellipse: semi-axes and centre in points, and its turn in radians, clockwise
    /// as drawn, y being downward.
    let a: Double
    let b: Double
    let turn: Double
    let cx: Double
    let cy: Double
    /// Each dash's two ends as the ellipse's parameter, the start below the end.
    let spans: [(start: Double, end: Double)]

    init(_ beam: Beam) {
        let a = beam.waistX * canvas
        let b = beam.waistY * canvas
        self.a = a
        self.b = b
        turn = -beam.angleDegrees * .pi / 180
        cx = beam.centerX * canvas
        cy = beam.centerY * canvas

        // Arc length along the ellipse against its parameter, tabulated finely enough
        // that linear interpolation between entries is exact to well under a hundredth
        // of a point.
        let samples = 7200
        var lengths = [0.0]
        lengths.reserveCapacity(samples + 1)
        var previous = (x: a, y: 0.0)
        for i in 1...samples {
            let t = 2 * Double.pi * Double(i) / Double(samples)
            let point = (x: a * cos(t), y: b * sin(t))
            lengths.append(lengths[i - 1] + hypot(point.x - previous.x, point.y - previous.y))
            previous = point
        }
        let perimeter = lengths[samples]

        /// Not wrapped into one turn: a dash that straddles the start of the ellipse
        /// begins at a negative parameter, so its start stays below its end.
        func parameter(at distance: Double) -> Double {
            let turns = (distance / perimeter).rounded(.down)
            let s = distance - turns * perimeter
            var low = 0
            var high = samples
            while high - low > 1 {
                let middle = (low + high) / 2
                if lengths[middle] <= s { low = middle } else { high = middle }
            }
            let fraction = (s - lengths[low]) / (lengths[high] - lengths[low])
            return 2 * Double.pi * (turns + (Double(low) + fraction) / Double(samples))
        }

        let period = perimeter / Double(Contour.dashes)
        let half = period * Contour.duty / 2
        spans = (0..<Contour.dashes).map { dash in
            let middle = Double(dash) * period
            return (parameter(at: middle - half), parameter(at: middle + half))
        }
    }

    func point(_ t: Double) -> (x: Double, y: Double) {
        let x = a * cos(t)
        let y = b * sin(t)
        return (cx + x * cos(turn) - y * sin(turn), cy + x * sin(turn) + y * cos(turn))
    }
}

/// The contour as one arc per dash.
func contourLayer(_ beam: Beam) -> String {
    let dashes = Dashes(beam)
    let radii = "\(number(dashes.a)) \(number(dashes.b)) \(number(-beam.angleDegrees))"
    let stroke = String(
        format: "#%02X%02X%02X",
        Int((Palette.contour.0 * 255).rounded()),
        Int((Palette.contour.1 * 255).rounded()),
        Int((Palette.contour.2 * 255).rounded())
    )

    var body = [
        "<g fill=\"none\" stroke=\"\(stroke)\" "
            + "stroke-width=\"\(number(Contour.lineWidth))\" stroke-linecap=\"butt\">"
    ]
    for span in dashes.spans {
        let start = dashes.point(span.start)
        let end = dashes.point(span.end)
        body.append(
            "  <path d=\"M\(number(start.x)) \(number(start.y)) "
                + "A\(radii) 0 1 \(number(end.x)) \(number(end.y))\"/>"
        )
    }
    body.append("</g>")
    return svg(body)
}

// MARK: - Document

func srgb(_ c: (Double, Double, Double)) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", c.0, c.1, c.2)
}

/// icon.json, in the layout Icon Composer itself saves. Groups run front to back.
func document() -> String {
    let ground = """
        {
                "linear-gradient" : [
                  "\(srgb(Palette.groundTop))",
                  "\(srgb(Palette.groundBottom))"
                ]
              }
        """
    return """
        {
          "fill-specializations" : [
            {
              "value" : \(ground)
            },
            {
              "appearance" : "dark",
              "value" : \(ground)
            }
          ],
          "groups" : [
            {
              "layers" : [
                {
                  "image-name" : "Contour.svg",
                  "name" : "Contour"
                }
              ],
              "shadow" : {
                "kind" : "neutral",
                "opacity" : 0.5
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            },
            {
              "layers" : [
                {
                  "glass" : false,
                  "image-name-specializations" : [
                    {
                      "value" : "Beam.svg"
                    },
                    {
                      "appearance" : "tinted",
                      "value" : "Beam-Mono.svg"
                    }
                  ],
                  "name" : "Beam"
                }
              ],
              "shadow" : {
                "kind" : "neutral",
                "opacity" : 0
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            }
          ],
          "supported-platforms" : {
            "squares" : "shared"
          }
        }

        """
}

// MARK: - visionOS layers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// The back layer: the ground with the beam on it, opaque. Each pixel is worked out the
/// way the beam view works one out, which is the picture the vector layer's gradient
/// stands in for.
func pictureLayer(_ beam: Beam, through colormap: Colormap) -> CGImage? {
    let lut = colormap.lookupTable()  // BGRA
    let size = Int(canvas)
    var bytes = [UInt8](repeating: 255, count: size * size * 4)

    let turn = -beam.angleDegrees * .pi / 180  // lab CCW → y-downward image coords
    let cosT = cos(turn)
    let sinT = sin(turn)
    let top = [Palette.groundTop.0, Palette.groundTop.1, Palette.groundTop.2]
    let bottom = [Palette.groundBottom.0, Palette.groundBottom.1, Palette.groundBottom.2]

    for py in 0..<size {
        let y = (Double(py) + 0.5) / canvas
        let ground = (0..<3).map { top[$0] + (bottom[$0] - top[$0]) * y }
        for px in 0..<size {
            let dx = (Double(px) + 0.5) / canvas - beam.centerX
            let dy = y - beam.centerY
            let u = (dx * cosT + dy * sinT) / beam.waistX
            let v = (-dx * sinT + dy * cosT) / beam.waistY
            let rho = (u * u + v * v).squareRoot()
            let coverage = beam.coverage(rho)

            // Between the table's entries, so that its 256 colours do not show as rings
            // at this size.
            let position = min(255, max(0, beam.display(rho) * 255))
            let index = min(254, Int(position))
            let fraction = position - Double(index)

            let o = (py * size + px) * 4
            for channel in 0..<3 {
                let low = Double(lut[index * 4 + 2 - channel])
                let high = Double(lut[index * 4 + 6 - channel])
                let color = (low + (high - low) * fraction) / 255
                let value = ground[channel] + (color - ground[channel]) * coverage
                bytes[o + channel] = UInt8((min(1, max(0, value)) * 255).rounded())
            }
        }
    }

    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: size,
        height: size,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: size * 4,
        space: sRGB,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

/// The front layer: the dashes on nothing. No shadow or dark edge of their own, since
/// visionOS casts the shadow of an upper layer itself.
func contourImage(_ beam: Beam) -> CGImage? {
    let size = Int(canvas)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // y downward, as the vector layers are.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    // The unit circle onto the ellipse. Only the path goes through it, so the stroke
    // keeps one width all the way round.
    let dashes = Dashes(beam)
    let onto = CGAffineTransform(translationX: dashes.cx, y: dashes.cy)
        .rotated(by: dashes.turn)
        .scaledBy(x: dashes.a, y: dashes.b)
    let path = CGMutablePath()
    for span in dashes.spans {
        path.move(to: CGPoint(x: cos(span.start), y: sin(span.start)), transform: onto)
        path.addArc(
            center: .zero, radius: 1,
            startAngle: span.start, endAngle: span.end, clockwise: false,
            transform: onto
        )
    }

    let color = [Palette.contour.0, Palette.contour.1, Palette.contour.2, 1].map { CGFloat($0) }
    context.setStrokeColor(CGColor(colorSpace: sRGB, components: color)!)
    context.setLineWidth(Contour.lineWidth)
    context.setLineCap(.butt)
    context.addPath(path)
    context.strokePath()
    return context.makeImage()
}

// MARK: - Asset catalog

/// A Contents.json as Xcode saves one, its keys in alphabetical order: `images` goes
/// before `info` and `layers` after it.
func catalogContents(images: String? = nil, layers: String? = nil) -> String {
    let info = [
        "  \"info\" : {",
        "    \"author\" : \"xcode\",",
        "    \"version\" : 1",
        "  }",
    ].joined(separator: "\n")
    return "{\n" + [images, info, layers].compactMap { $0 }.joined(separator: ",\n") + "\n}\n"
}

/// A solid image stack, in the layout Xcode itself saves: a folder per layer, front to
/// back, each holding an image set with the one bitmap, 1024 px declared as 512 pt at 2x.
func writeStack(_ layers: [(name: String, image: CGImage)], to stack: URL) throws {
    let files = FileManager.default
    try files.createDirectory(at: stack, withIntermediateDirectories: true)

    let list = layers.map { layer in
        [
            "    {",
            "      \"filename\" : \"\(layer.name).solidimagestacklayer\"",
            "    }",
        ].joined(separator: "\n")
    }.joined(separator: ",\n")
    try write(
        catalogContents(layers: "  \"layers\" : [\n\(list)\n  ]"),
        to: stack.appendingPathComponent("Contents.json")
    )

    for layer in layers {
        let folder = stack.appendingPathComponent("\(layer.name).solidimagestacklayer")
        let imageSet = folder.appendingPathComponent("Content.imageset")
        try files.createDirectory(at: imageSet, withIntermediateDirectories: true)
        try write(catalogContents(), to: folder.appendingPathComponent("Contents.json"))

        let images = [
            "  \"images\" : [",
            "    {",
            "      \"filename\" : \"\(layer.name).png\",",
            "      \"idiom\" : \"vision\",",
            "      \"scale\" : \"2x\"",
            "    }",
            "  ]",
        ].joined(separator: "\n")
        try write(
            catalogContents(images: images),
            to: imageSet.appendingPathComponent("Contents.json")
        )

        let png = imageSet.appendingPathComponent("\(layer.name).png")
        guard let destination = CGImageDestinationCreateWithURL(
            png as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw Failure("cannot write \(png.path)")
        }
        CGImageDestinationAddImage(destination, layer.image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure("cannot encode \(png.path)")
        }
    }
}

func write(_ text: String, to url: URL) throws {
    guard let data = text.data(using: .utf8) else {
        throw Failure("cannot encode \(url.path)")
    }
    try data.write(to: url)
}

// MARK: - Entry point

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
enum MakeAppIcon {

    static func main() {
        let app = URL(
            fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1]
                : "apps/Profiler"
        )
        let bundle = app.appendingPathComponent("AppIcon.icon")
        let assets = bundle.appendingPathComponent("Assets")
        let catalog = app.appendingPathComponent("Assets.xcassets")
        let stack = catalog.appendingPathComponent("AppIcon.solidimagestack")
        let beam = Beam()

        let vectors: [(URL, String)] = [
            (assets.appendingPathComponent("Beam.svg"), beamLayer(beam, through: .turbo)),
            (assets.appendingPathComponent("Beam-Mono.svg"), beamLayer(beam, through: .grayscale)),
            (assets.appendingPathComponent("Contour.svg"), contourLayer(beam)),
            (bundle.appendingPathComponent("icon.json"), document()),
        ]

        do {
            let files = FileManager.default

            // Start from nothing, so a layer the design no longer has does not linger.
            if files.fileExists(atPath: bundle.path) {
                try files.removeItem(at: bundle)
            }
            try files.createDirectory(at: assets, withIntermediateDirectories: true)
            for (url, text) in vectors {
                try write(text, to: url)
            }
            print("==> Wrote \(vectors.count - 1) layers to \(bundle.path)")

            guard let picture = pictureLayer(beam, through: .turbo),
                let contour = contourImage(beam)
            else {
                throw Failure("cannot draw the visionOS layers")
            }
            // The catalog may come to hold other things; only the stack is replaced.
            if files.fileExists(atPath: stack.path) {
                try files.removeItem(at: stack)
            }
            try files.createDirectory(at: catalog, withIntermediateDirectories: true)
            let contents = catalog.appendingPathComponent("Contents.json")
            if !files.fileExists(atPath: contents.path) {
                try write(catalogContents(), to: contents)
            }
            let layers = [(name: "Front", image: contour), (name: "Back", image: picture)]
            try writeStack(layers, to: stack)
            print("==> Wrote \(layers.count) layers to \(stack.path)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
