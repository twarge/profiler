import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One measurement, captured whole: the analysed frame, the metrics, and the settings that
/// produced them, taken at the same instant so the exported artifacts cannot straddle a
/// frame boundary while capture keeps running.
///
/// Encoding is deferred: constructing this is a value copy, and the PNG, CSV, and JSON
/// bytes — including the colormap render itself — are only produced when a share target
/// or drop destination actually asks.
struct MeasurementExport {
    var frame: BeamFrame
    var colormap: Colormap
    var displayGain: Double
    var logarithmic: Bool
    var metrics: BeamMetrics
    var micronsPerPixel: Double
    var source: String
    var channel: String
    var noiseSigmaMultiplier: Double
    var apertureFactor: Double
    var darkFrameSubtracted: Bool
    var iso: Int?
    var shutter: String?
    var timestamp: Date

    /// Shared base name, so one export's files sort together wherever they land.
    var stem: String { "beam-" + Self.stampFormatter.string(from: timestamp) }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    func file(_ content: ExportFile.Content) -> ExportFile {
        ExportFile(content: content, export: self)
    }

    /// The complete measurement, as offered by the share sheet.
    var shareFiles: [ExportFile] {
        [file(.image), file(.profiles), file(.metrics)]
    }

    // MARK: - Encoders

    enum Axis { case x, y }

    /// PNG via ImageIO rather than the AppKit or UIKit image classes, which disagree about
    /// how a CGImage becomes file data and exist on only one platform each. Rendered from
    /// the analysed frame, so the picture and the metrics describe the same beam even
    /// though the live display has moved on.
    func pngData() throws -> Data {
        guard let image = BeamImageRenderer.makeImage(
                  frame: frame, colormap: colormap,
                  displayGain: displayGain, logarithmic: logarithmic
              ),
              let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data, UTType.png.identifier as CFString, 1, nil
              )
        else {
            throw NSError(
                domain: "Profiler", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Could not render the beam image."]
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "Profiler", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode the beam image as PNG."]
            )
        }
        return data as Data
    }

    func csvData(axes: [Axis]) -> Data {
        var text = "axis,index,position_um,intensity\n"
        if axes.contains(.x) {
            for (i, v) in metrics.profileX.enumerated() {
                let position = (Double(i) - metrics.centroidX) * micronsPerPixel
                text += "x,\(i),\(position),\(v)\n"
            }
        }
        if axes.contains(.y) {
            for (i, v) in metrics.profileY.enumerated() {
                let position = (Double(i) - metrics.centroidY) * micronsPerPixel
                text += "y,\(i),\(position),\(v)\n"
            }
        }
        return Data(text.utf8)
    }

    func jsonData() throws -> Data {
        let scale = micronsPerPixel
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "source": source,
            "frame_width_px": frame.width,
            "frame_height_px": frame.height,
            "microns_per_pixel": scale,
            "channel": channel,
            "noise_threshold_sigma": noiseSigmaMultiplier,
            "aperture_factor": apertureFactor,
            "dark_frame_subtracted": darkFrameSubtracted,
            "centroid_x_um": metrics.centroidX * scale,
            "centroid_y_um": metrics.centroidY * scale,
            "d4sigma_x_um": metrics.d4SigmaX * scale,
            "d4sigma_y_um": metrics.d4SigmaY * scale,
            "major_diameter_um": metrics.majorDiameter * scale,
            "minor_diameter_um": metrics.minorDiameter * scale,
            "ellipticity": metrics.ellipticity,
            "angle_deg": metrics.angleDegrees,
            "peak_fraction_full_scale": metrics.peak,
            "saturated_fraction": metrics.saturatedFraction,
            "saturated": metrics.isSaturated,
            "background_mean": metrics.backgroundMean,
            "background_sigma": metrics.backgroundSigma,
            "converged": metrics.converged,
            "iterations": metrics.iterations,
        ]
        if let iso { payload["iso"] = iso }
        if let shutter { payload["shutter"] = shutter }
        if let fit = metrics.fitX {
            payload["fit_x_d4sigma_um"] = fit.d4SigmaEquivalent * scale
            payload["fit_x_r_squared"] = fit.rSquared
        }
        if let fit = metrics.fitY {
            payload["fit_y_d4sigma_um"] = fit.d4SigmaEquivalent * scale
            payload["fit_y_r_squared"] = fit.rSquared
        }

        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}

/// One artifact of a measurement, typed for transfer: shareable through the share sheet
/// and draggable straight out of the views that show it.
///
/// A single type rather than one per artifact because `ShareLink` wants a homogeneous
/// collection; the exporting conditions steer each instance to the one representation
/// that matches its content, so a receiver is never offered a CSV under a PNG type.
struct ExportFile: Transferable {
    enum Content: Equatable {
        case image, profiles, profileX, profileY, metrics
    }

    var content: Content
    var export: MeasurementExport

    var filename: String {
        switch content {
        case .image: return export.stem + ".png"
        case .profiles: return export.stem + "-profiles.csv"
        case .profileX: return export.stem + "-profile-x.csv"
        case .profileY: return export.stem + "-profile-y.csv"
        case .metrics: return export.stem + "-metrics.json"
        }
    }

    var iconSystemName: String {
        switch content {
        case .image: return "photo"
        case .profiles, .profileX, .profileY: return "tablecells"
        case .metrics: return "curlybraces"
        }
    }

    /// The type this artifact transfers as, and the key the representations below are
    /// selected by — so a content case cannot end up offering one extension under a
    /// different transfer type.
    var contentType: UTType {
        switch content {
        case .image: return .png
        case .profiles, .profileX, .profileY: return .commaSeparatedText
        case .metrics: return .json
        }
    }

    func data() throws -> Data {
        switch content {
        case .image: return try export.pngData()
        case .profiles: return export.csvData(axes: [.x, .y])
        case .profileX: return export.csvData(axes: [.x])
        case .profileY: return export.csvData(axes: [.y])
        case .metrics: return try export.jsonData()
        }
    }

    /// One representation per exported type, each offered only for the contents that
    /// carry it.
    ///
    /// Built through the helper below, with every closure's types spelled out. Written
    /// as three inline `FileRepresentation`s with `$0` conditions instead, the builder's
    /// ten `buildBlock` arities and the untyped closures leave Xcode 26.6's type checker
    /// enough to explore that it gives up — "unable to type-check this expression in
    /// reasonable time" — even though Xcode 27's still manages it. The CI runners are on
    /// the former, so keep the annotations.
    static var transferRepresentation: some TransferRepresentation {
        fileRepresentation(.png)
        fileRepresentation(.commaSeparatedText)
        fileRepresentation(.json)
    }

    private static func fileRepresentation(
        _ type: UTType
    ) -> some TransferRepresentation<ExportFile> {
        let representation = FileRepresentation<ExportFile>(exportedContentType: type) {
            (file: ExportFile) async throws -> SentTransferredFile in
            SentTransferredFile(try file.writeTemporary(), allowAccessingOriginalFile: false)
        }
        return representation.exportingCondition { (file: ExportFile) -> Bool in
            file.contentType == type
        }
    }

    /// File transfers hand over a URL, so the bytes go through a uniquely-named temporary
    /// directory — which is also what lets the receiver see the real filename.
    private func writeTemporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try data().write(to: url)
        return url
    }
}
