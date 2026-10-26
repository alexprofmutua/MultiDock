import AppKit

@MainActor
enum InteractionSmoke {
    static func run() async throws {
        try await verifyRestoredAutoHide()
        let applications = ApplicationService()
        defer { applications.activity.shutdown() }
        let display = DisplayService.current.first!
        var dock = DockConfiguration(name: "Interaction Checks", position: DockPosition(x: display.visibleFrame.midX - 120, y: display.visibleFrame.midY),
            applications: TestApplications.installed())
        dock.behavior = DockBehavior(magnificationEnabled: true, magnificationStrength: 0.75, magnificationDuration: 0.08,
            autoHideEnabled: true, autoHideDelay: 0.2, visibilityDuration: 0.05, showsRunningIndicators: true,
            collapseEnabled: true)
        let controller = DockWindowController(configuration: dock)
        defer { controller.dispose() }
        controller.update(configuration: dock, applications: applications, launch: { _ in })
        let fullFrame = controller.window!.frame
        let zone = DockInteractionGeometry.revealFrame(dockFrame: fullFrame, orientation: dock.orientation,
            visibleFrame: display.visibleFrame, occupied: [])!
        controller.interactions.setRevealFrame(zone)
        controller.show()
        let host = controller.window!.contentView as! DockDropHostingView
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let buttons = host.applicationButtons
        precondition(!buttons.isEmpty)
        let button = buttons[0]
        let frame = button.convert(button.bounds, to: nil)
        controller.interactions.pointerChanged(CGPoint(x: frame.midX, y: frame.midY))
        precondition(abs(button.magnification - 1.75) < 0.01)
        precondition(!controller.interactions.hasPendingHide)
        for index in 0..<80 {
            controller.interactions.pointerChanged(CGPoint(x: frame.midX + CGFloat(index % 12) * 3, y: frame.midY))
        }
        precondition(controller.window!.frame == fullFrame, "Pointer scaling must not move or resize the dock")
        controller.update(configuration: dock, applications: applications, launch: { _ in }, accessibility: DockAccessibility(reduceMotion: true))
        host.layoutSubtreeIfNeeded()
        controller.interactions.pointerChanged(CGPoint(x: frame.midX, y: frame.midY))
        precondition(button.magnification == 1)
        precondition(button.layer?.sublayers?.allSatisfy { $0.animationKeys()?.contains("magnification") != true } == true)
        controller.interactions.pointerChanged(nil)
        try await Task.sleep(for: .milliseconds(300))
        precondition(controller.interactions.isAutoHidden && !controller.window!.isVisible)
        precondition(controller.interactions.revealPanel?.isVisible == true)
        precondition(!controller.interactions.hasPendingHide && !controller.interactions.isTransitioning)
        let revealView = controller.interactions.revealPanel!.contentView!
        let revealDrag = SmokeDragInfo(window: controller.interactions.revealPanel!)
        revealDrag.draggingSourceOperationMask = .copy
        revealDrag.draggingPasteboard.setString(dock.applications[0].location!.absoluteString, forType: .fileURL)
        precondition(revealView.draggingEntered(revealDrag) == .copy)
        precondition(controller.window!.isVisible && !controller.interactions.isAutoHidden)
        precondition(!controller.interactions.isTransitioning, "Reduce Motion must skip visibility animation")
        // Ordering a reveal tab out may omit mouseExited. The full host's exit must still allow hiding.
        controller.interactions.pointerChanged(nil)
        try await Task.sleep(for: .milliseconds(300))
        precondition(controller.interactions.isAutoHidden, "A removed reveal tab must not retain a stale hover hold")
        (revealView as! NSButton).performClick(nil)
        precondition(controller.window!.isVisible)
        // Accessibility button activation does not move the actual pointer onto the reveal tab.
        controller.interactions.pointerChanged(nil)
        try await Task.sleep(for: .milliseconds(300))
        precondition(controller.interactions.isAutoHidden, "Accessibility activation must not invent an indefinite hover hold")
        controller.interactions.reveal()
        revealView.draggingExited(revealDrag)

        controller.update(configuration: dock, applications: applications, launch: { _ in })
        for _ in 0..<6 {
            controller.interactions.pointerChanged(nil)
            try await Task.sleep(for: .milliseconds(300))
            precondition(!controller.window!.isVisible && controller.interactions.revealPanel!.isVisible)
            controller.interactions.reveal()
            try await Task.sleep(for: .milliseconds(70))
            precondition(controller.window!.isVisible && !controller.interactions.isTransitioning)
        }
        // Interrupt a fade-out with reveal, then rapid entry/exit before the delay expires.
        controller.interactions.pointerChanged(nil)
        try await Task.sleep(for: .milliseconds(220))
        controller.interactions.reveal()
        for _ in 0..<12 {
            controller.interactions.pointerChanged(nil)
            controller.interactions.pointerChanged(CGPoint(x: frame.midX, y: frame.midY))
        }
        try await Task.sleep(for: .milliseconds(300))
        precondition(controller.window!.isVisible && !controller.interactions.isAutoHidden)
        precondition(controller.window!.contentView!.layer!.opacity == 1)
        controller.interactions.pointerChanged(nil)
        controller.interactions.beginInteraction()
        try await Task.sleep(for: .milliseconds(300))
        precondition(controller.window!.isVisible, "Menus, drops and position drags must hold the dock open")
        controller.interactions.endInteraction()

        applications.activity.onChange = { [weak controller] in controller?.refreshActivity(using: applications) }
        let item = dock.applications[0]
        applications.activity.setLaunchState(.launching, for: item.id)
        precondition(button.activityState == .launching)
        try await Task.sleep(for: .milliseconds(300))
        precondition(controller.window!.isVisible, "Pending launch feedback must hold the dock open")
        applications.activity.setLaunchState(.succeeded, for: item.id)
        precondition(button.activityState == .succeeded)
        try await Task.sleep(for: .milliseconds(1300))
        precondition(button.activityState == .idle)
        applications.activity.setLaunchState(.failed, for: item.id)
        precondition(button.activityState == .failed)
        applications.activity.setLaunchState(.idle, for: item.id)
        let synthetic = "org.multidock.tests.synthetic"
        applications.activity.recordProcess(pid: 1_000_001, bundleIdentifier: synthetic, launched: true)
        precondition(applications.activity.isRunning(synthetic))
        applications.activity.recordProcess(pid: 1_000_001, bundleIdentifier: nil, launched: false)
        precondition(!applications.activity.isRunning(synthetic))
        precondition(applications.icon(for: item) === applications.icon(for: item), "Repeated rendering must reuse the cached native image")
        // Failed real launch validation produces feedback without opening an unrelated application.
        let missing = ApplicationItem(bundleIdentifier: "org.multidock.tests.nonexistent", name: "Missing test application")
        do { try await applications.launch(missing); preconditionFailure("Expected failed launch") }
        catch { precondition(applications.activity.launchState(missing.id) == .failed) }
        applications.activity.onChange = nil
        controller.dispose()

        let manager = DockManager(initialApplications: TestApplications.installed(), newDockBehavior: DockBehavior())
        defer { manager.shutdown() }
        manager.createDock()
        manager.createDock()
        let ids = manager.configurations.map(\.id)
        for id in ids {
            manager.placeDock(id, anchor: .topLeft)
            manager.setBehavior(DockBehavior(autoHideEnabled: true, autoHideDelay: 0.2,
                visibilityDuration: 0.05, collapseEnabled: true, isCollapsed: true), in: id)
        }
        let tabs = NSApp.windows.filter { $0.title.hasPrefix("Reveal Dock") && $0.isVisible }
        precondition(tabs.count == 2 && !tabs[0].frame.intersects(tabs[1].frame), "Neighboring docks need separate reveal tabs")
        manager.toggleTemporaryVisibility()
        precondition(!tabs.contains(where: \.isVisible))
        manager.toggleTemporaryVisibility()
        precondition(tabs.allSatisfy(\.isVisible))
        manager.showDock(ids[0])
        precondition(!manager.configurations[0].behavior.isCollapsed)
        manager.setEnabled(false, in: ids[1])
        precondition(!tabs.contains { $0.isVisible && $0.title == "Reveal Dock 2" })
        manager.setOrientation(ids[0], to: .vertical)
        let verticalHost = NSApp.windows.first { ($0.contentView as? DockDropHostingView)?.configuration.id == ids[0] }!.contentView as! DockDropHostingView
        verticalHost.pointerChanged?(nil)
        try await Task.sleep(for: .milliseconds(300))
        manager.placeDock(ids[0], anchor: .bottomRight)
        let repositioned = NSApp.windows.first { ($0.contentView as? DockDropHostingView)?.configuration.id == ids[0] }!
        precondition(repositioned.isVisible && display.visibleFrame.contains(repositioned.frame), "Repositioning must recover an auto-hidden dock")
        manager.setCollapsed(true, in: ids[0])
        let verticalTab = NSApp.windows.first { $0.title == "Reveal Dock 1" && $0.isVisible }!
        precondition(verticalTab.frame.size == CGSize(width: 8, height: 44))
        (verticalTab.contentView as! NSButton).performClick(nil)
        precondition(!manager.configurations[0].behavior.isCollapsed && repositioned.isVisible, "The tab's native action must expand a collapsed dock")
        manager.setCollapsed(true, in: ids[0])
        let settingsSnapshot = manager.configurations
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        try await store.save(settingsSnapshot, revision: 1)
        let restored = try await store.load()
        precondition(restored == settingsSnapshot, "Behavior and collapsed state must persist")
        try await verifyWorkspaceNotifications()
        print("PASS: nearby magnification, rapid pointer changes, fixed geometry, Reduce Motion, interrupted fades, six hide/reveal cycles, interaction/launch holds, launch feedback, icon reuse, nonoverlapping reveal tabs, vertical collapse, position recovery, persisted behavior, workspace lifecycle")
    }

