// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Writes the app icon as an Icon Composer bundle, apps/Profiler/AppIcon.icon:
//
//   make icon
//
// The icon is the app's own picture — an astigmatic Gaussian through the same Turbo
// lookup table the beam view offers, cropped by the icon's own edges, with the D4σ
// ellipse dashed over it. Colormap.swift is compiled in rather than having its anchors
// copied here, so the icon's colours cannot drift from the app's.
//
// The bundle is icon.json plus one SVG per layer. The asset compiler turns it into
// every size each platform needs and applies the system's shape and its glass, dark,
// clear and tinted treatments, so the artwork is full bleed and carries no mask, rim or
// shadow of its own. Back to front:
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
// The bundle is committed, so this only needs running when the design changes. To look
// at the result without building:
//
//   "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//       apps/Profiler/AppIcon.icon --export-image --output-file icon.png \
//       --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// with Dark, TintedLight, TintedDark, ClearLight or ClearDark for the other renditions.

import Foundation

// MARK: - Design

/// Icon Composer's canvas, in points, y downward.
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
    static let contour = "#FFFFFF"
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

/// The 1/e² contour, where the analyser draws its D4σ ellipse, as one arc per dash.
///
/// The dashes are laid out by arc length rather than left to `stroke-dasharray`, which
/// would start the pattern wherever the renderer starts the ellipse and end it with
/// whatever fraction of a dash is left over.
func contourLayer(_ beam: Beam) -> String {
    let a = beam.waistX * canvas
    let b = beam.waistY * canvas
    let turn = -beam.angleDegrees * .pi / 180
    let cx = beam.centerX * canvas
    let cy = beam.centerY * canvas

    // Arc length along the ellipse against its parameter, tabulated finely enough that
    // linear interpolation between entries is exact to well under a hundredth of a point.
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

    func point(at distance: Double) -> (x: Double, y: Double) {
        let s = (distance.truncatingRemainder(dividingBy: perimeter) + perimeter)
            .truncatingRemainder(dividingBy: perimeter)
        var low = 0
        var high = samples
        while high - low > 1 {
            let middle = (low + high) / 2
            if lengths[middle] <= s { low = middle } else { high = middle }
        }
        let fraction = (s - lengths[low]) / (lengths[high] - lengths[low])
        let t = 2 * Double.pi * (Double(low) + fraction) / Double(samples)
        let x = a * cos(t)
        let y = b * sin(t)
        return (cx + x * cos(turn) - y * sin(turn), cy + x * sin(turn) + y * cos(turn))
    }

    let period = perimeter / Double(Contour.dashes)
    let half = period * Contour.duty / 2
    let radii = "\(number(a)) \(number(b)) \(number(-beam.angleDegrees))"

    var body = [
        "<g fill=\"none\" stroke=\"\(Palette.contour)\" "
            + "stroke-width=\"\(number(Contour.lineWidth))\" stroke-linecap=\"butt\">"
    ]
    for dash in 0..<Contour.dashes {
        let middle = Double(dash) * period
        let start = point(at: middle - half)
        let end = point(at: middle + half)
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

// MARK: - Entry point

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
enum MakeAppIcon {

    static func main() {
        let bundle = URL(
            fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1]
                : "apps/Profiler/AppIcon.icon"
        )
        let assets = bundle.appendingPathComponent("Assets")
        let beam = Beam()

        let files: [(URL, String)] = [
            (assets.appendingPathComponent("Beam.svg"), beamLayer(beam, through: .turbo)),
            (assets.appendingPathComponent("Beam-Mono.svg"), beamLayer(beam, through: .grayscale)),
            (assets.appendingPathComponent("Contour.svg"), contourLayer(beam)),
            (bundle.appendingPathComponent("icon.json"), document()),
        ]

        do {
            // Start from nothing, so a layer the design no longer has does not linger.
            if FileManager.default.fileExists(atPath: bundle.path) {
                try FileManager.default.removeItem(at: bundle)
            }
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            for (url, text) in files {
                guard let data = text.data(using: .utf8) else {
                    throw Failure("cannot encode \(url.path)")
                }
                try data.write(to: url)
            }
            print("==> Wrote \(files.count - 1) layers to \(bundle.path)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
