import AppKit
import SwiftUI

/// One popover across all docks, with explicit capture cancellation and a balanced auto-hide hold.
@MainActor
final class WindowPreviewController: NSObject, NSPopoverDelegate {
    private let provider: any WindowPreviewProviding
    let model = WindowPreviewModel()
    private(set) var popover: NSPopover?
    private weak var owner: DockWindowController?
    private weak var pendingOwner: DockWindowController?
    private weak var anchor: NSView?
    private var hoveredID: UUID?
    private var generation = UUID()
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var stopped = false
    private var popoverHovered = false
    var hasPendingRequest: Bool { hoverTask != nil || captureTask != nil }
    var isOpen: Bool { popover?.isShown == true }

    init(provider: any WindowPreviewProviding = WindowPreviewService()) { self.provider = provider }

    func hover(_ item: ApplicationItem, anchor: NSView, entered: Bool, owner: DockWindowController,
               orientation: DockOrientation, launch: @escaping @MainActor () -> Void, immediate: Bool = false) {
        guard !stopped else { return }
        if !entered {
            if hoveredID == item.id {
                hoveredID = nil
                hoverTask?.cancel(); hoverTask = nil
                scheduleClose()
            }
            return
        }
        // Permission education is explicit, so normal hover never opens an intrusive access banner.
        if !provider.screenAccess && !immediate { return }
        closeTask?.cancel(); closeTask = nil
        if self.anchor === anchor && isOpen { hoveredID = item.id; return }
        dismiss()
        hoveredID = item.id
        pendingOwner = owner
        let token = generation
        hoverTask = Task { @MainActor [weak self, weak anchor, weak owner] in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
            guard let self, generation == token, hoveredID == item.id, let anchor, let owner,
                  anchor.window?.isVisible == true, NSEvent.pressedMouseButtons == 0 else { return }
            hoverTask = nil
            show(item, anchor: anchor, owner: owner, orientation: orientation, launch: launch)
        }
    }

