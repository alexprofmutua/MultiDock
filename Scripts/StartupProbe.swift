import AppKit
import CoreGraphics

/// Launches the real supplied app with persistence disabled and requests normal termination afterward.
@main
@MainActor
struct StartupProbe {
    struct Failure: Error { let message: String }
    static func milliseconds(_ interval: Duration) -> Double {
        Double(interval.components.seconds) * 1000 + Double(interval.components.attoseconds) / 1e15
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "Supply a built MultiDock.app path") }
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/MultiDock")
        var environment = ProcessInfo.processInfo.environment
        environment["MULTIDOCK_DISABLE_PERSISTENCE"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        let clock = ContinuousClock()
        let start = clock.now
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var found = false
        while start.duration(to: clock.now) < .seconds(10), process.isRunning {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            found = windows.contains {
                ($0[kCGWindowOwnerPID as String] as? Int32) == process.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.floatingWindow))
            }
            if found { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard found else { throw Failure(message: "No visible dock detected in ten seconds") }
        let elapsed = milliseconds(start.duration(to: clock.now))
        let quit = clock.now
        guard NSRunningApplication(processIdentifier: process.processIdentifier)?.terminate() == true else {
            throw Failure(message: "Normal Quit request was refused")
        }
        while process.isRunning && quit.duration(to: clock.now) < .seconds(5) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else { throw Failure(message: "App did not quit within five seconds") }
        let object: [String: Any] = ["spawnToVisibleDockMilliseconds": elapsed,
            "normalQuitMilliseconds": milliseconds(quit.duration(to: clock.now)),
            "exitStatus": process.terminationStatus,
            "method": "Real optimized app, persistence disabled, on-screen window metadata sampled every 10 ms only during startup. Single sample; includes process startup, excludes user configuration restoration; normal NSRunningApplication termination."]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
