import SwiftUI

/// One key shared by the View-menu toggle and the measurement view.
///
/// App chrome, not a measurement setting: it rides UserDefaults directly rather than the
/// per-device profile, the same as the window layout it sits under.
enum StatusBarPreference {
    static let key = "showStatusBar.v1"
}

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        if CommandLine.arguments.contains("--benchmark") {
            exit(Benchmark.run())
        }
        ProfilerApp.main()
    }
}

#if os(macOS)
private struct StatusBarToggle: View {
    @AppStorage(StatusBarPreference.key) private var showStatusBar = false

    var body: some View {
        Toggle("Show Status Bar", isOn: $showStatusBar)
    }
}
#endif

#if os(iOS)
/// File › New Window, for a second camera's window. The Mac's menu has one of its own; the
/// iPad's offers a SwiftUI app only Close. Not on an iPhone, which shows one window.
private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        // By id, not value: always a new window, which then settles its own camera.
        Button("New Window") { openWindow(id: ProfilerApp.windowID) }
            .keyboardShortcut("n")
            .disabled(!supportsMultipleWindows)
    }
}
#endif

/// One window per camera. Each window is an instrument of its own — its own model, source
/// and settings — so two cameras measure side by side, or as tabs of one window. A new
/// window comes up set to a camera no other window is using, ready to start.
///
/// A window's value is the camera it measures with, so iPadOS's scene restoration and the
/// Mac's reopening of the last session bring each one back on its own camera — and asking
/// for a camera that already has a window brings that window forward, not a second one.
struct ProfilerApp: App {
    /// Opening the group by id gives a new window every time; by value, a window already
    /// showing that value would be brought forward instead.
    static let windowID = "instrument"

    #if os(macOS)
    init() {
        // macOS never restores Profiler's windows itself: the app reopens them, from its own
        // record of the last session (`Instruments.reopenLastSession`), whichever way "Close
        // windows when quitting an application" is set. A window macOS restores learns its
        // camera only after it has appeared, by which time it has settled on another — and
        // the reopening, not seeing it, would open that camera a second time. This is the
        // default Xcode's launch-without-state-restoration option passes; registered, not
        // written, so it lasts as long as the process.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }
    #endif

    var body: some Scene {
        WindowGroup("Profiler", id: Self.windowID, for: String.self) { $deviceKey in
            ContentView(deviceKey: $deviceKey)
        } defaultValue: {
            // A window asked for rather than brought back, which settles its own camera.
            ""
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        .commands {
            // Lands in the View menu, beside the system's own sidebar toggles.
            CommandGroup(after: .sidebar) {
                StatusBarToggle()
            }
        }
        #else
        .commands {
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
            }
        }
        #endif
    }
}
