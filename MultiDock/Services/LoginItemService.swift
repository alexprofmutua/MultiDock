import AppKit
import Combine
import ServiceManagement

@MainActor
protocol LoginItemClient {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
private struct SystemLoginItemClient: LoginItemClient {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
}

/// System registration is the source of truth. Merely opening settings never registers the app.
@MainActor
final class LoginItemService: NSObject, ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    private let client: any LoginItemClient

    init(client: (any LoginItemClient)? = nil) {
        self.client = client ?? SystemLoginItemClient()
        super.init()
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: "MultiDock will open when you log in."
        case .requiresApproval: "Approve MultiDock in System Settings → General → Login Items."
        case .notFound: "macOS cannot find this app's login registration. Keep MultiDock in Applications and try again."
        case .notRegistered: "MultiDock will not open automatically."
        @unknown default: "macOS reported an unknown login-item status."
        }
    }
    @objc private func applicationActivated(_ notification: Notification) { refresh() }
    func refresh() { status = client.status }
    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { refresh(); isUpdating = false }
        refresh()
        do {
            if enabled && !isRequested { try client.register() }
            else if !enabled && isRequested { try await client.unregister() }
        } catch { errorMessage = "Could not change Launch at Login: \(error.localizedDescription)" }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
