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

struct ProfilerApp: App {
    var body: some Scene {
        WindowGroup("Profiler") {
            ContentView()
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Lands in the View menu, beside the system's own sidebar toggles.
            CommandGroup(after: .sidebar) {
                StatusBarToggle()
            }
        }
        #endif
    }
}
