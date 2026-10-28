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
        Button("New Window") { openWindow(id: ProfilerApp.windowID) }
            .keyboardShortcut("n")
            .disabled(!supportsMultipleWindows)
    }
}
#endif

/// One window per camera. Each window is an instrument of its own — its own model, source
/// and settings — so two cameras measure side by side, or as tabs of one window. A new
/// window comes up set to a camera no other window is using, ready to start.
struct ProfilerApp: App {
    /// The window group, for File › New Window on the iPad.
    static let windowID = "instrument"

    var body: some Scene {
        WindowGroup("Profiler", id: Self.windowID) {
            ContentView()
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
