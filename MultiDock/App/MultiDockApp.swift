import AppKit

@main
@MainActor
enum MultiDockApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication holds its delegate weakly. Keep ownership through the run loop.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