    private func show(_ item: ApplicationItem, anchor: NSView, owner: DockWindowController,
                      orientation: DockOrientation, launch: @escaping @MainActor () -> Void) {
        self.owner = owner
        self.anchor = anchor
        owner.interactions.beginInteraction()
        model.title = item.name
        model.rows = []
        model.message = provider.screenAccess ? "Loading windows…" : WindowPreviewError.screenAccess.localizedDescription
        model.needsScreenAccess = !provider.screenAccess
        model.needsAccessibility = false
        model.selecting = false
        model.openApplication = { [weak self] in self?.dismiss(); launch() }
        model.close = { [weak self] in self?.dismiss() }
        model.requestScreen = { [weak self] in
            guard let self else { return }
            // This action follows the visible privacy explanation and an explicit button click.
            provider.requestScreenAccess()
            guard isOpen else { return }
            if provider.screenAccess { load(item) }
            else { model.message = "Access has not been granted. Allow MultiDock in System Settings > Privacy & Security > Screen Recording, then reopen MultiDock if macOS requests it."; resize() }
        }
        model.requestAccessibility = { [weak self] in
            guard let self else { return }
            provider.requestAccessibilityAccess()
            guard isOpen else { return }
            model.message = "Allow MultiDock in System Settings > Privacy & Security > Accessibility, then select the window again."
            resize()
        }
        model.select = { [weak self] window in self?.select(window, item: item) }
        let content = NSViewController()
        let host = PreviewHostingView(rootView: WindowPreviewView(model: model))
        host.hoverChanged = { [weak self] entered in
            guard let self else { return }
            popoverHovered = entered
            if entered { closeTask?.cancel(); closeTask = nil }
            else if hoveredID == nil { scheduleClose() }
        }
        content.view = host
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !DockAccessibility.current.reduceMotion
        popover.contentViewController = content
        popover.delegate = self
        popover.contentSize = host.fittingSize
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: orientation == .horizontal ? .maxY : .maxX)
        if !popover.isShown { dismiss(); return }
        if provider.screenAccess { load(item) }
    }
    private func load(_ item: ApplicationItem) {
        guard captureTask == nil, isOpen, !stopped else { return }
        model.needsScreenAccess = false
        model.message = "Loading windows…"
        let token = generation
        let provider = self.provider
        captureTask = Task { @MainActor [weak self] in
            do {
                let rows = try await provider.load(bundleIdentifier: item.bundleIdentifier)
                try Task.checkCancellation()
                guard let self, generation == token, isOpen else { return }
                model.rows = rows
                model.message = rows.isEmpty ? "No available windows. Hidden, minimized, protected, or other-Space windows may not be exposed by macOS." : "Select a window. Up to 8 thumbnails and 32 windows are shown."
                captureTask = nil
                resize()
            } catch {
                guard !Task.isCancelled, let self, generation == token, isOpen else { return }
                model.message = error.localizedDescription
                model.needsScreenAccess = !provider.screenAccess
                captureTask = nil
                resize()
            }
        }
    }
    private func select(_ window: PreviewWindowDescriptor, item: ApplicationItem) {
        guard !model.selecting else { return }
        closeTask?.cancel(); closeTask = nil
        guard provider.accessibilityAccess else {
            model.needsAccessibility = true
            model.message = WindowPreviewError.accessibilityAccess.localizedDescription
            resize()
            return
        }
        model.needsAccessibility = false
        model.selecting = true
        resize()
        let token = generation
        let provider = self.provider
        selectionTask = Task { @MainActor [weak self] in
            do {
                try await provider.activate(window, bundleIdentifier: item.bundleIdentifier)
                try Task.checkCancellation()
                guard let self, generation == token else { return }
                dismiss()
            } catch {
                guard !Task.isCancelled, let self, generation == token, isOpen else { return }
                model.selecting = false
                model.message = error.localizedDescription
                selectionTask = nil
                resize()
                if hoveredID == nil { scheduleClose() }
            }
        }
    }
    private func resize() {
        guard let popover, let host = popover.contentViewController?.view as? PreviewHostingView else { return }
        // State changes are infrequent; size the native popover only when its content changes.
        host.rootView = WindowPreviewView(model: model)
        host.layoutSubtreeIfNeeded()
        popover.contentSize = host.fittingSize
    }
    private func scheduleClose() {
        guard !popoverHovered, !model.selecting else { return }
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            self?.dismiss()
        }
    }
    func dismiss(for controller: DockWindowController? = nil) {
        if let controller, owner !== controller && pendingOwner !== controller { return }
        generation = UUID()
        hoveredID = nil
        popoverHovered = false
        hoverTask?.cancel(); hoverTask = nil
        closeTask?.cancel(); closeTask = nil
        captureTask?.cancel(); captureTask = nil
        selectionTask?.cancel(); selectionTask = nil
        let old = popover
        popover = nil
        old?.delegate = nil
        (old?.contentViewController?.view as? PreviewHostingView)?.hoverChanged = { _ in }
        old?.close()
        old?.contentViewController = nil
        model.clear()
        owner?.interactions.endInteraction()
        owner = nil
        pendingOwner = nil
        anchor = nil
    }
    func popoverDidClose(_ notification: Notification) { dismiss() }
    func shutdown() { dismiss(); stopped = true }
}

/// App/folder stacks use a transient native popover; no capture or filesystem watcher.
@MainActor
final class StackPopoverController: NSObject, NSPopoverDelegate {
    var isShown: Bool { popover.isShown }
    private let popover = NSPopover()
    private weak var owner: DockWindowController?
    private var dockID: UUID?
    func show(item: DockItem, dockID: UUID, anchor: NSView, owner: DockWindowController, manager: DockManager) {
        guard anchor.window?.isVisible == true else { return }
        dismiss()
        self.owner = owner; self.dockID = dockID
        owner.interactions.beginInteraction()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = !DockAccessibility.current.reduceMotion
        let maximum = max(120, (anchor.window?.screen?.visibleFrame.height ?? 600) - 80)
        popover.contentSize = NSSize(width: 360, height: min(maximum, CGFloat(max(2, min(item.children.count, 8))) * 48 + 120))
        popover.contentViewController = NSHostingController(rootView: StackPopoverContent(manager: manager, dockID: dockID, fallback: item))
        let orientation = manager.configurations.first { $0.id == dockID }?.orientation ?? .horizontal
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: orientation == .horizontal ? .maxY : .maxX)
    }
    func dismiss(dockID: UUID? = nil) {
        if let dockID, self.dockID != dockID { return }
        popover.animates = false
        popover.close()
        finish()
    }
    private func finish() {
        // A popover can intercept the parent's exit event. Reconcile once on close
        // so a stale hover flag cannot keep an auto-hide dock visible indefinitely.
        if let owner, owner.window?.frame.contains(NSEvent.mouseLocation) == false {
            owner.interactions.pointerChanged(nil)
        }
        owner?.interactions.endInteraction()
        owner = nil; dockID = nil
        popover.contentViewController = nil
    }
    func popoverDidClose(_ notification: Notification) { finish() }
}
