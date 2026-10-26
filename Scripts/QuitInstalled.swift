import AppKit
import Foundation

/// Installer-only helper. Requests normal application termination so pending settings can flush.
@main
@MainActor
struct QuitInstalled {
    static func main() {
        do { try requestQuit() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    private static func requestQuit() throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "org.multidock.MultiDock")
        if CommandLine.arguments.contains("--check") {
            print("Installer preflight: \(applications.count) running MultiDock instance(s); none were quit.")
            return
        }
        for application in applications where !application.isTerminated {
            guard application.terminate() else {
                throw NSError(domain: "MultiDockInstaller", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "MultiDock did not accept a normal Quit request. Quit it from the menu bar, then run the installer again."])
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard applications.allSatisfy(\.isTerminated) else {
            throw NSError(domain: "MultiDockInstaller", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "MultiDock is still closing. Finish any dialog or quit it manually, then retry. Nothing was replaced."])
        }
    }
}