    private static func verifyRestoredAutoHide() async throws {
        let display = DisplayService.current.first!
        let pointer = NSEvent.mouseLocation
        let bounds = display.visibleFrame
        let origin = DockPosition(x: pointer.x < bounds.midX ? bounds.maxX - 250 : bounds.minX + 40,
                                  y: pointer.y < bounds.midY ? bounds.maxY - 250 : bounds.minY + 40)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MultiDock-restored-hide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        let saved = (0..<4).map { index in
            DockConfiguration(name: "Restored auto-hide \(index)",
                orientation: index.isMultiple(of: 2) ? .horizontal : .vertical,
                position: origin, applications: Array(TestApplications.installed().prefix(2)),
                behavior: DockBehavior(autoHideEnabled: true, autoHideDelay: 0.2, visibilityDuration: 0.05))
        }
        try await store.save(saved, revision: 1)
        let manager = DockManager(store: store)
        defer { manager.shutdown() }
        await manager.start()
        let controllers = NSApp.windows.compactMap { $0.delegate as? DockWindowController }
            .filter { controller in saved.contains { $0.id == controller.dockID } }
        precondition(controllers.count == 4)
        precondition(controllers.allSatisfy { $0.interactions.revealFrame != nil },
                     "Every restored dock needs a reveal zone, even when the cached layout is unchanged")
        precondition(controllers.allSatisfy { $0.interactions.hasPendingHide },
                     "Every restored dock must schedule auto-hide without an initial pointer exit")
        try await Task.sleep(for: .milliseconds(400))
        precondition(controllers.allSatisfy {
            $0.interactions.isAutoHidden && $0.window?.isVisible == false && $0.interactions.revealPanel?.isVisible == true
        }, "All restored docks must auto-hide and keep a visible reveal tab")
        for controller in controllers {
            (controller.interactions.revealPanel?.contentView as? NSButton)?.performClick(nil)
            precondition(controller.window?.isVisible == true)
            controller.interactions.pointerChanged(nil)
        }
        try await Task.sleep(for: .milliseconds(900))
        precondition(controllers.allSatisfy { $0.interactions.isAutoHidden && $0.window?.isVisible == false })
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(400))
        precondition(controllers.allSatisfy { $0.interactions.isAutoHidden && $0.interactions.revealPanel?.isVisible == true },
                     "Auto-hide must resume for every dock after wake")
        precondition(manager.configurations.map(\.id) == saved.map(\.id))
        precondition(manager.configurations.allSatisfy { $0.behavior.autoHideEnabled })
        let originalFrames = controllers.map { $0.window!.frame }
        let originalPanels = controllers.map { $0.window!.windowNumber }
        manager.setGlobalRevealStyle(DockRevealStyle(color: .blue, opacity: 0.6))
        precondition(controllers.allSatisfy { $0.interactions.revealStyle == manager.globalRevealStyle })
        let independent = controllers[1]
        let override = DockRevealStyle(color: .orange, opacity: 0.8)
        manager.setRevealStyle(override, usesGlobal: false, in: independent.dockID)
        manager.setGlobalRevealStyle(DockRevealStyle(color: .purple, opacity: 0.5))
        for controller in controllers {
            precondition(controller.interactions.revealStyle == (controller === independent ? override : manager.globalRevealStyle))
            precondition(controller.interactions.isAutoHidden && controller.interactions.revealPanel?.isVisible == true)
        }
        precondition(controllers.map { $0.window!.frame } == originalFrames)
        precondition(controllers.map { $0.window!.windowNumber } == originalPanels,
                     "Theme changes must not recreate or reposition dock windows")
        let tab = independent.interactions.revealPanel!.contentView as! DockRevealButton
        let resting = tab.layer!.backgroundColor!
        precondition(abs(resting.alpha - 0.8) < 0.001)
        tab.setHovered(true)
        precondition(tab.layer!.backgroundColor! != resting, "Hover must visibly highlight the tab")
        tab.setHovered(false)
        precondition(tab.layer!.backgroundColor! == resting)
        tab.reduceTransparency = true
        tab.refreshColors()
        precondition(tab.layer!.backgroundColor!.alpha == 1)
        tab.reduceTransparency = false
        tab.increaseContrast = true
        tab.refreshColors()
        precondition(tab.layer!.backgroundColor!.alpha == 1 && tab.layer!.borderWidth == 2)
        manager.setRevealStyle(override, usesGlobal: true, in: independent.dockID)
        precondition(independent.interactions.revealStyle == manager.globalRevealStyle)
        manager.setRevealStyle(override, usesGlobal: false, in: independent.dockID)
        precondition(independent.interactions.revealStyle == override)
        try await manager.flush()
        let global = manager.globalRevealStyle
        let snapshot = manager.configurations
        manager.shutdown()
        let reopened = DockManager(store: DockStore(url: store.url))
        defer { reopened.shutdown() }
        await reopened.start()
        precondition(reopened.globalRevealStyle == global && reopened.configurations == snapshot)
        print("PASS: global reveal colors/opacity, independent override, retained custom style, hover highlight, accessibility opacity/contrast, no window recreation/movement, saved global and individual themes")
        print("PASS: four restored docks, both orientations, startup auto-hide without pointer events, independent reveal/re-hide, wake recovery, stable IDs and settings")
    }

    private static func verifyWorkspaceNotifications() async throws {
        guard let path = ProcessInfo.processInfo.environment["MULTIDOCK_ACTIVITY_PROBE"] else {
            preconditionFailure("The lifecycle probe must be provided by test-windows.sh")
        }
        guard let agentPath = ProcessInfo.processInfo.environment["MULTIDOCK_ACTIVITY_AGENT_PROBE"] else {
            preconditionFailure("The agent lifecycle probe must be provided by test-windows.sh")
        }
        let workspace = NSWorkspace.shared
        let activity = ApplicationActivityService(workspace: workspace)
        defer { activity.shutdown() }
        for path in [path, agentPath] {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        let app = try await workspace.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
        defer { if !app.isTerminated { app.terminate() } }
        let id = app.bundleIdentifier!
        await waitFor(activity) { activity.isRunning(id) }
        precondition(app.terminate(), "Probe must support normal termination")
        await waitFor(activity) { !activity.isRunning(id) }
        }
    }
    private static func waitFor(_ service: ApplicationActivityService, condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        service.onChange = { continuation.yield(()) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(4))
            continuation.finish()
        }
        defer { timeout.cancel(); continuation.finish(); service.onChange = nil }
        for await _ in stream { if condition() { return } }
        preconditionFailure("Timed out waiting for NSWorkspace lifecycle notification")
    }
}
