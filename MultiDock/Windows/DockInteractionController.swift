import AppKit
import QuartzCore

/// Owns only transient interaction state. Saved positions always describe the full dock.
@MainActor
final class DockInteractionController {
    private weak var owner: DockWindowController?
    let nameLabel = DockNameLabelController()
    private weak var namedButton: ApplicationIconButton?
    private var lastPointer: CGPoint?
    private var lastEventTimestamp: TimeInterval = 0
    private var behavior = DockBehavior()
    private(set) var revealStyle = DockRevealStyle()
    private var accessibility = DockAccessibility()
    private var hideTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var generation = UUID()
    private var holds = 0
    private var launchInProgress = false
    private var pointerInside = false
    private var controlsVisible: Bool?
    private var hoveringReveal = false
    var hasPendingHide: Bool { hideTask != nil }
    var isTransitioning: Bool { transitionTask != nil }
    private var heldOpen = false
    private var active = false
    private var stopped = false
    private(set) var isAutoHidden = false
    private(set) var revealFrame: CGRect?
    private(set) var revealPanel: NSPanel?
    var expand: (() -> Void)?

    init(owner: DockWindowController) { self.owner = owner }

    func configure(behavior: DockBehavior, accessibility: DockAccessibility, geometryChanged: Bool) {
        let previous = self.behavior
        self.behavior = behavior.normalized
        let motionChanged = self.accessibility.reduceMotion != accessibility.reduceMotion
        self.accessibility = accessibility
        refreshRevealPresentation()
        updateManagementControls(force: true)
        if !behavior.autoHideEnabled || geometryChanged { isAutoHidden = false }
        if geometryChanged || (previous.isCollapsed && !behavior.isCollapsed) {
            pointerInside = (owner?.window?.frame.contains(NSEvent.mouseLocation) ?? false) || hoveringReveal
            heldOpen = false
        }
        if previous != self.behavior || geometryChanged || motionChanged {
            cancelHide()
            applyPresentation(animated: !geometryChanged && !motionChanged)
            updateMagnification(at: nil)
            scheduleHide()
        }
    }

    func setRevealFrame(_ frame: CGRect?) {
        guard !stopped, revealFrame != frame else { return }
        revealFrame = frame
        if let frame { makeRevealPanel(); revealPanel?.setFrame(frame, display: true) }
        else { isAutoHidden = false }
        applyPresentation(animated: false)
        scheduleHide()
    }

    private func makeRevealPanel() {
        guard revealPanel == nil else { return }
        let panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        let button = DockRevealButton()
        button.reveal = { [weak self] clicked in
            guard let self else { return }
            hoveringReveal = !clicked || (revealFrame?.contains(NSEvent.mouseLocation) ?? false)
            if behavior.isCollapsed {
                if clicked { expand?() }
            } else { reveal(holdOpen: false) }
        }
        button.exited = { [weak self] in
            guard let self else { return }
            hoveringReveal = false
            pointerInside = owner?.window?.frame.contains(NSEvent.mouseLocation) ?? false
            if !isAutoHidden && !behavior.isCollapsed { revealPanel?.orderOut(nil) }
            if !pointerInside { scheduleHide(minimumDelay: 0.8) }
        }
        panel.contentView = button
        revealPanel = panel
        refreshRevealPresentation()
    }

    func setRevealStyle(_ style: DockRevealStyle) {
        revealStyle = style.normalized
        refreshRevealPresentation()
    }

    private func refreshRevealPresentation() {
        guard let window = owner?.window, let panel = revealPanel,
              let button = panel.contentView as? DockRevealButton else { return }
        panel.title = "Reveal \(window.title)"
        panel.appearance = window.appearance
        button.toolTip = behavior.isCollapsed ? "Click to expand \(window.title)" : "Hover or click to reveal \(window.title)"
        button.setAccessibilityLabel(button.toolTip)
        button.increaseContrast = accessibility.increaseContrast
        button.reduceTransparency = accessibility.reduceTransparency
        button.style = revealStyle
        button.refreshColors()
    }

