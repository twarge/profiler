import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        ProfilerApp.main()
    }
}

struct ProfilerApp: App {
    var body: some Scene {
        WindowGroup("Profiler") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
