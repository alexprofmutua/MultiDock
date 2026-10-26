import AppKit

@MainActor
private final class PreviewProviderProbe: WindowPreviewProviding {
    var screenAccess = false
    var accessibilityAccess = false
    var screenRequests = 0
    var accessibilityRequests = 0
    var loadCount = 0
    var activationCount = 0
    var failure: WindowPreviewError?
    var delay = false
    let window = PreviewWindowDescriptor(id: 1, pid: 12345, title: "Test window",
                                        frame: CGRect(x: 0, y: 50, width: 400, height: 300), isOnScreen: true)
    func requestScreenAccess() { screenRequests += 1 }
    func requestAccessibilityAccess() { accessibilityRequests += 1 }
    func load(bundleIdentifier: String) async throws -> [WindowPreview] {
        loadCount += 1
        if delay { try? await Task.sleep(for: .milliseconds(150)) }
        if let failure { throw failure }
        // A generated symbol, never user screen content.
        var rectangle = CGRect(x: 0, y: 0, width: 32, height: 32)
        let image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?.cgImage(forProposedRect: &rectangle, context: nil, hints: nil)
        return [WindowPreview(window: window, image: image)]
    }
    func activate(_ window: PreviewWindowDescriptor, bundleIdentifier: String) async throws {
        activationCount += 1
        if let failure { throw failure }
    }
}

@MainActor
struct PreviewSmoke {
    static func run() async throws {
        let provider = PreviewProviderProbe()
        let previews = WindowPreviewController(provider: provider)
        var configuration = DockConfiguration(name: "Preview checks", position: DockPosition(x: 200, y: 200))
        configuration.behavior.windowPreviewsEnabled = true
        let owner = DockWindowController(configuration: configuration)
        owner.previews = previews
        let anchor = ApplicationIconButton(frame: CGRect(x: 20, y: 10, width: 40, height: 40))
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        content.addSubview(anchor)
        owner.window?.contentView = content
        owner.window?.setFrame(CGRect(x: 200, y: 200, width: 200, height: 60), display: true)
        owner.window?.orderFrontRegardless()
        let item = ApplicationItem(bundleIdentifier: "org.multidock.tests.Preview", name: "Preview test")
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var opened = 0
        func open(immediate: Bool = true) async throws {
            previews.hover(item, anchor: anchor, entered: true, owner: owner, orientation: .horizontal,
                           launch: { opened += 1 }, immediate: immediate)
            try await Task.sleep(for: .milliseconds(70))
        }
        defer { previews.shutdown(); owner.dispose() }
        func inspect(_ name: String) throws {
            guard let view = previews.popover?.contentViewController?.view else { preconditionFailure("Missing preview view") }
            view.layoutSubtreeIfNeeded()
            precondition(view.bounds.width >= 280 && view.bounds.height >= 80, "Popover must have usable content dimensions")
            precondition(view.bounds.height + 2 >= view.fittingSize.height, "Popover must fit its content")
            if let directory = ProcessInfo.processInfo.environment["MULTIDOCK_PREVIEW_QA_DIR"],
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
                }
            }
        }
        try await open(immediate: false)
        try await Task.sleep(for: .milliseconds(550))
        precondition(!previews.isOpen && provider.screenRequests == 0 && provider.loadCount == 0,
                     "Ordinary hover without permission must not open an access banner")
        previews.dismiss()
        try await open()
        try inspect("preview-permission")
        precondition(previews.isOpen && previews.model.needsScreenAccess)
        precondition(provider.loadCount == 0 && provider.screenRequests == 0 && provider.accessibilityRequests == 0,
                     "Hover must neither capture nor request permission when access is denied")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                     "Showing previews must not switch applications")
        previews.model.requestScreen()
        precondition(provider.screenRequests == 1 && provider.loadCount == 0)
        previews.model.openApplication()
        precondition(opened == 1 && !previews.isOpen && previews.model.rows.isEmpty)

        provider.screenAccess = true
        try await open()
        precondition(previews.isOpen && previews.model.rows.count == 1 && provider.loadCount == 1)
        try inspect("preview-window")
        previews.model.select(provider.window)
        precondition(previews.model.needsAccessibility && provider.activationCount == 0 && provider.accessibilityRequests == 0)
        try inspect("preview-accessibility")
        previews.model.requestAccessibility()
        precondition(provider.accessibilityRequests == 1)
        provider.accessibilityAccess = true
        provider.failure = .ambiguous
        previews.model.select(provider.window)
        try await Task.sleep(for: .milliseconds(40))
        precondition(previews.isOpen && !previews.model.selecting && previews.model.message.contains("unique"))
        provider.failure = nil
        previews.model.select(provider.window)
        try await Task.sleep(for: .milliseconds(40))
        precondition(!previews.isOpen && previews.model.rows.isEmpty && provider.activationCount == 2)

        provider.delay = true
        try await open()
        previews.dismiss()
        try await Task.sleep(for: .milliseconds(180))
        precondition(!previews.isOpen && previews.model.rows.isEmpty && !previews.hasPendingRequest,
                     "Late results must never resurrect closed previews")
        provider.delay = false
        provider.failure = .unavailable
        try await open()
        precondition(previews.model.rows.isEmpty && !previews.model.message.isEmpty)
        previews.dismiss()
        provider.failure = nil
        let count = provider.loadCount
        try await open(immediate: false)
        previews.hover(item, anchor: anchor, entered: false, owner: owner, orientation: .horizontal, launch: {})
        try await Task.sleep(for: .milliseconds(550))
        precondition(provider.loadCount == count && !previews.isOpen, "Rapid pointer movement must not capture")
        previews.dismiss()
        for orientation in DockOrientation.allCases {
            previews.hover(item, anchor: anchor, entered: true, owner: owner, orientation: orientation, launch: {}, immediate: true)
            try await Task.sleep(for: .milliseconds(50))
            precondition(previews.isOpen)
            previews.dismiss(for: owner)
            precondition(previews.model.rows.isEmpty)
        }
        try await open()
        owner.setVisible(false)
        precondition(!previews.isOpen)
        previews.shutdown()
        try await open()
        precondition(!previews.isOpen && !previews.hasPendingRequest)
        print("PASS: native preview popover, nonactivation, no permission prompts on hover, explicit permission actions, denial fallback, exact-window errors, successful selection, snapshot release, stale-result cancellation, rapid hover, orientations, visibility and shutdown")

        let manager = DockManager(newDockBehavior: DockBehavior())
        defer { manager.shutdown() }
        let knownWindows = Set(NSApp.windows.map(\.windowNumber))
        manager.createDock()
        let saved = manager.configurations
        let panel = NSApp.windows.compactMap { $0 as? DockPanel }.first { !knownWindows.contains($0.windowNumber) && $0.title == saved[0].name }!
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        precondition(!panel.isVisible && manager.configurations == saved)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(panel.isVisible && manager.configurations == saved)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(!panel.isVisible, "System wake must wait for sleeping displays")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        precondition(panel.isVisible)
        manager.toggleTemporaryVisibility()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        precondition(!panel.isVisible && manager.docksTemporarilyHidden)
        manager.toggleTemporaryVisibility()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        precondition(panel.isVisible && manager.configurations == saved)
        print("PASS: simulated sleep/wake and Spaces notifications preserve saved docks and temporary visibility")
    }
}
