import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let dockManager = DockManager(store:
        ProcessInfo.processInfo.environment["MULTIDOCK_DISABLE_PERSISTENCE"] == "1" ? nil : .standard)
    private var startupTask: Task<Void, Never>?
    private var terminationPending = false
    private var statusItem: NSStatusItem?
    private var managementController: ManageDocksWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        dockManager.showSettings = { [weak self] in self?.manageDocks() }
        installMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "MultiDock")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MultiDock"
            button.setAccessibilityLabel("MultiDock")
        }
        let menu = NSMenu()
        menu.addItem(menuItem("Create Dock", action: #selector(createDock), key: "n"))
        menu.addItem(menuItem("Settings…", action: #selector(manageDocks), key: ","))
        menu.addItem(menuItem("Hide Docks Temporarily", action: #selector(toggleDockVisibility), key: "h"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit MultiDock", action: #selector(quit), key: "q"))
        item.menu = menu
        statusItem = item
        startupTask = Task { @MainActor [weak self] in await self?.dockManager.start() }
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func installMainMenu() {
        // Keep text editing shortcuts available while the management window is key.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MultiDock")
        appMenu.addItem(menuItem("Create Dock", action: #selector(createDock), key: "n"))
        appMenu.addItem(menuItem("Settings…", action: #selector(manageDocks), key: ","))
        appMenu.addItem(menuItem("Hide Docks Temporarily", action: #selector(toggleDockVisibility), key: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Quit MultiDock", action: #selector(quit), key: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func createDock() { dockManager.createDock() }
    @objc private func manageDocks() {
        if managementController == nil {
            managementController = ManageDocksWindowController(manager: dockManager)
        }
        managementController?.present()
    }
    @objc private func toggleDockVisibility() { dockManager.toggleTemporaryVisibility() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening an all-disabled or empty collection should expose management, never create a duplicate dock.
        if !flag { manageDocks() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDockVisibility) {
            menuItem.title = dockManager.docksTemporarilyHidden ? "Show Docks" : "Hide Docks Temporarily"
        }
        return menuItem.action != #selector(createDock) || !dockManager.isLoading
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor [self] in
            await startupTask?.value
            do {
                try await dockManager.flush()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not save your docks"
                alert.informativeText = "\(error.localizedDescription)\nQuit without saving the latest changes, or cancel to keep working."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Without Saving")
                NSApp.activate(ignoringOtherApps: true)
                let quit = alert.runModal() == .alertSecondButtonReturn
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: quit)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockManager.shutdown()
        managementController?.close()
        managementController = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
