import Observation

/// Every instrument open at once — one per window — so that a camera one of them has taken
/// stays out of the others' reach. A second session on a camera that is already streaming
/// fails at best; at worst it takes the device out from under the window using it.
///
/// Holds the instruments weakly: each window owns its own, and leaves when it closes.
@MainActor
@Observable
final class Instruments {
    static let shared = Instruments()

    private struct Member {
        weak var model: ProfilerModel?
    }

    private var members: [Member] = []

    func join(_ model: ProfilerModel) {
        members.removeAll { $0.model == nil || $0.model === model }
        members.append(Member(model: model))
    }

    func leave(_ model: ProfilerModel) {
        members.removeAll { $0.model == nil || $0.model === model }
    }

    /// Drops the instruments that have gone — and, being a change, tells the windows still
    /// open that whatever those held is free.
    func prune() {
        members.removeAll { $0.model == nil }
    }

    func others(than model: ProfilerModel) -> [ProfilerModel] {
        members.compactMap(\.model).filter { $0 !== model }
    }

    /// The other instrument that has taken this camera, if one has.
    func holder(of deviceKey: String, other model: ProfilerModel) -> ProfilerModel? {
        others(than: model).first { $0.heldDeviceKey == deviceKey }
    }
}
