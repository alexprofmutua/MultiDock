import AppKit
import Combine
import OSLog
import UniformTypeIdentifiers

@MainActor
final class DockManager: NSObject, ObservableObject {
    @Published private(set) var globalPositionLocked = false
    @Published private(set) var globalRevealStyle = DockRevealStyle()
    @Published private(set) var configurations: [DockConfiguration] = []
    private var controllers: [UUID: DockWindowController] = [:]
    var showSettings: @MainActor () -> Void = {}
    private let applications = ApplicationService()
    private let stacks = StackPopoverController()
    private let previews = WindowPreviewController()
    private let windowCommands = ApplicationWindowService()
    private let newDockBehavior: DockBehavior
    private var systemSleeping = false
    private var screensSleeping = false
    private var desktopSuspended: Bool { systemSleeping || screensSleeping }
    private let logger = Logger(subsystem: "org.multidock.MultiDock", category: "Applications")
    private var nextNumber = 1
    private var accessibility = DockAccessibility.current
    // Keep an AppKit dragging source alive even when a successful move removes its view.
    private var documentTasks: [UUID: Task<Void, Never>] = [:]
    private var clickTask: Task<Void, Never>?
    private var activeDragSource: NSView?
    @Published private(set) var availableDisplays: [DockDisplay] = DisplayService.current
    @Published private(set) var isLoading: Bool
    @Published private(set) var docksTemporarilyHidden = false
    @Published private(set) var storageMessage: String?
    private var lastScheduledPositionLocked: Bool?
    private var lastScheduledRevealStyle: DockRevealStyle?
    private var lastScheduledSnapshot: [DockConfiguration]?
    private let store: DockStore?
    private var savingEnabled = true
    private var hasStarted = false
    private var isShutdown = false
    private let initialApplications: [ApplicationItem]
    private var saveTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var reportedSaveFailure = false
    private var positioningDrags: Set<UUID> = []
    private struct RevealRequest: Equatable {
        let id: UUID
        let frame: CGRect
        let orientation: DockOrientation
        let bounds: CGRect
    }
    private var lastRevealRequests: [RevealRequest] = []

    init(store: DockStore? = nil, initialApplications: [ApplicationItem] = [], newDockBehavior: DockBehavior = DockBehavior(magnificationEnabled: true)) {
        self.store = store
        self.initialApplications = initialApplications
        self.newDockBehavior = newDockBehavior
        isLoading = store != nil
        super.init()
        applications.activity.onChange = { [weak self] in
            guard let self else { return }
            previews.dismiss()
            if stacks.isShown { objectWillChange.send() }
            for controller in controllers.values { controller.refreshActivity(using: applications) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(desktopChanged), name: name, object: nil)
        }
    }

    func start() async {
        guard !hasStarted, !isShutdown else { return }
        hasStarted = true
        var restored: [DockConfiguration]?
        do {
            if let result = try await store?.loadRecovering() {
                guard !isShutdown else { return }
                restored = result.docks
                globalRevealStyle = result.globalRevealStyle
                globalPositionLocked = result.globalPositionLocked
                if let backup = result.backupURL {
                    let detail = result.notices.isEmpty ? "Updated the saved configuration format." : result.notices.joined(separator: "\n")
                    storageMessage = "\(detail)\nOriginal saved at \(backup.path)"
                }
            }
        }
        catch {
            guard !isShutdown else { return }
            savingEnabled = false
            storageMessage = "Restoration failed: \(error.localizedDescription) This session will not overwrite the original file."
            report(error, title: "Could not restore saved docks. The original file is unchanged; this session will not be saved.")
        }
        guard !isShutdown else { return }
        isLoading = false
        availableDisplays = DisplayService.current
        if let restored {
            configurations = restored
            nextNumber = restored.count + 1
            for configuration in restored {
                installController(configuration)
                render(configuration, restoring: true)
                applyVisibility(configuration.id)
            }
            scheduleSave()
        } else {
            createDock()
        }
    }

