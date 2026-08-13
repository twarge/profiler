import Foundation

/// One place to turn a measurement into text.
///
/// The inspector, the plot labels and the large readout show the same numbers at the same
/// moment. A beam that reads 721.0 µm in one and 0.721 mm in the other is two numbers the
/// operator has to reconcile, for no reason other than two call sites formatting separately.
///
/// Everything here works in significant figures rather than decimal places, because that is
/// what a measurement has: 3 figures says the beam is 721 µm and not that it is 721.0 µm.
/// The count is the operator's to set — a stable bench beam supports more digits than a
/// drifting one, and printing digits the measurement does not have reads as false precision.
enum MeasurementFormat {

    /// Rounds to `figures` significant digits and prints it in plain decimal.
    ///
    /// The rounding has to happen to the value, not to the format string: `%.0f` on 1017.4
    /// gives 1017, which is four figures however many were asked for.
    static func significant(_ value: Double, figures: Int) -> String {
        let digits = max(1, min(9, figures))
        guard value.isFinite else { return "—" }
        guard value != 0 else { return String(format: "%.\(digits - 1)f", 0.0) }

        let exponent = Int(floor(log10(abs(value))))
        let decimals = max(0, digits - 1 - exponent)
        // Scaling by a power of ten and rounding is exact enough here: these are display
        // strings for values already far coarser than a double's precision.
        let scale = pow(10.0, Double(decimals))
        let rounded = (value * scale).rounded() / scale
        return String(format: "%.\(decimals)f", rounded)
    }

    /// Pixels through the calibration: µm below a millimetre, mm above it.
    ///
    /// The unit switches at 1 mm rather than at a digit count, so the same beam does not
    /// change units when the operator changes the number of figures.
    static func length(pixels: Double, micronsPerPixel: Double, figures: Int) -> String {
        let microns = pixels * micronsPerPixel
        return abs(microns) >= 1000
            ? significant(microns / 1000, figures: figures) + " mm"
            : significant(microns, figures: figures) + " µm"
    }
}