    func setActive(_ value: Bool) {
        guard !stopped, active != value else { return }
        active = value
        isAutoHidden = false
        cancelHide()
        if !value {
            clearHover()
            lastPointer = nil
            hoveringReveal = false
            cancelTransition()
            owner?.window?.orderOut(nil)
            revealPanel?.orderOut(nil)
            updateMagnification(at: nil)
            updateManagementControls()
        } else {
            pointerInside = owner?.window?.frame.contains(NSEvent.mouseLocation) ?? false
            applyPresentation(animated: false)
            scheduleHide()
        }
    }

    func reveal(holdOpen: Bool = true) {
        guard active, !stopped else { return }
        isAutoHidden = false
        pointerInside = (owner?.window?.frame.contains(NSEvent.mouseLocation) ?? false) || hoveringReveal
        heldOpen = holdOpen
        cancelHide()
        applyPresentation(animated: true)
        if !holdOpen { scheduleHide(minimumDelay: 0.8) }
    }

    func pointerEvent(_ event: NSEvent) {
        guard event.timestamp >= lastEventTimestamp,
              let window = owner?.window, event.windowNumber == window.windowNumber,
              let host = window.contentView else { return }
        lastEventTimestamp = event.timestamp
        if event.type == .scrollWheel { lastPointer = nil }
        let point = event.locationInWindow
        pointerChanged(host.bounds.contains(host.convert(point, from: nil)) ? point : nil)
    }

    func pointerChanged(_ point: CGPoint?) {
        guard active, !stopped else { return }
        if let point, point == lastPointer, pointerInside {
            // Relayout may finish under a stationary pointer. Refresh selection from stable
            // target geometry, without restarting the magnification animation.
            if holds == 0 { reconcileHover(at: point) }
            return
        }
        lastPointer = point
        if let point {
            pointerInside = true
            cancelHide()
            updateMagnification(at: point)
        } else {
            pointerInside = false
            heldOpen = false
            clearHover()
            updateMagnification(at: nil)
            scheduleHide()
        }
        updateManagementControls()
    }

