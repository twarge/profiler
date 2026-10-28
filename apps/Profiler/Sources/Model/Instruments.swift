import Foundation
import Observation

#if os(macOS)
import AppKit
#endif

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

    /// The windows open when the app last quit, which this launch opens again. Written at
    /// quit on the Mac only: iPadOS brings back its own scenes, and an iPad app is never
    /// told it is quitting.
    private let lastSession: [OpenWindow]
    private var lastSessionClaimed = false
    private var lastSessionReopened = false

    private init() {
        lastSession = SettingsStore().appState.openWindows ?? []
        #if os(macOS)
        // Before the windows go: a window that closes leaves the registry, so after them
        // there would be nothing left to write down.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberSession() }
        }
        #endif
    }

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

    /// For the first window of a launch, the first window of the last session; nil after it,
    /// and once the rest have been reopened.
    func claimLaunchWindow() -> OpenWindow? {
        guard !lastSessionClaimed else { return nil }
        lastSessionClaimed = true
        return lastSession.first
    }

    /// Opens a window for each camera that had one when the app last quit and has none now,
    /// once per launch. Asking for a camera that already has a window only brings that
    /// window forward, so two windows on one camera come back as one.
    func reopenLastSession(_ open: (String) -> Void) {
        guard !lastSessionReopened else { return }
        lastSessionReopened = true
        lastSessionClaimed = true
        var showing = Set(members.compactMap(\.model).filter(\.isOpen).map(\.currentDeviceKey))
        for window in lastSession where showing.insert(window.deviceKey).inserted {
            open(window.deviceKey)
        }
    }

    /// Whether a window on this camera was measuring when the app last quit. Only those
    /// start again by themselves: a reopened window that was idle stays idle.
    func wasRunningAtLastQuit(_ deviceKey: String) -> Bool {
        lastSession.contains { $0.deviceKey == deviceKey && $0.wasRunning }
    }

    private func rememberSession() {
        let store = SettingsStore()
        var state = store.appState
        state.openWindows = members.compactMap(\.model).filter(\.isOpen).map {
            OpenWindow(deviceKey: $0.currentDeviceKey, wasRunning: $0.isRunning)
        }
        store.appState = state
    }

    /// The other instrument that has taken this camera, if one has.
    func holder(of deviceKey: String, other model: ProfilerModel) -> ProfilerModel? {
        others(than: model).first { $0.heldDeviceKey == deviceKey }
    }
}