    func createDock() {
        guard !isLoading, !isShutdown else { return }
        availableDisplays = DisplayService.current
        let pointer = NSEvent.mouseLocation
        let display = availableDisplays.first { $0.frame.contains(pointer) }
            ?? availableDisplays.first(where: \.isPrimary) ?? availableDisplays.first
        let frame = display?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let offset = CGFloat(configurations.count % 8) * 28
        while configurations.contains(where: { $0.name == "Dock \(nextNumber)" }) { nextNumber += 1 }
        let configuration = DockConfiguration(name: "Dock \(nextNumber)",
            position: DockPosition(x: frame.midX - 100 + offset, y: frame.midY - offset),
            applications: initialApplications.map { $0.copy() }, behavior: newDockBehavior)
        nextNumber += 1
        configurations.append(configuration)
        installController(configuration)
        render(configuration)
        applyVisibility(configuration.id)
        scheduleSave()
    }

    private func installController(_ configuration: DockConfiguration) {
        let controller = DockWindowController(configuration: configuration)
        controller.previews = previews
        controller.onRequestDelete = { [weak self] id in self?.requestDeleteDock(id) }
        controller.onClose = { [weak self] id in self?.didClose(id) }
        controller.onMove = { [weak self] id, position in self?.updatePosition(id, position) }
        controller.onScreenChange = { [weak self] id in
            guard let self, !positioningDrags.contains(id) else { return }
            refreshDisplays()
        }
        controller.onDragStart = { [weak self] id in self?.positioningDrags.insert(id) }
        controller.onDragEnd = { [weak self] id in self?.finishPositionDrag(id) }
        controllers[configuration.id] = controller
        // Requests can stay identical while restored controllers are installed one by one.
        // Invalidate the allocation cache so every new controller receives its reveal zone.
        lastRevealRequests.removeAll()
    }

    /// Internal confirmed deletion path; UI entry points use requestDeleteDock.
    func closeDock(_ id: UUID) { controllers[id]?.close() }

    func requestDeleteDock(_ id: UUID) {
        guard let dock = configurations.first(where: { $0.id == id }) else { return }
        if confirm("Delete \(dock.name.isEmpty ? "Untitled Dock" : dock.name)?",
                   detail: "This removes this dock and its settings. Installed applications stay on your Mac.", action: "Delete Dock") {
            closeDock(id)
        }
    }

