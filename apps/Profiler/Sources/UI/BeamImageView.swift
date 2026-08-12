import SwiftUI

extension Color {
    /// The measurement area keeps a fixed dark ground in both appearances: colormaps are
    /// designed against black, and a light surround shifts how the low end reads.
    static let instrumentBackground = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let instrumentForeground = Color.white.opacity(0.55)
    static let instrumentGridline = Color.white.opacity(0.22)
}

/// The beam image with measurement overlays drawn in image coordinates.
struct BeamImageView: View {
    var model: ProfilerModel

    var body: some View {
        GeometryReader { geometry in
            let imageSize = currentImageSize
            let rect = Self.fittedRect(imageSize: imageSize, in: geometry.size)

            ZStack(alignment: .topLeading) {
                Color.instrumentBackground

                if let image = model.displayImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.metering.spot")
                            .font(.system(size: 38))
                        Text("No frames yet")
                            .font(.headline)
                        Text("Choose a backend and press Start.")
                            .font(.callout)
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    // Explicit light colours: the semantic styles resolve dark in light
                    // appearance and would vanish against this background.
                    .foregroundStyle(Color.instrumentForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Canvas { context, _ in
                    guard imageSize.width > 0, model.metrics.hasBeam else { return }
                    let scale = rect.width / imageSize.width
                    drawOverlays(context: context, origin: rect.origin, scale: scale)
                }
                .allowsHitTesting(false)

                if model.metrics.isSaturated {
                    saturationBanner
                        .padding(10)
                }
            }
        }
        .background(Color.instrumentBackground)
    }

    private var currentImageSize: CGSize {
        guard let image = model.displayImage else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    private var saturationBanner: some View {
        Label(
            "Saturated — \(percent(model.metrics.saturatedFraction)) of pixels clipped. "
            + "Widths are biased low until this clears.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private func percent(_ v: Double) -> String {
        String(format: "%.2f%%", v * 100)
    }

    private func drawOverlays(context: GraphicsContext, origin: CGPoint, scale: CGFloat) {
        let m = model.metrics

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale)
        }

        if model.showAperture, !m.aperture.isEmpty {
            let topLeft = point(Double(m.aperture.x0), Double(m.aperture.y0))
            let size = CGSize(
                width: CGFloat(m.aperture.width) * scale,
                height: CGFloat(m.aperture.height) * scale
            )
            var path = Path(CGRect(origin: topLeft, size: size))
            context.stroke(
                path,
                with: .color(.cyan.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
            path = Path()
        }

        let center = point(m.centroidX, m.centroidY)

        if model.showEllipse, m.majorDiameter > 0 {
            // Semi-axes are half the D4σ diameters, which is the 1/e² radius for a Gaussian.
            let semiMajor = CGFloat(m.majorDiameter / 2) * scale
            let semiMinor = CGFloat(m.minorDiameter / 2) * scale
            // Screen rows run downward, so the lab-frame azimuth negates on the way back.
            let rotation = Angle(degrees: -m.angleDegrees)

            var transform = CGAffineTransform.identity
                .translatedBy(x: center.x, y: center.y)
                .rotated(by: CGFloat(rotation.radians))
            let ellipse = CGRect(
                x: -semiMajor, y: -semiMinor,
                width: semiMajor * 2, height: semiMinor * 2
            )
            let path = CGPath(ellipseIn: ellipse, transform: &transform)
            context.stroke(
                Path(path),
                with: .color(.green),
                style: StrokeStyle(lineWidth: 1.5)
            )

            // Major axis tick, so the reported angle is visually verifiable.
            let dx = cos(rotation.radians) * semiMajor
            let dy = sin(rotation.radians) * semiMajor
            var axis = Path()
            axis.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            axis.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
            context.stroke(
                axis,
                with: .color(.green.opacity(0.6)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }

        if model.showCrosshair {
            var cross = Path()
            let arm: CGFloat = 14
            cross.move(to: CGPoint(x: center.x - arm, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - arm))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            context.stroke(cross, with: .color(.white), style: StrokeStyle(lineWidth: 1.2))
        }
    }

    /// Aspect-preserving fit, so pixels stay square and the overlays stay registered.
    static func fittedRect(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
