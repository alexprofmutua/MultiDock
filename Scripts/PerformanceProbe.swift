import AppKit
import Darwin

/// Measures the production manager/views in an optimized test process. Does not change user settings.
@main
@MainActor
struct PerformanceProbe {
    struct Sample: Encodable {
        let docks: Int
        let iconsPerDock: Int
        let createAndLayoutMilliseconds: Double
        let idleWallSeconds: Double
        let idleCPUSeconds: Double
        let idleCPUPercentOfOneCore: Double
        let residentBytes: UInt64?
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return .nan }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }
    static func milliseconds(_ interval: Duration) -> Double {
        Double(interval.components.seconds) * 1000 + Double(interval.components.attoseconds) / 1e15
    }
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let clock = ContinuousClock()
        let fixtures = TestApplications.installed()
        var samples: [Sample] = []
        for count in [1, 10, 25] {
            let manager = DockManager(initialApplications: fixtures)
            let start = clock.now
            for _ in 0..<count { manager.createDock() }
            for window in NSApp.windows where window.isVisible { window.contentView?.layoutSubtreeIfNeeded() }
            let elapsed = milliseconds(start.duration(to: clock.now))
            try await Task.sleep(for: .seconds(3))
            let idleStart = clock.now
            let cpuStart = cpuSeconds()
            try await Task.sleep(for: .seconds(10))
            let cpu = cpuSeconds() - cpuStart
            let wall = milliseconds(idleStart.duration(to: clock.now)) / 1000
            samples.append(Sample(docks: count, iconsPerDock: fixtures.count, createAndLayoutMilliseconds: elapsed,
                idleWallSeconds: wall, idleCPUSeconds: cpu, idleCPUPercentOfOneCore: cpu / wall * 100,
                residentBytes: residentBytes()))
            manager.shutdown()
            try await Task.sleep(for: .milliseconds(200))
        }
        let applications = ApplicationService()
        defer { applications.activity.shutdown() }
        let iconStart = clock.now
        if let item = fixtures.first {
            let icon = applications.icon(for: item)
            for _ in 0..<1000 { precondition(applications.icon(for: item) === icon) }
        }
        let iconMilliseconds = milliseconds(iconStart.duration(to: clock.now))
        let button = ApplicationIconButton(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        let layerStart = clock.now
        for index in 0..<1000 { button.setMagnification(index.isMultiple(of: 2) ? 1 : 1.5, duration: 0.12) }
        let layerMilliseconds = milliseconds(layerStart.duration(to: clock.now))
        struct Report: Encodable {
            let os: String
            let architecture = "arm64"
            let configuration = "Optimized test harness (-O), warm process, three-second settling, ten-second idle samples. Defaults; no captures; no persistence. RSS includes shared framework/cache pages. CPU includes all process threads. Creation timing excludes process/framework startup."
            let samples: [Sample]
            let cachedIconLookups1000Milliseconds: Double
            let layerScaleUpdates1000Milliseconds: Double
        }
        let report = Report(os: ProcessInfo.processInfo.operatingSystemVersionString, samples: samples,
                            cachedIconLookups1000Milliseconds: iconMilliseconds, layerScaleUpdates1000Milliseconds: layerMilliseconds)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
