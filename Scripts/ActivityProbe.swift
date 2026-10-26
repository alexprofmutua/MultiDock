import AppKit

/// Test-only regular application with no windows; never installed or registered for login.
@main
@MainActor
enum ActivityProbe {
    static func main() {
        let app = NSApplication.shared
        let delegate = DocumentProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true ? .accessory : .regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { app.terminate(nil) }
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class DocumentProbeDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = ProcessInfo.processInfo.environment["MULTIDOCK_TEST_OPEN_RECEIPT"] {
            do { try JSONEncoder().encode(filenames).write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { NSLog("Test receipt failed: %@", error.localizedDescription) }
        }
        sender.reply(toOpenOrPrint: .success)
    }
}
