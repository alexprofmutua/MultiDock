import AppKit
import SwiftUI

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var positionLocked = false {
        didSet {
            isMovable = !positionLocked
            if positionLocked && isPositionDragging {
                cancelPositionDrag()
                onDockDragFinished?()
            }
        }
    }
    var onDockDragStarted: (() -> Void)?
    var onDockDragFinished: (() -> Void)?
    private var completionTask: Task<Void, Never>?
    private(set) var isPositionDragging = false

    func startPositionDrag(with event: NSEvent) {
        guard !positionLocked else { return }
        completionTask?.cancel()
        isPositionDragging = true
        onDockDragStarted?()
        performDrag(with: event)
        // performDrag returns immediately; mouse-up delivery is not guaranteed by AppKit.
        // Check button state only during this native drag, never while idle. No global monitor or permission.
        completionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    isPositionDragging = false
                    completionTask = nil
                    onDockDragFinished?()
                    return
                }
            }
        }
    }

    func cancelPositionDrag() {
        completionTask?.cancel()
        completionTask = nil
        isPositionDragging = false
    }
}

@MainActor
final class DockWindowController: NSWindowController, NSWindowDelegate {
    let dockID: UUID
    var onRequestDelete: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onMove: ((UUID, DockPosition) -> Void)?
    var onScreenChange: ((UUID) -> Void)?
    var onDragStart: ((UUID) -> Void)?
    var onDragEnd: ((UUID) -> Void)?
    weak var previews: WindowPreviewController?
    private var isUpdating = false
    private var windowPreviewsEnabled = false
    private(set) lazy var interactions = DockInteractionController(owner: self)

    init(configuration: DockConfiguration) {
        dockID = configuration.id
        let panel = DockPanel(
            contentRect: NSRect(origin: .zero, size: DockLayout.size(for: configuration)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        super.init(window: panel)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        panel.onDockDragStarted = { [weak self] in
            guard let self else { return }
            previews?.dismiss(for: self)
            interactions.beginInteraction()
            onDragStart?(dockID)
        }
        panel.onDockDragFinished = { [weak self] in
            guard let self else { return }
            onDragEnd?(dockID)
            interactions.endInteraction()
        }
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
    }

    required init?(coder: NSCoder) { fatalError("Use init(configuration:)") }

    func update(configuration: DockConfiguration, applications: ApplicationService,
                launch: @escaping @MainActor (ApplicationItem) -> Void, actions: DockActions = DockActions(), accessibility: DockAccessibility = .current, placement: DockPlacementResult? = nil, revealStyle: DockRevealStyle? = nil) {
        guard let window else { return }
        previews?.dismiss(for: self)
        windowPreviewsEnabled = configuration.behavior.windowPreviewsEnabled
        isUpdating = true
        defer { isUpdating = false }
        window.title = configuration.name
        switch configuration.appearance.colorMode {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }
        guard let resolved = placement ?? DockPositioning.resolve(configuration, displays: DisplayService.current, restoring: false) else { return }
        let maximumLength = resolved.maximumLength
        let close: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if let onRequestDelete { onRequestDelete(dockID) } else { self.close() }
        }
        var hostedActions = actions
        hostedActions.hoverPointer = { [weak self] event in
            self?.interactions.pointerEvent(event)
        }
        hostedActions.preview = { [weak self] item, anchor, entered, immediate in
            guard let self, windowPreviewsEnabled else { return }
            previews?.hover(item, anchor: anchor, entered: entered, owner: self, orientation: configuration.orientation,
                            launch: { launch(item) }, immediate: immediate)
        }
        hostedActions.interactionBegan = { [weak self] in
            guard let self else { return }
            previews?.dismiss(for: self)
            interactions.beginInteraction()
        }
        hostedActions.interactionEnded = { [weak self] in self?.interactions.endInteraction() }
        hostedActions.settings = { [weak self] in
            if let self { previews?.dismiss(for: self) }
            self?.interactions.beginInteraction()
            defer { self?.interactions.endInteraction() }
            actions.settings()
        }
        hostedActions.dragBegan = { [weak self] view in
            self?.interactions.beginInteraction()
            actions.dragBegan(view)
        }
        hostedActions.dragEnded = { [weak self] in
            actions.dragEnded()
            self?.interactions.endInteraction()
        }
        interactions.expand = actions.collapse
        let view = DockView(configuration: configuration, applications: applications, launch: launch,
                            close: close, actions: hostedActions, maximumLength: maximumLength, accessibility: accessibility)
        if let hosting = window.contentView as? DockDropHostingView {
            hosting.configuration = configuration
            hosting.actions = hostedActions
            hosting.rootView = view
        } else {
            window.contentView = DockDropHostingView(rootView: view, configuration: configuration, actions: hostedActions, close: close)
        }
        let geometryChanged = window.frame != resolved.frame
        if geometryChanged {
            window.setFrame(resolved.frame, display: true, animate: false)
        }
        (window.contentView as? DockDropHostingView)?.hoverPointer = { [weak self] event in
            self?.interactions.pointerEvent(event)
        }
        (window.contentView as? DockDropHostingView)?.pointerChanged = { [weak self] point in
            self?.interactions.pointerChanged(point)
        }
        interactions.setRevealStyle(revealStyle ?? configuration.appearance.effectiveRevealStyle(global: DockRevealStyle()))
        interactions.configure(behavior: configuration.behavior, accessibility: accessibility, geometryChanged: geometryChanged)
        refreshActivity(using: applications)
        window.invalidateShadow()
    }

    func show() { interactions.setActive(true) }
    func setVisible(_ visible: Bool) {
        if !visible { previews?.dismiss(for: self) }
        interactions.setActive(visible)
    }
    func refreshActivity(using applications: ApplicationService) {
        guard let host = window?.contentView as? DockDropHostingView else { return }
        for button in host.applicationButtons {
            guard let id = button.itemID, let item = host.configuration.applications.first(where: { $0.id == id }) else { continue }
            button.applyActivity(running: applications.activity.isRunning(item.bundleIdentifier), state: applications.activity.launchState(id))
        }
        interactions.setLaunchInProgress(host.configuration.applications.contains { applications.activity.launchState($0.id) == .launching })
    }

    func windowDidMove(_ notification: Notification) {
        guard !isUpdating, let origin = window?.frame.origin else { return }
        previews?.dismiss(for: self)
        onMove?(dockID, DockPosition(x: origin.x, y: origin.y))
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard !isUpdating else { return }
        onScreenChange?(dockID)
    }

    func windowWillClose(_ notification: Notification) { onClose?(dockID) }

    /// Shutdown explicitly breaks callbacks before closing owned windows.
    func dispose() {
        previews?.dismiss(for: self)
        interactions.shutdown()
        (window?.contentView as? DockDropHostingView)?.pointerChanged = nil
        (window?.contentView as? DockDropHostingView)?.hoverPointer = nil
        onRequestDelete = nil
        onClose = nil
        onMove = nil
        onScreenChange = nil
        onDragStart = nil
        onDragEnd = nil
        if let panel = window as? DockPanel {
            panel.onDockDragStarted = nil
            panel.onDockDragFinished = nil
            panel.cancelPositionDrag()
        }
        window?.delegate = nil
        close()
        window?.contentView = nil
    }
}
