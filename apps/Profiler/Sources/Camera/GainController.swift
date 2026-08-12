import Foundation

/// Closed-loop gain servo.
///
/// Drives the peak signal toward a target fraction of full scale. The loop works in stops
/// (log₂ units) because ISO is logarithmic in effect, so a fixed correction moves the peak
/// by a fixed ratio regardless of where it started.
///
/// Saturation is treated asymmetrically: clipping destroys the beam core and invalidates
/// every second-moment result, so an over-exposed frame gets an immediate large correction
/// while an under-exposed one is walked up gently.
final class GainController {

    struct Settings {
        var enabled = false
        /// Target peak as a fraction of full scale. 0.7 leaves headroom for beam
        /// fluctuation without wasting dynamic range.
        var targetPeak: Double = 0.70
        /// No correction is issued inside this band, to stop the loop hunting.
        var deadbandStops: Double = 0.25
        /// Frames to wait after a change before measuring again — the camera needs a
        /// few frames to apply a new ISO and the analyser needs one clean frame after that.
        var settleFrames: Int = 8
    }

    enum Decision: Equatable {
        /// Apply this ISO to the camera.
        case setISO(Int)
        /// The source can't change gain, or has run out of range: tell the operator.
        case advise(stops: Double, message: String)
        case none
    }

    var settings = Settings()
    private var framesUntilReady = 0
    private(set) var lastDecision: Decision = .none

    func reset() {
        framesUntilReady = 0
        lastDecision = .none
    }

    /// - Parameters:
    ///   - peak: robust peak of the current frame, 0...1 of full scale.
    ///   - saturated: whether the frame has clipped pixels above the tolerated fraction.
    func update(peak: Double, saturated: Bool, state: GainState) -> Decision {
        guard settings.enabled else { return .none }

        if framesUntilReady > 0 {
            framesUntilReady -= 1
            return .none
        }

        // No signal at all: a correction computed from noise would be meaningless.
        guard peak > 0.002 else {
            lastDecision = .advise(
                stops: 0,
                message: "No beam detected. Check the shutter, ND filters and alignment.")
            return lastDecision
        }

        var errorStops = log2(settings.targetPeak / peak)

        // Clipping hides the true peak, so the measured error understates the problem.
        if saturated || peak >= 0.99 {
            errorStops = min(errorStops, -1.0)
        } else if abs(errorStops) < settings.deadbandStops {
            lastDecision = .none
            return .none
        }

        guard state.canSetISO, let current = state.currentISO, !state.availableISO.isEmpty else {
            let direction = errorStops > 0 ? "Increase" : "Reduce"
            lastDecision = .advise(
                stops: errorStops,
                message: String(
                    format: "%@ exposure by %.1f stops on the camera body.",
                    direction, abs(errorStops))
            )
            return lastDecision
        }

        let desired = Double(current) * pow(2, errorStops)
        let ladder = state.availableISO.sorted()

        guard let target = ladder.min(by: {
            abs(log(Double($0)) - log(desired)) < abs(log(Double($1)) - log(desired))
        }) else {
            lastDecision = .none
            return .none
        }

        if target == current {
            // Already at the closest available step. If we still need a big correction,
            // ISO has railed and the operator has to change something else.
            if abs(errorStops) > 1.0 {
                let atFloor = current == ladder.first
                let message = atFloor
                    ? "ISO is at minimum and the beam is still too bright. "
                        + "Add ND attenuation or shorten the exposure."
                    : "ISO is at maximum and the beam is still too dim. "
                        + "Lengthen the exposure or open the aperture."
                lastDecision = .advise(stops: errorStops, message: message)
                return lastDecision
            }
            lastDecision = .none
            return .none
        }

        framesUntilReady = settings.settleFrames
        lastDecision = .setISO(target)
        return lastDecision
    }
}
