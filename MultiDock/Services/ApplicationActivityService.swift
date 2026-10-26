import AppKit

/// Event-driven workspace state. No timer refreshes the running-application list.
@MainActor
final class ApplicationActivityService: NSObject {
    private let workspace: NSWorkspace
    private nonisolated let notifications: NotificationCenter
    private var running = RunningApplicationState()
    private var applicationsObservation: NSKeyValueObservation?
    private var stopped = false
    private var launches: [UUID: DockLaunchState] = [:]
    private var feedbackTasks: [UUID: Task<Void, Never>] = [:]
    var onChange: (() -> Void)?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        notifications = workspace.notificationCenter
        super.init()
        refreshRunningSnapshot()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.notificationCenter.addObserver(self, selector: #selector(applicationChanged), name: name, object: nil)
        }
        // Workspace launch/termination notifications omit some agent apps. Public KVO fills that gap.
        applicationsObservation = workspace.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshRunningSnapshot() }
        }
    }
    private func refreshRunningSnapshot() {
        guard !stopped else { return }
        var snapshot = RunningApplicationState()
        for app in workspace.runningApplications where !app.isTerminated {
            if let id = app.bundleIdentifier { snapshot.launched(pid: app.processIdentifier, bundleIdentifier: id) }
        }
        if running != snapshot { running = snapshot; onChange?() }
    }
    deinit { feedbackTasks.values.forEach { $0.cancel() }; notifications.removeObserver(self) }
    func isRunning(_ id: String) -> Bool { running.isRunning(id) }
    func launchState(_ id: UUID) -> DockLaunchState { launches[id] ?? .idle }
    @objc private func applicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        recordProcess(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                      launched: notification.name == NSWorkspace.didLaunchApplicationNotification)
    }
    func recordProcess(pid: Int32, bundleIdentifier: String?, launched: Bool) {
        guard !stopped else { return }
        let previous = running
        if launched, let bundleIdentifier { running.launched(pid: pid, bundleIdentifier: bundleIdentifier) }
        else if !launched { running.terminated(pid: pid) }
        if previous != running { onChange?() }
    }
    func setLaunchState(_ state: DockLaunchState, for id: UUID) {
        guard !stopped, launchState(id) != state else { return }
        feedbackTasks.removeValue(forKey: id)?.cancel()
        if state == .idle { launches.removeValue(forKey: id) } else { launches[id] = state }
        onChange?()
        if state == .succeeded || state == .failed {
            feedbackTasks[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                self?.setLaunchState(.idle, for: id)
            }
        }
    }
    func shutdown() {
        stopped = true
        applicationsObservation?.invalidate()
        applicationsObservation = nil
        workspace.notificationCenter.removeObserver(self)
        feedbackTasks.values.forEach { $0.cancel() }
        feedbackTasks.removeAll()
        onChange = nil
    }
}
