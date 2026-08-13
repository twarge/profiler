import Foundation

/// A scalar the app can plot against time.
///
/// Beam drift is a time-domain question — is the centroid walking, is the waist breathing,
/// is the servo hunting — and none of it is visible in an instantaneous readout. Each case
/// knows how to pull itself out of a measurement and what units it lands in, so the plot
/// axis and the sidebar readout can never disagree about what a number means.
enum PlotQuantity: String, CaseIterable, Identifiable, Codable {
    case centroidX, centroidY
    case d4SigmaX, d4SigmaY, majorDiameter, minorDiameter
    case ellipticity, angle
    case peak, clippedFraction, background
    case iso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .centroidX: return "Centroid X"
        case .centroidY: return "Centroid Y"
        case .d4SigmaX: return "D4σ Horizontal"
        case .d4SigmaY: return "D4σ Vertical"
        case .majorDiameter: return "Major"
        case .minorDiameter: return "Minor"
        case .ellipticity: return "Ellipticity"
        case .angle: return "Angle"
        case .peak: return "Peak"
        case .clippedFraction: return "Clipped"
        case .background: return "Background"
        case .iso: return "ISO"
        }
    }

    /// Whether the raw value is in pixels and therefore scales with the calibration.
    private var isLength: Bool {
        switch self {
        case .centroidX, .centroidY, .d4SigmaX, .d4SigmaY, .majorDiameter, .minorDiameter:
            return true
        default:
            return false
        }
    }

    var unit: String {
        switch self {
        case .centroidX, .centroidY, .d4SigmaX, .d4SigmaY, .majorDiameter, .minorDiameter:
            return "µm"
        case .angle: return "°"
        case .peak, .clippedFraction: return "% FS"
        case .ellipticity, .background, .iso: return ""
        }
    }

    /// Current value in display units, or nil when the measurement does not carry it —
    /// a source with no ISO, or a frame with no beam. Nil is not plotted, so a dropout
    /// leaves a gap rather than a fabricated zero.
    func value(metrics: BeamMetrics, gain: GainState, micronsPerPixel: Double) -> Double? {
        if isLength {
            guard metrics.hasBeam else { return nil }
            let pixels: Double
            switch self {
            case .centroidX: pixels = metrics.centroidX
            case .centroidY: pixels = metrics.centroidY
            case .d4SigmaX: pixels = metrics.d4SigmaX
            case .d4SigmaY: pixels = metrics.d4SigmaY
            case .majorDiameter: pixels = metrics.majorDiameter
            case .minorDiameter: pixels = metrics.minorDiameter
            default: return nil
            }
            return pixels * micronsPerPixel
        }

        switch self {
        case .ellipticity: return metrics.hasBeam ? metrics.ellipticity : nil
        case .angle: return metrics.hasBeam ? metrics.angleDegrees : nil
        case .peak: return metrics.peak * 100
        case .clippedFraction: return metrics.saturatedFraction * 100
        case .background: return metrics.backgroundMean
        case .iso: return gain.currentISO.map(Double.init)
        default: return nil
        }
    }

    /// Readable value for a chart axis or legend. `value` is already in this quantity's
    /// units — microns for the lengths — so the calibration has been applied by here.
    func format(_ value: Double, figures: Int) -> String {
        func rounded(_ v: Double) -> String {
            MeasurementFormat.significant(v, figures: figures)
        }
        switch self {
        case .centroidX, .centroidY, .d4SigmaX, .d4SigmaY, .majorDiameter, .minorDiameter:
            return abs(value) >= 1000 ? rounded(value / 1000) + " mm" : rounded(value) + " µm"
        case .ellipticity: return rounded(value)
        case .angle: return rounded(value) + "°"
        case .peak, .clippedFraction: return rounded(value) + "%"
        case .background: return rounded(value)
        // A whole number the camera reports, not a measurement with figures to give.
        case .iso: return String(format: "%.0f", value)
        }
    }
}

/// One recorded point.
struct PlotSample {
    var time: Date
    var value: Double
}

/// Fixed-window history for every plottable quantity.
///
/// Sampled on a fixed cadence rather than per frame: drift is a slow phenomenon, and at 30
/// fps a one-minute window would be 1800 points per series redrawn every frame for no extra
/// information. Plot selection controls presentation only, so enabling any plot can reveal
/// the full retained window rather than beginning with an empty chart.
struct TimeSeriesRecorder {
    /// How often a sample is taken.
    var interval: TimeInterval = 0.2
    /// How much history is kept.
    var window: TimeInterval = 60

    private(set) var series: [PlotQuantity: [PlotSample]] = [:]
    private var lastSample: Date?

    var isEmpty: Bool { series.isEmpty }

    mutating func record(
        metrics: BeamMetrics,
        gain: GainState,
        micronsPerPixel: Double,
        now: Date = Date()
    ) {
        if let last = lastSample, now.timeIntervalSince(last) < interval { return }
        lastSample = now

        let cutoff = now.addingTimeInterval(-window)
        for quantity in PlotQuantity.allCases {
            var points = series[quantity] ?? []
            if let value = quantity.value(
                metrics: metrics, gain: gain, micronsPerPixel: micronsPerPixel
            ) {
                points.append(PlotSample(time: now, value: value))
            }
            if let first = points.first, first.time < cutoff {
                points.removeAll { $0.time < cutoff }
            }
            series[quantity] = points
        }
    }

    mutating func clear() {
        series.removeAll()
        lastSample = nil
    }
}
