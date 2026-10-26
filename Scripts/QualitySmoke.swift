import AppKit

@MainActor
struct QualitySmoke {
    static func run() async throws {
        try await verifyPositionLocks()
        try await verifyStacks()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MultiDock-quality-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        let original = DockConfiguration(name: "Preserved", position: DockPosition(x: 200, y: 200))
        try await store.save([original], revision: 1)
        let stopped = DockManager(store: DockStore(url: store.url))
        stopped.shutdown()
        await stopped.start()
        stopped.createDock()
        try await stopped.flush()
        let preserved = try await store.load()
        precondition(stopped.configurations.isEmpty && preserved == [original],
                     "A shutdown manager must never restart or overwrite storage")

        let manager = DockManager()
        defer { manager.shutdown() }
        manager.createDock()
        let empty = manager.configurations[0]
        precondition(empty.applications.isEmpty, "New docks must not contain development examples")
        manager.restoreDefaultLayout()
        precondition(manager.configurations.count == 1 && manager.configurations[0].applications.isEmpty)
        manager.closeDock(manager.configurations[0].id)
        var references: [WeakPanel] = []
        for index in 0..<40 {
            let before = Set(NSApp.windows.map(\.windowNumber))
            manager.createDock()
            let id = manager.configurations.last!.id
            let panel = NSApp.windows.compactMap { $0 as? DockPanel }.first { !before.contains($0.windowNumber) }!
            references.append(WeakPanel(panel: panel))
            manager.renameDock(id, to: "Stress \(index)")
            manager.setOrientation(id, to: index.isMultiple(of: 2) ? .vertical : .horizontal)
        }
        precondition(manager.configurations.count == 40)
        for id in manager.configurations.map(\.id) { manager.closeDock(id) }
        precondition(manager.configurations.isEmpty && references.allSatisfy { $0.panel?.isVisible != true })
        try await Task.sleep(for: .milliseconds(100))
        precondition(references.allSatisfy { $0.panel == nil }, "Closed dock windows must be released")

        let applications = ApplicationService()
        defer { applications.activity.shutdown() }
        weak var releasedController: DockWindowController?
        weak var releasedIcon: ApplicationIconButton?
        weak var releasedHost: NSView?
        autoreleasepool {
            let item = TestApplications.installed()[0]
            let dock = DockConfiguration(name: "Ownership", position: DockPosition(x: 100, y: 100), applications: [item],
                                         behavior: DockBehavior(windowPreviewsEnabled: true))
            let controller = DockWindowController(configuration: dock)
            releasedController = controller
            controller.update(configuration: dock, applications: applications, launch: { _ in })
            controller.show()
            let host = controller.window!.contentView as! DockDropHostingView
            host.layoutSubtreeIfNeeded()
            let button = host.applicationButtons[0]
            releasedIcon = button
            releasedHost = host
            button.applyActivity(running: false, state: .idle)
            let menu = button.contextMenu()
            menu.update()
            precondition(menu.items.first { $0.title == "Show Window Previews" }?.isEnabled == false,
                         "Menu validation must preserve an unavailable preview command")
            precondition(menu.items.first { $0.title == "Quit \(item.name)" }?.isEnabled == false,
                         "Quit must be disabled for a stopped app")
            controller.dispose()
        }
        try await Task.sleep(for: .milliseconds(150))
        precondition(releasedController == nil && releasedHost == nil && releasedIcon == nil,
                     "Controller, hosting view and icon callbacks must release on disposal")
        guard let path = ProcessInfo.processInfo.environment["MULTIDOCK_ACTIVITY_PROBE"] else {
            preconditionFailure("Missing native launch probe")
        }
        let item = try applications.item(at: URL(fileURLWithPath: path))
        let foreground = NSWorkspace.shared.frontmostApplication
        defer { _ = foreground?.activate(options: []) }
        try await applications.launch(item)
        try await Task.sleep(for: .milliseconds(100))
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == item.bundleIdentifier && !$0.isTerminated }
        precondition(running.count == 1 && applications.activity.launchState(item.id) == .succeeded)
        let instance = running[0]
        defer { if !instance.isTerminated { instance.terminate() } }
        precondition(instance.isActive, "A dock launch must activate the selected regular application")
        let denied = ApplicationWindowService(permissionCheck: { false })
        try await denied.activate(bundleIdentifier: item.bundleIdentifier, mode: .smartActivate, restoreMinimized: true)
        try await denied.activate(bundleIdentifier: item.bundleIdentifier, mode: .cycleWindows, restoreMinimized: false)
        precondition(instance.isActive, "Denied Accessibility must fall back to ordinary app activation without prompting")
        let copiedEntry = item.copy()
        try await applications.launch(copiedEntry)
        let reused = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == item.bundleIdentifier && !$0.isTerminated }
        precondition(reused.map(\.processIdentifier) == running.map(\.processIdentifier), "An already running app must reuse its process")
        var requestedItem: UUID?
        let button = ApplicationIconButton()
        var actions = DockActions()
        actions.quit = { selected in
            requestedItem = selected.id
            do { try applications.quit(selected) }
            catch { preconditionFailure("Quit failed: \(error.localizedDescription)") }
        }
        ApplicationIcon(item: item, configuration: DockConfiguration(name: "Quit test", position: DockPosition(x: 100, y: 100), applications: [item]),
                        image: applications.icon(for: item), actions: actions, launch: {}, close: {},
                        running: true).configure(button)
        let menu = button.contextMenu()
        menu.update()
        let quit = menu.items.first { $0.title == "Quit \(item.name)" }!
        precondition(quit.isEnabled)
        precondition(NSApp.sendAction(quit.action!, to: quit.target, from: quit))
        precondition(requestedItem == item.id, "Quit must target the selected entry")
        for _ in 0..<50 where !instance.isTerminated {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(instance.isTerminated, "Quit must normally terminate the test app")
        try applications.quit(item) // A stale menu after termination is harmless.
        try await verifyFileDrops()
        print("PASS: enabled running-app Quit menu invokes normal termination; stopped-app menu disabled; repeated quit safe")
        print("PASS: actual ApplicationService launch, native activation, existing process reuse, success feedback")
        print("PASS: terminal shutdown, storage preservation, empty production defaults, 40 simultaneous docks, rapid deletion, window/host/icon release, unavailable preview menu validation")
    }
    private static func verifyFileDrops() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MultiDock-documents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.txt"), second = folder.appendingPathComponent("second.txt")
        try Data("original one".utf8).write(to: first); try Data("original two".utf8).write(to: second)
        let unsupported = folder.appendingPathComponent("image.png")
        try Data().write(to: unsupported)
        let receipt = folder.appendingPathComponent("received.json")
        let path = ProcessInfo.processInfo.environment["MULTIDOCK_ACTIVITY_PROBE"]!
        let service = ApplicationService()
        defer { service.activity.shutdown() }
        let item = try service.item(at: URL(fileURLWithPath: path))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["MULTIDOCK_TEST_OPEN_RECEIPT": receipt.path]
        let probe = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
        defer { if !probe.isTerminated { probe.terminate() } }
        precondition(service.canOpen([first, second], with: item))
        precondition(!service.canOpen([unsupported], with: item))
        let manager = DockManager(initialApplications: [item])
        defer { manager.shutdown() }
        manager.createDock()
        let dockID = manager.configurations[0].id
        manager.setPositionLocked(true, in: dockID)
        let panel = NSApp.windows.first { ($0.delegate as? DockWindowController)?.dockID == dockID }!
        let host = panel.contentView as! DockDropHostingView
        host.layoutSubtreeIfNeeded()
        let button = host.applicationButtons[0]
        let drag = SmokeDragInfo(window: panel)
        drag.draggingSourceOperationMask = .copy
        drag.draggingPasteboard.writeObjects([first as NSURL, second as NSURL])
        let originalFrame = panel.frame
        let originalEntries = manager.configurations[0].applications
        precondition(button.draggingEntered(drag) == .copy && button.prepareForDragOperation(drag))
        precondition(button.performDragOperation(drag))
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: receipt.path) { try await Task.sleep(for: .milliseconds(50)) }
        let received = try JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))
        precondition(Set(received.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == Set([first, second].map { $0.resolvingSymlinksInPath().path }))
        precondition(manager.configurations[0].applications == originalEntries, "Document drops must not alter dock entries")
        precondition(panel.frame == originalFrame, "Document drops must not move locked docks")
        try FileManager.default.removeItem(at: receipt)
        try await service.open([folder], with: item)
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: receipt.path) { try await Task.sleep(for: .milliseconds(50)) }
        let folderReceipt = try JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))
        precondition(folderReceipt.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [folder.resolvingSymlinksInPath().path])
        try FileManager.default.removeItem(at: receipt)
        let stackID = manager.createStack(in: dockID)!
        try manager.insertApplicationURLs([URL(fileURLWithPath: path)], into: dockID, at: 0, stackID: stackID)
        host.layoutSubtreeIfNeeded()
        let stack = manager.configurations[0].applications.first { $0.id == stackID }!
        let foreground = NSWorkspace.shared.frontmostApplication
        defer { _ = foreground?.activate(options: []) }
        NSApp.activate(ignoringOtherApps: true)
        manager.showGroup(stack, in: dockID, anchor: host.applicationButtons.first { $0.itemID == stackID }!)
        try await Task.sleep(for: .milliseconds(120))
        func find(_ view: NSView) -> ApplicationIconButton? {
            if let button = view as? ApplicationIconButton, button.itemID == stack.children[0].id { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        let child = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first!
        child.layoutSubtreeIfNeeded()
        precondition(child.hasRenderedIcon, "SwiftUI-hosted stack app icons must retain their rendering layer")
        let childDrop = SmokeDragInfo(window: child.window!)
        childDrop.draggingSourceOperationMask = .copy
        childDrop.draggingPasteboard.writeObjects([first as NSURL])
        precondition(child.draggingEntered(childDrop) == .copy && child.performDragOperation(childDrop))
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: receipt.path) { try await Task.sleep(for: .milliseconds(50)) }
        let childReceipt = try JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))
        precondition(childReceipt.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [first.resolvingSymlinksInPath().path])
        precondition(manager.configurations[0].applications.first { $0.id == stackID }!.children == stack.children)
        drag.draggingPasteboard.clearContents(); drag.draggingPasteboard.writeObjects([unsupported as NSURL])
        precondition(button.draggingEntered(drag).isEmpty && !button.prepareForDragOperation(drag))
        button.draggingExited(drag)
        drag.draggingPasteboard.clearContents(); drag.draggingPasteboard.writeObjects([first as NSURL])
        drag.draggingSourceOperationMask = .move
        precondition(button.draggingEntered(drag).isEmpty, "Document drops must never negotiate moving a file")
        button.draggingExited(drag)
        let keptFirst = try Data(contentsOf: first), keptSecond = try Data(contentsOf: second)
        precondition(keptFirst == Data("original one".utf8) && keptSecond == Data("original two".utf8))
        print("PASS: actual single/multiple-document and folder delivery, including an app inside a stack, through NSWorkspace to compatible probe, native icon drop routing, locked window stability, incompatible target rejection, no move operation or permanent document entries, original contents intact")
    }

    private static func verifyStacks() async throws {
        let manager = DockManager()
        defer { manager.shutdown() }
        manager.createDock()
        let dockID = manager.configurations[0].id
        let stackID = manager.createStack(in: dockID)!
        manager.renameStack(stackID, in: dockID, name: "Native Stack", symbol: "hammer.fill")
        let urls = TestApplications.installed().prefix(2).compactMap(\.location)
        try manager.insertApplicationURLs(urls, into: dockID, at: 0, stackID: stackID)
        manager.setPositionLocked(true, in: dockID)
        let panel = NSApp.windows.first { ($0.delegate as? DockWindowController)?.dockID == dockID }!
        let host = panel.contentView as! DockDropHostingView
        host.layoutSubtreeIfNeeded()
        let foreground = NSWorkspace.shared.frontmostApplication
        defer { _ = foreground?.activate(options: []) }
        NSApp.activate(ignoringOtherApps: true)
        let stack = manager.configurations[0].applications[0]
        manager.showGroup(stack, in: dockID, anchor: host.applicationButtons[0])
        try await Task.sleep(for: .milliseconds(150))
        precondition(manager.hasOpenStack, "A stack must open a native popover")
        let first = stack.children[0].id
        manager.moveStackItem(first, stackID: stackID, in: dockID, by: 1)
        precondition(manager.configurations[0].applications[0].children[1].id == first)
        manager.removeApplication(first, from: dockID, stackID: stackID)
        precondition(manager.configurations[0].applications[0].children.count == 1)
        var autoHide = manager.configurations[0].behavior
        autoHide.autoHideEnabled = true; autoHide.autoHideDelay = 0.2; autoHide.visibilityDuration = 0.05
        manager.setBehavior(autoHide, in: dockID)
        let display = DisplayService.current.first!
        manager.placeDock(dockID, anchor: NSEvent.mouseLocation.x > display.visibleFrame.midX ? .topLeft : .bottomRight)
        let owner = panel.delegate as! DockWindowController
        owner.interactions.pointerChanged(CGPoint(x: 10, y: 10)) // Simulate a missing parent exit event.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(350))
        precondition(!manager.hasOpenStack && owner.interactions.isAutoHidden,
                     "Closing a stack popover must clear stale parent hover and resume auto-hide")
        manager.removeApplication(stackID, from: dockID)
        precondition(!manager.hasOpenStack && manager.configurations[0].applications.isEmpty)
        print("PASS: typed stack creation/rename/symbol, native popover on locked dock, insertion, child reorder/removal, stack deletion closes popover")
    }

    private static func verifyPositionLocks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DockStore(url: folder.appendingPathComponent("docks.json"))
        let manager = DockManager(store: store, initialApplications: TestApplications.installed())
        await manager.start()
        manager.createDock()
        let ids = manager.configurations.map(\.id)
        func panel(_ id: UUID) -> DockPanel {
            NSApp.windows.compactMap { $0 as? DockPanel }.first { ($0.delegate as? DockWindowController)?.dockID == id }!
        }
        manager.setPositionLocked(true, in: ids[0])
        precondition(panel(ids[0]).positionLocked && !panel(ids[1]).positionLocked)
        let lockedPanel = panel(ids[0])
        let frame = lockedPanel.frame
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: lockedPanel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        lockedPanel.startPositionDrag(with: event)
        precondition(!lockedPanel.isPositionDragging && lockedPanel.frame == frame && !lockedPanel.isMovable)
        let first = manager.configurations[0].applications[0].id
        manager.moveApplication(first, in: ids[0], by: 1)
        precondition(manager.configurations[0].applications[1].id == first)
        manager.setGlobalPositionLocked(true)
        precondition(panel(ids[0]).positionLocked && panel(ids[1]).positionLocked)
        manager.setGlobalPositionLocked(false)
        precondition(panel(ids[0]).positionLocked && !panel(ids[1]).positionLocked)
        manager.resetPosition(ids[0])
        precondition(DisplayService.current.contains { $0.visibleFrame.contains(lockedPanel.frame) })
        manager.setGlobalPositionLocked(true)
        try await manager.flush()
        let snapshot = manager.configurations
        manager.shutdown()
        let reopened = DockManager(store: DockStore(url: store.url))
        defer { reopened.shutdown() }
        await reopened.start()
        precondition(reopened.globalPositionLocked && reopened.configurations == snapshot)
        reopened.setGlobalPositionLocked(false)
        precondition(panel(ids[0]).positionLocked && !panel(ids[1]).positionLocked)
        print("PASS: individual/global position locks, native pointer-drag guard, reordering while locked, programmatic recovery, persisted global/individual preferences")
    }
    private final class WeakPanel {
        weak var panel: DockPanel?
        init(panel: DockPanel) { self.panel = panel }
    }
}