    private func confirm(_ title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func applyVisibility(_ id: UUID) {
        guard let dock = configurations.first(where: { $0.id == id }) else { return }
        if dock.isEnabled && !docksTemporarilyHidden && !desktopSuspended { controllers[id]?.show() }
        else { stacks.dismiss(dockID: id); controllers[id]?.setVisible(false) }
    }

    func setEnabled(_ enabled: Bool, in id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }), configurations[index].isEnabled != enabled else { return }
        if positioningDrags.contains(id) { finishPositionDrag(id) }
        configurations[index].isEnabled = enabled
        updateRevealPlacements()
        applyVisibility(id)
        scheduleSave()
    }

    func toggleTemporaryVisibility() {
        for id in Array(positioningDrags) { finishPositionDrag(id) }
        docksTemporarilyHidden.toggle()
        for dock in configurations { applyVisibility(dock.id) }
    }

    @discardableResult
    func duplicateDock(_ id: UUID) -> UUID? {
        guard !isLoading, let source = configurations.first(where: { $0.id == id }) else { return nil }
        let names = Set(configurations.map(\.name))
        let base = source.name.isEmpty ? "Untitled Dock" : source.name
        var name = "\(base) Copy"
        var number = 2
        while names.contains(name) { name = "\(base) Copy \(number)"; number += 1 }
        var duplicate = source.duplicate(name: name)
        duplicate.position.x += 24
        duplicate.position.y -= 24
        configurations.append(duplicate)
        installController(duplicate)
        render(duplicate)
        applyVisibility(duplicate.id)
        return duplicate.id
    }

    func resetPosition(_ id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        availableDisplays = DisplayService.current
        guard let display = availableDisplays.first(where: { $0.id == configurations[index].placement.displayID })
            ?? availableDisplays.first(where: \.isPrimary) ?? availableDisplays.first else { return }
        configurations[index].placement.relativeX = 0.5
        configurations[index].placement.relativeY = 0.5
        DockPositioning.place(&configurations[index], on: display, anchor: .free)
        render(configurations[index])
    }

    func moveApplication(_ itemID: UUID, in id: UUID, by offset: Int) {
        guard let dock = configurations.first(where: { $0.id == id }),
              let index = dock.applications.firstIndex(where: { $0.id == itemID }) else { return }
        let destination = min(max(index + offset, 0), dock.applications.count - 1)
        guard destination != index else { return }
        do { try transferApplication(DockItemDrag(dockID: id, itemID: itemID), to: id,
                                     at: destination > index ? destination + 1 : destination, copy: false) }
        catch { report(error, title: "Could not reorder applications") }
    }

    func requestRestoreDefaultLayout() {
        guard !isLoading, !isShutdown else { return }
        if confirm("Restore the default layout?", detail: "Replace all docks with one empty default dock. Installed applications and Launch at Login are unchanged.",
                   action: "Restore Default Layout") { restoreDefaultLayout() }
    }

    func restoreDefaultLayout() {
        guard !isLoading, !isShutdown else { return }
        stacks.dismiss()
        let owned = Array(controllers.values)
        controllers.removeAll()
        owned.forEach { $0.dispose() }
        positioningDrags.removeAll()
        configurations.removeAll()
        activeDragSource = nil
        nextNumber = 1
        docksTemporarilyHidden = false
        createDock()
        applications.trimIconCache()
    }
    func showDock(_ id: UUID) {
        guard let dock = configurations.first(where: { $0.id == id }), dock.isEnabled else { return }
        if docksTemporarilyHidden { toggleTemporaryVisibility() }
        if dock.behavior.isCollapsed { setCollapsed(false, in: id) }
        else { render(dock) }
        applyVisibility(id)
        controllers[id]?.interactions.reveal()
    }

    func setBehavior(_ behavior: DockBehavior, in id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }), configurations[index].behavior != behavior.normalized else { return }
        configurations[index].behavior = behavior.normalized
        render(configurations[index])
    }
    func useDockStyleInteractions() {
        for dock in Array(configurations) {
            var behavior = dock.behavior
            behavior.autoHideEnabled = true
            behavior.magnificationEnabled = true
            setBehavior(behavior, in: dock.id)
        }
    }
    @objc private func systemColorsChanged(_ notification: Notification) {
        applications.trimIconCache()
        for dock in Array(configurations) { render(dock) }
    }

    func setCollapsed(_ value: Bool, in id: UUID) {
        guard let dock = configurations.first(where: { $0.id == id }) else { return }
        var behavior = dock.behavior
        behavior.isCollapsed = value
        setBehavior(behavior, in: id)
    }

    func setSnapping(_ enabled: Bool, in id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].placement.snappingEnabled = enabled
        if !enabled { configurations[index].placement.anchor = .free }
        render(configurations[index])
    }

    func placeDock(_ id: UUID, anchor: DockAnchor, displayID: String? = nil) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        availableDisplays = DisplayService.current
        let selectedID = displayID ?? configurations[index].placement.displayID
        guard let display = availableDisplays.first(where: { $0.id == selectedID })
            ?? availableDisplays.first(where: \.isPrimary) ?? availableDisplays.first else { return }
        DockPositioning.place(&configurations[index], on: display, anchor: anchor)
        render(configurations[index])
    }

    func finishPositionDrag(_ id: UUID) {
        positioningDrags.remove(id)
        guard let index = configurations.firstIndex(where: { $0.id == id }), let frame = controllers[id]?.window?.frame else { return }
        availableDisplays = DisplayService.current
        DockPositioning.finishDrag(frame, dock: &configurations[index], displays: availableDisplays)
        render(configurations[index])
    }

    func renameDock(_ id: UUID, to name: String) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].name = name
        controllers[id]?.window?.title = name
        // Refresh labels, including the close button's accessibility label.
        render(configurations[index])
    }

    func setOrientation(_ id: UUID, to orientation: DockOrientation) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].orientation = orientation
        render(configurations[index])
    }

    func setAppearance(_ appearance: DockAppearance, in id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        let normalized = appearance.normalized
        guard configurations[index].appearance != normalized else { return }
        configurations[index].appearance = normalized
        render(configurations[index])
    }

    func setGlobalPositionLocked(_ value: Bool) {
        guard globalPositionLocked != value, !isShutdown else { return }
        globalPositionLocked = value
        for dock in Array(configurations) { render(dock) }
        scheduleSave()
    }
    func setPositionLocked(_ value: Bool, in id: UUID) {
        guard let dock = configurations.first(where: { $0.id == id }) else { return }
        var behavior = dock.behavior
        behavior.positionLocked = value
        setBehavior(behavior, in: id)
    }

    func setGlobalRevealStyle(_ style: DockRevealStyle) {
        guard !isShutdown, globalRevealStyle != style.normalized else { return }
        globalRevealStyle = style.normalized
        updateRevealStyles()
        scheduleSave()
    }

    func setRevealStyle(_ style: DockRevealStyle, usesGlobal: Bool, in id: UUID) {
        guard !isShutdown, let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        var appearance = configurations[index].appearance
        appearance.revealTabStyle = style.normalized
        appearance.revealTabUsesGlobal = usesGlobal
        guard configurations[index].appearance != appearance else { return }
        configurations[index].appearance = appearance
        updateRevealStyles()
        scheduleSave()
    }

    private func updateRevealStyles() {
        for dock in configurations {
            controllers[dock.id]?.interactions.setRevealStyle(dock.appearance.effectiveRevealStyle(global: globalRevealStyle))
        }
    }

    @objc private func accessibilityChanged(_ notification: Notification) {
        updateAccessibility(.current)
    }

    // Also supports deterministic accessibility checks without altering system preferences.
    func updateAccessibility(_ preferences: DockAccessibility) {
        guard accessibility != preferences else { return }
        accessibility = preferences
        for configuration in Array(configurations) { render(configuration) }
    }

    var hasOpenStack: Bool { stacks.isShown }

    @discardableResult
    func createStack(in id: UUID) -> UUID? {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return nil }
        let item = DockItem.stack()
        configurations[index].applications.append(item)
        render(configurations[index])
        return item.id
    }
    func renameStack(_ itemID: UUID, in id: UUID, name: String, symbol: String? = nil) {
        guard let index = configurations.firstIndex(where: { $0.id == id }),
              let item = configurations[index].applications.firstIndex(where: { $0.id == itemID && $0.kind == .stack }) else { return }
        configurations[index].applications[item].name = name
        if let symbol, DockItem.stackSymbols.contains(symbol) { configurations[index].applications[item].stackSymbol = symbol }
        render(configurations[index])
    }
    func addFolder(to id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Add Folder Stack"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.resolvesAliases = true; panel.prompt = "Add Folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do { try insertFolderURL(url, into: id) }
            catch { report(error, title: "Could not add folder") }
        }
    }
    func insertFolderURL(_ url: URL, into id: UUID) throws {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { throw DockEditError.missingDock }
        var dock = configurations[index]
        try DockItemEditor.insert([applications.folderItem(at: url)], at: Int.max, into: &dock)
        configurations[index] = dock; render(dock)
    }
    func showGroup(_ item: DockItem, in id: UUID, anchor: NSView) {
        guard let owner = controllers[id] else { return }
        previews.dismiss()
        stacks.show(item: item, dockID: id, anchor: anchor, owner: owner, manager: self)
    }
    func launchFromStack(_ item: DockItem, in id: UUID) {
        guard let dock = configurations.first(where: { $0.id == id }) else { return }
        launch(item, behavior: dock.behavior)
    }
    func openFolder(_ item: DockItem) {
        do { openFolderEntry(try FolderReference.resolve(item)) }
        catch { report(error, title: "Folder unavailable") }
    }
    func openFolderEntry(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
            report(CocoaError(.fileReadNoSuchFile), title: "Could not open this item"); return
        }
    }
    func moveStackItem(_ itemID: UUID, stackID: UUID, in id: UUID, by offset: Int) {
        guard let dock = configurations.first(where: { $0.id == id }),
              let entries = try? DockItemEditor.entries(in: dock, stackID: stackID),
              let source = entries.firstIndex(where: { $0.id == itemID }) else { return }
        let next = min(max(source + offset, 0), entries.count - 1)
        guard next != source else { return }
        transferFromMenu(DockItemDrag(dockID: id, itemID: itemID, stackID: stackID), to: id,
            stackID: stackID, at: next > source ? next + 1 : next)
    }
    func transferFromMenu(_ drag: DockItemDrag, to id: UUID, stackID: UUID? = nil, at index: Int = Int.max, copy: Bool = false) {
        do { try transferApplication(drag, to: id, at: index, copy: copy, toStack: stackID) }
        catch { report(error, title: "Could not move application") }
    }
    func stackActions(dockID: UUID, stackID: UUID) -> DockActions {
        var actions = DockActions()
        actions.canOpenFiles = { [weak self] item, urls in self?.applications.canOpen(urls, with: item) ?? false }
        actions.openFiles = { [weak self] item, urls in self?.openDocuments(urls, with: item) ?? false }
        if let dock = configurations.first(where: { $0.id == dockID }) {
            actions.positionLockTitle = globalPositionLocked ? "Position Locked Globally…" : (dock.behavior.positionLocked ? "Unlock Position" : "Lock Position")
        }
        actions.togglePositionLock = { [weak self] in
            guard let self else { return }
            if globalPositionLocked { showSettings() }
            else if let dock = configurations.first(where: { $0.id == dockID }) { setPositionLocked(!dock.behavior.positionLocked, in: dockID) }
        }
        actions.sourceStackID = stackID
        actions.settings = { [weak self] in self?.showSettings() }
        actions.reveal = { [weak self] item in
            do { try self?.applications.reveal(item) } catch { self?.report(error, title: "Could not reveal application") }
        }
        actions.windowCommand = { [weak self] item, minimized in self?.changeWindows(item, minimized: minimized) }
        actions.quit = { [weak self] item in
            do { try self?.applications.quit(item) } catch { self?.report(error, title: "Could not quit application") }
        }
        actions.stackDrop = { [weak self] item, drag, urls, copy in
            guard let self, let dock = configurations.first(where: { $0.id == dockID }),
                  let entries = try? DockItemEditor.entries(in: dock, stackID: stackID) else { return false }
            return receiveDrop(drag, urls: urls, to: dockID, at: entries.firstIndex(where: { $0.id == item.id }) ?? Int.max,
                copy: copy, stackID: stackID)
        }
        actions.drop = { [weak self] drag, urls, _, copy in
            self?.receiveDrop(drag, urls: urls, to: dockID, at: Int.max, copy: copy, stackID: stackID) ?? false
        }
        actions.dragBegan = { [weak self] view in self?.activeDragSource = view }
        actions.dragEnded = { [weak self] in self?.activeDragSource = nil }
        return actions
    }

    func applicationLaunchState(_ item: DockItem) -> DockLaunchState { applications.activity.launchState(item.id) }
    func applicationIsRunning(_ item: DockItem) -> Bool { applications.activity.isRunning(item.bundleIdentifier) }

    func applicationIcon(_ item: ApplicationItem) -> NSImage { applications.icon(for: item) }

    func addApplications(to id: UUID, stackID: UUID? = nil) {
        guard configurations.contains(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Applications"
        panel.message = "Choose installed applications or aliases. Applications stay in their original locations."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle, .aliasFile, .symbolicLink]
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            do { try insertApplicationURLs(panel.urls, into: id, at: Int.max, stackID: stackID) }
            catch { report(error, title: "Could not add applications") }
        }
    }

    func insertApplicationURLs(_ urls: [URL], into id: UUID, at index: Int, stackID: UUID? = nil) throws {
        guard let dockIndex = configurations.firstIndex(where: { $0.id == id }) else { throw DockEditError.missingDock }
        // Validate the entire batch before changing either model or panel.
        let items = try urls.map { try applications.item(at: $0) }
        var configuration = configurations[dockIndex]
        if let stackID {
            var target = configuration
            target.applications = try DockItemEditor.entries(in: configuration, stackID: stackID)
            try DockItemEditor.insert(items, at: index, into: &target)
            try DockItemEditor.setEntries(target.applications, in: &configuration, stackID: stackID)
        } else { try DockItemEditor.insert(items, at: index, into: &configuration) }
        configurations[dockIndex] = configuration
        render(configuration)
    }

    func removeApplication(_ itemID: UUID, from id: UUID, stackID: UUID? = nil) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        var configuration = configurations[index]
        if stackID == nil { stacks.dismiss(dockID: id) }
        if let stackID, let group = configuration.applications.firstIndex(where: { $0.id == stackID }) {
            configuration.applications[group].children.removeAll { $0.id == itemID }
        } else { DockItemEditor.remove(itemID, from: &configuration) }
        configurations[index] = configuration
        applications.trimIconCache()
        render(configuration)
    }

    func setAllowsDuplicates(_ allows: Bool, in id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].allowsDuplicateApplications = allows
        render(configurations[index])
    }

    func transferApplication(_ drag: DockItemDrag, to id: UUID, at index: Int, copy: Bool, toStack: UUID? = nil) throws {
        var edited = configurations
        try DockItemEditor.transfer(drag, to: id, at: index, copy: copy, toStack: toStack, in: &edited)
        configurations = edited
        for configuration in edited where configuration.id == id || configuration.id == drag.dockID { render(configuration) }
    }

    private func receiveDrop(_ drag: DockItemDrag?, urls: [URL], to id: UUID, at index: Int, copy: Bool, stackID: UUID? = nil) -> Bool {
        do {
            if let drag { try transferApplication(drag, to: id, at: index, copy: copy, toStack: stackID) }
            else { try insertApplicationURLs(urls, into: id, at: index, stackID: stackID) }
            return true
        } catch {
            report(error, title: "Could not organize applications")
            return false
        }
    }

    private func report(_ error: any Error, title: String) {
        guard !isShutdown else { return }
        logger.error("Operation failed: \(title, privacy: .private): \(error.localizedDescription, privacy: .private)")
        // Present after the current AppKit drag/drop callback returns.
        Task { @MainActor [weak self] in
            guard let self, !isShutdown else { return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func render(_ original: DockConfiguration, restoring: Bool = false) {
        guard !positioningDrags.contains(original.id), let controller = controllers[original.id] else { return }
        // visibleFrame is sampled afresh; menu-bar and Dock insets can change independently of scale.
        let displays = DisplayService.current
        guard let result = DockPositioning.resolve(original, displays: displays, restoring: restoring) else { return }
        var configuration = original
        DockPositioning.recordLayout(result, in: &configuration)
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }), configurations[index] != configuration {
            configurations[index] = configuration
        }
        let id = configuration.id
        (controller.window as? DockPanel)?.positionLocked = globalPositionLocked || configuration.behavior.positionLocked
        let actions = DockActions(
            positionLockTitle: globalPositionLocked ? "Position Locked Globally…" : (configuration.behavior.positionLocked ? "Unlock Position" : "Lock Position"),
            togglePositionLock: { [weak self] in
                guard let self else { return }
                if globalPositionLocked { showSettings() }
                else { setPositionLocked(!configuration.behavior.positionLocked, in: id) }
            },
            canOpenFiles: { [weak self] item, urls in self?.applications.canOpen(urls, with: item) ?? false },
            openFiles: { [weak self] item, urls in self?.openDocuments(urls, with: item) ?? false },
            openGroup: { [weak self] item, anchor in self?.showGroup(item, in: id, anchor: anchor) },
            stackDrop: { [weak self] item, drag, urls, copy in
                self?.receiveDrop(drag, urls: urls, to: id, at: Int.max, copy: copy, stackID: item.id) ?? false
            },
            settings: { [weak self] in self?.showSettings() },
            reveal: { [weak self] item in
                guard let self else { return }
                do { try applications.reveal(item) }
                catch { report(error, title: "Could not reveal \(item.name)") }
            },
            collapse: { [weak self] in self?.setCollapsed(!configuration.behavior.isCollapsed, in: id) },
            drop: { [weak self] drag, urls, index, copy in self?.receiveDrop(drag, urls: urls, to: id, at: index, copy: copy) ?? false },
            quit: { [weak self] item in
                guard let self, !isShutdown else { return }
                do { try applications.quit(item) }
                catch { report(error, title: "Could not quit \(item.name)") }
            },
            windowCommand: { [weak self] item, minimized in self?.changeWindows(item, minimized: minimized) },
            dragBegan: { [weak self] in self?.activeDragSource = $0 },
            dragEnded: { [weak self] in self?.activeDragSource = nil }
        )
        controller.update(configuration: configuration, applications: applications, launch: { [weak self] item in
            self?.launch(item, behavior: configuration.behavior)
        }, actions: actions, accessibility: accessibility, placement: result,
           revealStyle: configuration.appearance.effectiveRevealStyle(global: globalRevealStyle))
        updateRevealPlacements()
        scheduleSave()
    }

    private func updateRevealPlacements() {
        let displays = DisplayService.current
        let requests: [RevealRequest] = configurations.compactMap { dock in
            guard dock.isEnabled, dock.behavior.autoHideEnabled || dock.behavior.collapseEnabled,
                  let result = DockPositioning.resolve(dock, displays: displays, restoring: false) else { return nil }
            return RevealRequest(id: dock.id, frame: result.frame, orientation: dock.orientation, bounds: result.display.visibleFrame)
        }
        guard requests != lastRevealRequests else { return }
        lastRevealRequests = requests
        var frames: [UUID: CGRect] = [:]
        for request in requests {
            frames[request.id] = DockInteractionGeometry.revealFrame(dockFrame: request.frame, orientation: request.orientation,
                visibleFrame: request.bounds, occupied: Array(frames.values))
        }
        for (id, controller) in controllers { controller.interactions.setRevealFrame(frames[id]) }
    }

    private func changeWindows(_ item: ApplicationItem, minimized: Bool) {
        guard !isShutdown else { return }
        if !windowCommands.hasAccess {
            let alert = NSAlert()
            alert.messageText = "Accessibility access for window controls"
            alert.informativeText = "MultiDock needs Accessibility access to minimize or restore this app's windows. macOS controls their animation and destination; windows cannot minimize into a MultiDock icon. After granting access, choose the command again."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Request Accessibility Access…")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { windowCommands.requestAccess() }
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !isShutdown else { return }
            do { try await windowCommands.perform(bundleIdentifier: item.bundleIdentifier, minimized: minimized) }
            catch { report(error, title: "Could not change windows for \(item.name)") }
        }
    }

    @discardableResult
    func openDocuments(_ urls: [URL], with item: DockItem) -> Bool {
        guard !isShutdown, documentTasks.count < 4, applications.canOpen(urls, with: item) else { return false }
        let token = UUID()
        documentTasks[token] = Task { [weak self] in
            guard let self else { return }
            defer { documentTasks[token] = nil }
            do { try await applications.open(urls, with: item) }
            catch { if !isShutdown { report(error, title: "Could not open files with \(item.name)") } }
        }
        return true
    }

    func requestWindowAccess() { windowCommands.requestAccess() }

    private func launch(_ item: ApplicationItem, behavior: DockBehavior = DockBehavior()) {
        guard !isShutdown else { return }
        clickTask?.cancel()
        clickTask = Task { [weak self] in
            guard let self, !isShutdown else { return }
            do {
                if behavior.clickMode == .standard || !applications.activity.isRunning(item.bundleIdentifier) {
                    try await applications.launch(item)
                } else {
                    do {
                        try await windowCommands.activate(bundleIdentifier: item.bundleIdentifier, mode: behavior.clickMode,
                            restoreMinimized: behavior.restoreMinimizedOnClick)
                        applications.activity.setLaunchState(.succeeded, for: item.id)
                    } catch is CancellationError { return }
                    catch WindowCommandError.notRunning { try await applications.launch(item) }
                    catch WindowCommandError.activationFailed { throw WindowCommandError.activationFailed }
                    catch {
                        // Ordinary activation already succeeded; inaccessible/custom windows are an expected fallback.
                        logger.info("Advanced activation fell back to app activation: \(error.localizedDescription, privacy: .public)")
                        applications.activity.setLaunchState(.succeeded, for: item.id)
                    }
                }
            } catch is CancellationError { return }
            catch { if !isShutdown { report(error, title: "Could not open \(item.name)") } }
        }
    }

    private func updatePosition(_ id: UUID, _ position: DockPosition) {
        // Unsolicited AppKit corrections during monitor removal must not overwrite the saved home display.
        guard positioningDrags.contains(id), let index = configurations.firstIndex(where: { $0.id == id }),
              configurations[index].position != position else { return }
        configurations[index].position = position
    }

    private func didClose(_ id: UUID) {
        stacks.dismiss(dockID: id)
        guard let controller = controllers.removeValue(forKey: id) else { return }
        previews.dismiss(for: controller)
        controller.interactions.shutdown()
        controller.onRequestDelete = nil
        controller.onClose = nil
        controller.onMove = nil
        controller.onScreenChange = nil
        controller.onDragStart = nil
        controller.onDragEnd = nil
        controller.window?.delegate = nil
        (controller.window as? DockPanel)?.cancelPositionDrag()
        positioningDrags.remove(id)
        configurations.removeAll { $0.id == id }
        updateRevealPlacements()
        scheduleSave()
    }

    @objc private func displaysChanged(_ notification: Notification) {
        stacks.dismiss()
        previews.dismiss()
        refreshDisplays(force: true)
    }

    @objc private func desktopChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.activeSpaceDidChangeNotification { stacks.dismiss() }
        previews.dismiss()
        if notification.name == NSWorkspace.didActivateApplicationNotification,
           let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            windowCommands.noteActivatedApplication(app.processIdentifier)
        }
        switch notification.name {
        case NSWorkspace.willSleepNotification: systemSleeping = true
        case NSWorkspace.screensDidSleepNotification: screensSleeping = true
        case NSWorkspace.didWakeNotification: systemSleeping = false
        case NSWorkspace.screensDidWakeNotification: screensSleeping = false
        default: return // AppKit owns Spaces, full-screen, and Stage Manager membership.
        }
        if !desktopSuspended { refreshDisplays(force: true) }
        for dock in configurations { applyVisibility(dock.id) }
    }

    private func refreshDisplays(force: Bool = false) {
        let current = DisplayService.current
        guard force || current != availableDisplays else { return }
        availableDisplays = current
        for configuration in Array(configurations) { render(configuration, restoring: true) }
    }

    private func scheduleSave() {
        guard let store, savingEnabled, !isLoading,
              configurations != lastScheduledSnapshot || globalRevealStyle != lastScheduledRevealStyle || globalPositionLocked != lastScheduledPositionLocked else { return }
        lastScheduledSnapshot = configurations
        lastScheduledRevealStyle = globalRevealStyle
        lastScheduledPositionLocked = globalPositionLocked
        saveTask?.cancel()
        revision += 1
        let snapshot = configurations
        let revealStyle = globalRevealStyle
        let locked = globalPositionLocked
        let currentRevision = revision
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await store.save(snapshot, revision: currentRevision, globalRevealStyle: revealStyle, globalPositionLocked: locked)
                self?.reportedSaveFailure = false
            } catch is CancellationError { return }
            catch {
                guard let self, !reportedSaveFailure else { return }
                lastScheduledSnapshot = nil
                reportedSaveFailure = true
                report(error, title: "Could not save docks. Changes are still available in this session.")
            }
        }
    }

    func flush() async throws {
        saveTask?.cancel()
        saveTask = nil
        guard let store, savingEnabled, !isLoading, !isShutdown else { return }
        while true {
            saveTask?.cancel()
            revision += 1
            let snapshot = configurations
            let revealStyle = globalRevealStyle
        let locked = globalPositionLocked
            try await store.save(snapshot, revision: revision, globalRevealStyle: revealStyle, globalPositionLocked: locked)
            if configurations == snapshot && globalRevealStyle == revealStyle && globalPositionLocked == locked { return }
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        documentTasks.values.forEach { $0.cancel() }
        documentTasks.removeAll()
        clickTask?.cancel()
        clickTask = nil
        stacks.dismiss()
        previews.shutdown()
        saveTask?.cancel()
        saveTask = nil
        positioningDrags.removeAll()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let ownedControllers = Array(controllers.values)
        controllers.removeAll()
        ownedControllers.forEach { $0.dispose() }
        configurations.removeAll()
        activeDragSource = nil
        lastRevealRequests.removeAll()
        applications.activity.shutdown()
        applications.trimIconCache()
    }
}
