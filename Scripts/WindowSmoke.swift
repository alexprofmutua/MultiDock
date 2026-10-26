import AppKit
import ServiceManagement

/// Runs real AppKit windows without launching another application or changing user data.
@main
struct WindowSmoke {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if ProcessInfo.processInfo.environment["MULTIDOCK_POLISH_ONLY"] == "1" {
            try await PolishSmoke.run()
            return
        }
        let wasActive = app.isActive
        let manager = DockManager(initialApplications: TestApplications.installed(), newDockBehavior: DockBehavior())
        defer { manager.shutdown() }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        manager.createDock()
        manager.createDock()
        precondition(manager.configurations.count == 2, "Manager must own both docks")
        let first = manager.configurations[0]
        let second = manager.configurations[1]
        precondition(first.id != second.id)
        let panels = app.windows.compactMap { $0 as? DockPanel }
        precondition(panels.filter(\.isVisible).count == 2)
        for panel in panels {
            precondition(!panel.canBecomeKey && !panel.canBecomeMain)
            precondition(panel.styleMask.contains(.nonactivatingPanel))
            precondition(panel.styleMask.contains(.borderless))
            precondition(panel.level == .floating && !panel.hidesOnDeactivate)
            precondition(panel.contentView != nil)
            panel.contentView?.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { descendants($0) }
            }
            let handle = descendants(panel.contentView!).first { String(describing: type(of: $0)) == "DragHandleView" }
            precondition((handle as? NSImageView)?.image != nil, "Drag handle symbol must exist")
            precondition(handle != nil && handle!.bounds.width > 0 && handle!.bounds.height > 0,
                         "Drag handle must have a visible hit area")
        }
        precondition(app.isActive == wasActive, "Creating docks must not activate MultiDock")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID,
                     "Creating docks must not change the foreground app")
        manager.setOrientation(first.id, to: .vertical)
        precondition(manager.configurations[0].orientation == .vertical)
        precondition(manager.configurations[1].orientation == .horizontal)
        let vertical = panels.first { $0.title == first.name }!
        precondition(vertical.frame.height > vertical.frame.width)
        manager.renameDock(first.id, to: "Independent")
        precondition(vertical.title == "Independent")
        precondition(manager.configurations[1] == second)
        func appearanceDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { appearanceDescendants($0) } }
        let originalHost = vertical.contentView as! DockDropHostingView
        let unchangedPanel = panels.first { $0.title == second.name }!
        let unchangedHost = unchangedPanel.contentView!
        let unchangedFrame = unchangedPanel.frame
        for size in [24.0, 48.0, 64.0] {
            let style = DockAppearance(iconSize: size, spacing: 8, padding: 10, colorMode: .dark,
                                       backgroundOpacity: 0.5, cornerRadius: 24)
            manager.setAppearance(style, in: first.id)
            vertical.contentView?.layoutSubtreeIfNeeded()
            precondition(vertical.contentView === originalHost, "Appearance updates must reuse the host")
            precondition(unchangedPanel.contentView === unchangedHost && unchangedPanel.frame == unchangedFrame)
            precondition(manager.configurations[1] == second, "Unrelated dock configuration must stay unchanged")
            precondition(vertical.appearance?.name == .darkAqua)
            let icons = appearanceDescendants(originalHost).compactMap { $0 as? ApplicationIconButton }
            precondition(icons.count == first.applications.count)
            precondition(icons.allSatisfy { $0.iconDrawSize == size && $0.bounds.width == size + 8 })
            let surface = appearanceDescendants(originalHost).compactMap { $0 as? DockSurface }.first!
            precondition(surface.bounds.size == vertical.frame.size)
            precondition(surface.effect.blendingMode == .behindWindow && surface.effect.state == .active)
            precondition(surface.style == style)
        }
        manager.updateAccessibility(DockAccessibility(reduceTransparency: true, reduceMotion: true, increaseContrast: true))
        originalHost.layoutSubtreeIfNeeded()
        let reducedSurface = appearanceDescendants(originalHost).compactMap { $0 as? DockSurface }.first!
        precondition(reducedSurface.effect.isHidden && reducedSurface.effect.alphaValue == 1)
        precondition(reducedSurface.preferences.increaseContrast)
        precondition(reducedSurface.layer?.backgroundColor?.alpha == 1)
        precondition(appearanceDescendants(originalHost).compactMap { $0 as? ApplicationIconButton }.allSatisfy { !$0.animatesDragCancellation })
        manager.updateAccessibility(.current)
        var lightStyle = DockAppearance()
        lightStyle.colorMode = .light
        manager.setAppearance(lightStyle, in: first.id)
        precondition(vertical.appearance?.name == .aqua)
        manager.setAppearance(DockAppearance(), in: first.id)
        precondition(vertical.appearance == nil)
        precondition(unchangedPanel.contentView === unchangedHost)
        let screen = DisplayService.current.first(where: \.isPrimary)!
        for connected in DisplayService.current {
            manager.placeDock(first.id, anchor: .topRight, displayID: connected.id)
            precondition(connected.visibleFrame.contains(vertical.frame))
        }
        manager.placeDock(first.id, anchor: .bottomRight, displayID: screen.id)
        precondition(vertical.frame.maxX == screen.visibleFrame.maxX && vertical.frame.minY == screen.visibleFrame.minY)
        manager.setSnapping(false, in: first.id)
        let freePoint = CGPoint(x: screen.visibleFrame.midX - 100, y: screen.visibleFrame.midY - 100)
        vertical.setFrameOrigin(freePoint)
        let actualFreePoint = vertical.frame.origin // AppKit may align a proposed fractional point to a backing pixel.
        manager.finishPositionDrag(first.id)
        precondition(manager.configurations[0].position == DockPosition(x: actualFreePoint.x, y: actualFreePoint.y),
                     "Drag must capture actual AppKit origin: \(manager.configurations[0].position), expected \(actualFreePoint)")
        precondition(abs(actualFreePoint.x - freePoint.x) <= 1 && abs(actualFreePoint.y - freePoint.y) <= 1)
        manager.renameDock(first.id, to: "Independent")
        precondition(vertical.frame.origin == actualFreePoint)
        let service = ApplicationService()
        let examples = TestApplications.installed()
        precondition(examples.count >= 2)
        let firstURL = try service.resolvedURL(for: examples[0])
        let secondURL = try service.resolvedURL(for: examples[1])
        for item in manager.configurations[0].applications { manager.removeApplication(item.id, from: first.id) }
        for item in manager.configurations[1].applications { manager.removeApplication(item.id, from: second.id) }
        try manager.insertApplicationURLs([firstURL], into: first.id, at: 0)
        do {
            try manager.insertApplicationURLs([firstURL], into: first.id, at: 1)
            preconditionFailure("Duplicate addition must be rejected")
        } catch is DockEditError {}
        precondition(manager.configurations[0].applications.count == 1)
        let entry = manager.configurations[0].applications[0]
        let sourceHost = vertical.contentView as! DockDropHostingView
        sourceHost.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let sourceButton = descendants(sourceHost).compactMap { $0 as? ApplicationIconButton }.first!
        let secondPanel = panels.first { $0.title == second.name }!
        let targetHost = secondPanel.contentView as! DockDropHostingView
        let drop = SmokeDragInfo(window: secondPanel)
        defer { drop.draggingPasteboard.releaseGlobally() }
        drop.draggingSource = sourceButton
        drop.draggingSourceOperationMask = [.move, .copy]
        drop.draggingPasteboard.setData(try JSONEncoder().encode(DockItemDrag(dockID: first.id, itemID: entry.id)),
                                       forType: ApplicationIconButton.pasteboardType)
        precondition(targetHost.draggingEntered(drop) == .move)
        precondition(targetHost.prepareForDragOperation(drop))
        precondition(targetHost.performDragOperation(drop))
        precondition(manager.configurations[0].applications.isEmpty)
        precondition(manager.configurations[1].applications.map(\.id) == [entry.id])
        targetHost.layoutSubtreeIfNeeded()
        let movedButton = descendants(targetHost).compactMap { $0 as? ApplicationIconButton }.first!
        drop.draggingSource = movedButton
        drop.draggingDestinationWindow = vertical
        drop.draggingSourceOperationMask = .copy // AppKit applies Option to the source mask.
        drop.draggingPasteboard.clearContents()
        drop.draggingPasteboard.setData(try JSONEncoder().encode(DockItemDrag(dockID: second.id, itemID: entry.id)),
                                       forType: ApplicationIconButton.pasteboardType)
        precondition(sourceHost.draggingEntered(drop) == .copy)
        precondition(sourceHost.performDragOperation(drop))
        precondition(manager.configurations[0].applications.count == 1 && manager.configurations[1].applications.count == 1)
        precondition(manager.configurations[0].applications[0].id != entry.id)
        // Finder-style file URL drop always copies a reference, never moves an installed bundle.
        drop.draggingSource = nil
        drop.draggingSourceOperationMask = [.copy, .move]
        drop.draggingPasteboard.clearContents()
        drop.draggingPasteboard.writeObjects([secondURL as NSURL])
        precondition(sourceHost.draggingEntered(drop) == .copy)
        precondition(sourceHost.performDragOperation(drop))
        precondition(manager.configurations[0].applications.count == 2)
        precondition(FileManager.default.fileExists(atPath: secondURL.path))
        sourceHost.layoutSubtreeIfNeeded()
        let buttons = descendants(sourceHost).compactMap { $0 as? ApplicationIconButton }
        let context = buttons[0].contextMenu()
        precondition(context.items.map(\.title).contains("Reveal in Finder"))
        precondition(!context.items.map(\.title).contains("Remove from This Dock"))
        precondition(context.items.map(\.title).contains("Settings…"))
        // The settings interface uses this manager command to remove a reference.
        manager.removeApplication(buttons[0].itemID!, from: first.id)
        precondition(manager.configurations[0].applications.count == 1)
        precondition(FileManager.default.fileExists(atPath: firstURL.path))
        // Large user lists are scrollable rather than creating an off-screen panel.
        manager.setAllowsDuplicates(true, in: first.id)
        for _ in 0..<20 { try manager.insertApplicationURLs([secondURL], into: first.id, at: Int.max) }
        let available = NSScreen.main!.visibleFrame
        precondition(vertical.frame.height <= available.height)
        manager.closeDock(first.id)
        precondition(manager.configurations.map(\.id) == [second.id])
        precondition(!vertical.isVisible)
        manager.closeDock(second.id)
        precondition(manager.configurations.isEmpty)
        for _ in 0..<25 {
            manager.createDock()
            manager.closeDock(manager.configurations[0].id)
        }
        precondition(manager.configurations.isEmpty)
        precondition(!app.windows.contains { $0 is DockPanel && $0.isVisible })

        weak var releasedController: DockWindowController?
        autoreleasepool {
            let controller = DockWindowController(configuration: first)
            releasedController = controller
            controller.update(configuration: first, applications: ApplicationService(), launch: { _ in })
            controller.show()
            controller.dispose()
        }
        precondition(releasedController == nil, "Controller must be released after disposal")
        precondition(TestApplications.installed().count > 0, "Expected installed development examples")
        let savedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: savedDirectory) }
        let savedURL = savedDirectory.appendingPathComponent("docks.json")
        let persistent = DockManager(store: DockStore(url: savedURL), newDockBehavior: DockBehavior())
        await persistent.start()
        persistent.createDock()
        let savedIDs = persistent.configurations.map(\.id)
        persistent.placeDock(savedIDs[0], anchor: .topLeft, displayID: screen.id)
        persistent.placeDock(savedIDs[1], anchor: .bottomRight, displayID: screen.id)
        persistent.setOrientation(savedIDs[1], to: .vertical)
        persistent.setEnabled(false, in: savedIDs[1])
        let savedConfigurations = persistent.configurations
        try await persistent.flush()
        persistent.shutdown()
        let reopened = DockManager(store: DockStore(url: savedURL), newDockBehavior: DockBehavior())
        await reopened.start()
        precondition(reopened.configurations == savedConfigurations, "Restart must restore every independent configuration")
        await reopened.start()
        precondition(reopened.configurations.count == 2, "Repeated startup must not duplicate restored docks")
        precondition(!app.windows.contains { $0 is DockPanel && $0.title == savedConfigurations[1].name && $0.isVisible },
                     "Disabled docks must remain hidden after restart")
        for id in savedIDs { reopened.closeDock(id) }
        try await reopened.flush()
        reopened.shutdown()
        let emptySession = DockManager(store: DockStore(url: savedURL), newDockBehavior: DockBehavior())
        await emptySession.start()
        precondition(emptySession.configurations.isEmpty, "Intentionally closed docks must stay closed on restart")
        emptySession.shutdown()
        let managed = DockManager(initialApplications: TestApplications.installed(), newDockBehavior: DockBehavior())
        managed.createDock()
        let managedID = managed.configurations[0].id
        let managedPanel = app.windows.first { $0 is DockPanel && $0.isVisible }!
        let original = managed.configurations[0]
        managed.setEnabled(false, in: managedID)
        precondition(!managedPanel.isVisible && managed.configurations.count == 1)
        managed.setEnabled(true, in: managedID)
        precondition(managedPanel.isVisible)
        managed.placeDock(managedID, anchor: .topRight)
        let duplicateID = managed.duplicateDock(managedID)!
        precondition(managed.configurations[1].placement.anchor == .topRight, "Duplication must preserve attached positioning behavior")
        precondition(duplicateID != managedID && managed.configurations.count == 2)
        precondition(managed.configurations[1].applications.map(\.id) != original.applications.map(\.id))
        managed.setEnabled(false, in: duplicateID)
        let beforeHide = managed.configurations
        managed.toggleTemporaryVisibility()
        precondition(!app.windows.contains { $0 is DockPanel && $0.isVisible })
        managed.toggleTemporaryVisibility()
        precondition(managed.configurations == beforeHide && managedPanel.isVisible)
        precondition(app.windows.filter { $0 is DockPanel && $0.isVisible }.count == 1)
        if original.applications.count > 1 {
            let item = original.applications[0]
            managed.moveApplication(item.id, in: managedID, by: 1)
            precondition(managed.configurations[0].applications[1].id == item.id)
            managed.moveApplication(item.id, in: managedID, by: -1)
            precondition(managed.configurations[0].applications == original.applications)
        }
        managed.placeDock(managedID, anchor: .bottomLeft)
        managed.resetPosition(managedID)
        precondition(managed.configurations[0].placement.anchor == .free)
        precondition(abs(managed.configurations[0].placement.relativeX - 0.5) < 0.001)
        precondition(abs(managed.configurations[0].placement.relativeY - 0.5) < 0.001)
        managed.restoreDefaultLayout()
        precondition(managed.configurations.count == 1 && managed.configurations[0].isEnabled)
        precondition(managed.configurations[0].id != managedID && managed.configurations[0].id != duplicateID)
        let settings = ManageDocksWindowController(manager: managed)
        settings.present()
        try await Task.sleep(for: .milliseconds(200))
        let settingsView = settings.window!.contentView!
        settingsView.layoutSubtreeIfNeeded()
        precondition(settingsView.bounds.width >= 800 && settingsView.bounds.height >= 570)
        if let destination = ProcessInfo.processInfo.environment["MULTIDOCK_SETTINGS_SNAPSHOT"],
           let bitmap = settingsView.bitmapImageRepForCachingDisplay(in: settingsView.bounds) {
            settingsView.cacheDisplay(in: settingsView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                preconditionFailure("Settings snapshot could not be encoded")
            }
            try png.write(to: URL(fileURLWithPath: destination))
        }
        settings.close()
        managed.shutdown()

        let loginClient = SmokeLoginItemClient()
        let login = LoginItemService(client: loginClient)
        precondition(!login.isRequested && loginClient.registrations == 0)
        await login.setEnabled(true)
        precondition(login.status == .enabled && loginClient.registrations == 1)
        await login.setEnabled(true)
        precondition(loginClient.registrations == 1, "Already enabled login items must not be registered again")
        await login.setEnabled(false)
        precondition(!login.isRequested && loginClient.removals == 1)
        loginClient.status = .requiresApproval
        login.refresh()
        precondition(login.isRequested && login.statusText.contains("Approve"))
        await login.setEnabled(false)
        loginClient.shouldFail = true
        await login.setEnabled(true)
        precondition(login.errorMessage != nil && !login.isRequested && !login.isUpdating)
        print("PASS: enable/disable, independent duplication, temporary visibility, management reorder, reset position/defaults, disabled restart, idempotent startup, login status/approval/failure using injected client")
        try await InteractionSmoke.run()
        try await PreviewSmoke.run()
        try await QualitySmoke.run()
        try await PolishSmoke.run()
        print("Connected displays exercised: \(DisplayService.current.count)")
        print("PASS: creation, independent identity/orientation/name, nonactivation, panel policy, close, 25 lifecycle cycles, controller release, installed app discovery, appearance isolation, size changes, native glass, accessibility fallback, native move/copy/file-URL drop callbacks, context removal, duplicate rejection, scroll bounds, anchored placement, free movement, persistent restart restoration")
    }
}

@MainActor
final class SmokeDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = []
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow) { draggingDestinationWindow = window; super.init() }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
private final class SmokeLoginItemClient: LoginItemClient {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var shouldFail = false
    struct Failure: LocalizedError {
        var errorDescription: String? { "Simulated ServiceManagement failure" }
    }
    func register() throws {
        if shouldFail { throw Failure() }
        registrations += 1
        status = .enabled
    }
    func unregister() async throws {
        removals += 1
        status = .notRegistered
    }
}