    func beginInteraction() { holds += 1; cancelHide(); nameLabel.hide(); updateManagementControls() }
    func endInteraction() {
        holds = max(0, holds - 1)
        if holds == 0 { updateMagnification(at: lastPointer) }
        scheduleHide()
        updateManagementControls()
    }
    private func clearHover() {
        namedButton = nil
        nameLabel.hide()
        (owner?.window?.contentView as? DockDropHostingView)?.applicationButtons.forEach { $0.setDockHovered(false) }
    }
    private func showName(for button: ApplicationIconButton) {
        guard active, !stopped, holds == 0, !isAutoHidden, !behavior.isCollapsed,
              let window = owner?.window, button.window === window,
              let host = window.contentView as? DockDropHostingView else { nameLabel.hide(); return }
        nameLabel.show(button.applicationName, anchor: button, orientation: host.configuration.orientation,
                       windowRect: host.iconStrip?.targetWindowRect(for: button))
    }
    private func updateManagementControls(force: Bool = false) {
        let visible = active && !stopped && (pointerInside || holds > 0)
        guard force || controlsVisible != visible else { return }
        controlsVisible = visible
        (owner?.window?.contentView as? DockDropHostingView)?.setManagementVisible(visible)
    }
    func setLaunchInProgress(_ value: Bool) {
        guard launchInProgress != value else { return }
        launchInProgress = value
        if value { cancelHide() } else { scheduleHide() }
    }
    private func cancelHide() { hideTask?.cancel(); hideTask = nil }
    private var mayHide: Bool {
        active && !stopped && behavior.autoHideEnabled && !behavior.isCollapsed && revealFrame != nil
            && (owner?.window?.contentView as? DockDropHostingView)?.configuration.applications.isEmpty == false
            && !pointerInside && !hoveringReveal && !heldOpen && holds == 0 && !launchInProgress
    }
    private func scheduleHide(minimumDelay: Double = 0) {
        cancelHide()
        guard mayHide, !isAutoHidden else { return }
        let delay = max(behavior.autoHideDelay, minimumDelay)
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, mayHide else { return }
            hideTask = nil
            isAutoHidden = true
            applyPresentation(animated: true)
        }
    }

    private func applyPresentation(animated: Bool) {
        guard active, !stopped, let window = owner?.window else { return }
        let hidden = revealFrame != nil && (behavior.isCollapsed || isAutoHidden)
        if hidden {
            clearHover()
            lastPointer = nil
            makeRevealPanel()
            refreshRevealPresentation()
            revealPanel?.orderFrontRegardless()
        } else if hoveringReveal, let frame = revealFrame, !window.frame.contains(frame) {
            // A collision-displaced tab stays under the pointer until it exits. This avoids reveal/hide loops.
            revealPanel?.orderFrontRegardless()
        } else {
            // AppKit need not send mouseExited when a tab window is ordered out.
            // The full host now owns pointer tracking; retaining tab hover would block auto-hide.
            hoveringReveal = false
            pointerInside = window.frame.contains(NSEvent.mouseLocation)
            revealPanel?.orderOut(nil)
        }
        updateManagementControls(force: true)
        transitionMain(shown: !hidden, animated: animated)
    }

    private func cancelTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        generation = UUID()
        if let layer = owner?.window?.contentView?.layer {
            layer.removeAnimation(forKey: "dockVisibility")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.opacity = 1
            CATransaction.commit()
        }
    }

    private func transitionMain(shown: Bool, animated: Bool) {
        guard let window = owner?.window, let layer = window.contentView?.layer else { return }
        let current = window.isVisible ? (layer.presentation()?.opacity ?? layer.opacity) : 0
        cancelTransition()
        let token = generation
        let target: Float = shown ? 1 : 0
        if shown { window.orderFrontRegardless() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        let duration = animated && !accessibility.reduceMotion ? behavior.visibilityDuration : 0
        guard duration > 0, window.isVisible, abs(current - target) > 0.001 else {
            if !shown { window.orderOut(nil) }
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "dockVisibility")
        transitionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, generation == token else { return }
            layer.removeAnimation(forKey: "dockVisibility")
            if !shown { window.orderOut(nil) }
            transitionTask = nil
        }
    }

    func updateMagnification(at point: CGPoint?) {
        guard let host = owner?.window?.contentView as? DockDropHostingView else { return }
        // Freeze moving hit targets during clicks, menus and drag sessions.
        guard holds == 0 else { nameLabel.hide(); return }
        if point == nil { lastPointer = nil }
        host.iconStrip?.updatePointer(point)
        reconcileHover(at: point)
    }
    private func reconcileHover(at point: CGPoint?) {
        guard let host = owner?.window?.contentView as? DockDropHostingView else { return }
        let hovered = point.flatMap { host.iconStrip?.targetButton(at: $0) }
        for button in host.applicationButtons { button.setDockHovered(button === hovered) }
        namedButton = hovered
        if let hovered { showName(for: hovered) }
        else { nameLabel.hide() }
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        clearHover()
        nameLabel.shutdown()
        cancelHide()
        cancelTransition()
        (revealPanel?.contentView as? DockRevealButton)?.reveal = nil
        (revealPanel?.contentView as? DockRevealButton)?.exited = nil
        revealPanel?.close()
        revealPanel = nil
        expand = nil
    }
}

@MainActor
final class DockRevealButton: DockHoverButton {
    var reveal: ((Bool) -> Void)?
    var exited: (() -> Void)?
    var style = DockRevealStyle()
    var reduceTransparency = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        image = nil
        drawsIcon = false
        iconDrawSize = 12
        isBordered = false
        target = self
        action = #selector(clicked)
        registerForDraggedTypes([.fileURL, ApplicationIconButton.pasteboardType])
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = style.color.revealTabColor
            let color = isHovered ? base.blended(withFraction: 0.28, of: .controlAccentColor) ?? base : base
            layer?.backgroundColor = color.withAlphaComponent(style.effectiveOpacity(
                reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(increaseContrast ? 0.8 : (isHovered ? 0.5 : 0.25)).cgColor
            layer?.borderWidth = increaseContrast ? 2 : 1
        }
        needsDisplay = true
    }
    override func setHovered(_ value: Bool) { super.setHovered(value); refreshColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); reveal?(false) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); exited?() }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        reveal?(false)
        // Reveal only; the full dock validates and accepts the actual drop. Never move a Finder file.
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { exited?() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    @objc private func clicked() { reveal?(true) }
}
