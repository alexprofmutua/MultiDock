import AppKit
import SwiftUI

@MainActor
struct DockActions {
    var positionLockTitle = "Lock Position"
    var togglePositionLock: @MainActor () -> Void = {}
    var hoverPointer: @MainActor (NSEvent) -> Void = { _ in }
    var canOpenFiles: @MainActor (DockItem, [URL]) -> Bool = { _, _ in false }
    var openFiles: @MainActor (DockItem, [URL]) -> Bool = { _, _ in false }
    var sourceStackID: UUID? = nil
    var openGroup: @MainActor (DockItem, NSView) -> Void = { _, _ in }
    var stackDrop: @MainActor (DockItem, DockItemDrag?, [URL], Bool) -> Bool = { _, _, _, _ in false }
    var settings: @MainActor () -> Void = {}
    var reveal: @MainActor (ApplicationItem) -> Void = { _ in }
    var collapse: @MainActor () -> Void = {}
    var drop: @MainActor (DockItemDrag?, [URL], Int, Bool) -> Bool = { _, _, _, _ in false }
    var quit: @MainActor (ApplicationItem) -> Void = { _ in }
    var windowCommand: @MainActor (ApplicationItem, Bool) -> Void = { _, _ in }
    var preview: @MainActor (ApplicationItem, NSView, Bool, Bool) -> Void = { _, _, _, _ in }
    var interactionBegan: @MainActor () -> Void = {}
    var interactionEnded: @MainActor () -> Void = {}
    var dragBegan: @MainActor (NSView) -> Void = { _ in }
    var dragEnded: @MainActor () -> Void = {}
}

@MainActor
func dockOptionsMenu(actions: DockActions) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(DockMenuItem(actions.positionLockTitle, action: actions.togglePositionLock))
    menu.addItem(DockMenuItem("Settings…", action: actions.settings))
    return menu
}

@MainActor
final class DockMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void
    init(_ title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Use init(_:action:)") }
    @objc private func invoke() { handler() }
}

struct ApplicationIcon: NSViewRepresentable {
    let item: ApplicationItem
    let configuration: DockConfiguration
    let image: NSImage
    let actions: DockActions
    let launch: @MainActor () -> Void
    let close: @MainActor () -> Void
    var accessibility = DockAccessibility()
    var running = false
    var launchState = DockLaunchState.idle

    func makeNSView(context: Context) -> ApplicationIconButton { ApplicationIconButton() }
    func updateNSView(_ button: ApplicationIconButton, context: Context) { configure(button) }

    func configure(_ button: ApplicationIconButton) {
        button.iconDrawSize = DockMetrics(configuration.appearance).iconSize
        button.animatesDragCancellation = accessibility.animatesDragCancellation
        button.increaseContrast = accessibility.increaseContrast
        button.itemID = item.id
        button.behavior = configuration.behavior
        button.iconTheme = configuration.appearance.iconTheme
        button.iconTint = configuration.appearance.iconTint
        button.reduceMotion = accessibility.reduceMotion
        button.orientation = configuration.orientation
        button.hoverPointer = actions.hoverPointer
        button.previewHover = { [weak button] entered in
            guard let button, configuration.behavior.windowPreviewsEnabled, button.isApplicationRunning else { return }
            actions.preview(item, button, entered, false)
        }
        button.interactionBegan = actions.interactionBegan
        button.interactionEnded = actions.interactionEnded
        button.image = nil // The native button cell must not also draw the layer-backed icon.
        button.applicationImage = image
        button.applicationName = item.name
        button.toolTip = nil
        button.setAccessibilityLabel("Open \(item.name)")
        if item.kind == .application { button.launch = launch }
        else { button.launch = { [weak button] in if let button { actions.openGroup(item, button) } } }
        button.dropIntoStack = { drag, urls, copy in actions.stackDrop(item, drag, urls, copy) }
        button.isStackTarget = item.kind == .stack || actions.sourceStackID != nil
        button.entryKind = item.kind
        button.canOpenFiles = { urls in actions.canOpenFiles(item, urls) }
        button.openFiles = { urls in actions.openFiles(item, urls) }
        button.registerForDraggedTypes([.fileURL, ApplicationIconButton.pasteboardType])
        button.drag = DockItemDrag(dockID: configuration.id, itemID: item.id, stackID: actions.sourceStackID)
        button.dragBegan = actions.dragBegan
        button.dragEnded = actions.dragEnded
        button.needsLayout = true
        button.applyActivity(running: running, state: launchState)
        button.contextMenu = { [weak button] in
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(DockMenuItem("Open \(item.name)") { [weak button] in button?.launch() })
            if item.kind != .application {
                menu.addItem(DockMenuItem("Settings…", action: actions.settings))
                return menu
            }
            if configuration.behavior.windowPreviewsEnabled {
                let previews = DockMenuItem("Show Window Previews") { [weak button] in
                    guard let button, button.isApplicationRunning else { return }
                    actions.preview(item, button, true, true)
                }
                previews.isEnabled = button?.isApplicationRunning == true
                menu.addItem(previews)
            }
            let minimize = DockMenuItem("Minimize Application Windows…") { actions.windowCommand(item, true) }
            let restore = DockMenuItem("Restore Application Windows…") { actions.windowCommand(item, false) }
            minimize.isEnabled = button?.isApplicationRunning == true
            restore.isEnabled = minimize.isEnabled
            menu.addItem(minimize)
            menu.addItem(restore)
            let quit = DockMenuItem("Quit \(item.name)") { actions.quit(item) }
            quit.isEnabled = button?.isApplicationRunning == true
            menu.addItem(quit)
            menu.addItem(DockMenuItem("Reveal in Finder") { actions.reveal(item) })
            menu.addItem(.separator())
            menu.addItem(DockMenuItem(actions.positionLockTitle, action: actions.togglePositionLock))
            menu.addItem(DockMenuItem("Settings…", action: actions.settings))
            return menu
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ApplicationIconButton, context: Context) -> CGSize? {
        CGSize(width: DockMetrics(configuration.appearance, behavior: configuration.behavior).itemSide, height: DockMetrics(configuration.appearance, behavior: configuration.behavior).itemSide)
    }
}

@MainActor
final class ApplicationIconButton: DockHoverButton, NSDraggingSource, NSMenuDelegate {
    static let pasteboardType = NSPasteboard.PasteboardType("org.multidock.application-entry")
    private let iconLayer = CALayer()
    private let runningDot = CALayer()
    private let feedback = CALayer()
    var applicationImage: NSImage?
    private var lastImage: NSImage?
    private var lastTheme = DockIconTheme.original
    private var lastTint = DockIconTint.accent
    var iconTheme = DockIconTheme.original
    var iconTint = DockIconTint.accent
    var hasRenderedIcon: Bool { iconLayer.superlayer === layer && iconLayer.contents != nil }
    var isLaunchAnimating: Bool { iconLayer.animation(forKey: "launchBounce") != nil }
    private var lastRenderedSize: CGFloat = 0
    private(set) var magnification: CGFloat = 1
    private(set) var activityState = DockLaunchState.idle
    private(set) var isApplicationRunning = false
    var behavior = DockBehavior()
    var reduceMotion = false { didSet { if reduceMotion { iconLayer.removeAnimation(forKey: "launchBounce") } } }
    var orientation = DockOrientation.horizontal
    var interactionBegan: @MainActor () -> Void = {}
    var interactionEnded: @MainActor () -> Void = {}
    var hoverPointer: (NSEvent) -> Void = { _ in }
    var previewHover: (Bool) -> Void = { _ in }
    var animatesDragCancellation = true
    var applicationName = "Application"
    var itemID: UUID?
    var drag: DockItemDrag?
    var isStackTarget = false
    var entryKind = DockItemKind.application
    var dropIntoStack: (DockItemDrag?, [URL], Bool) -> Bool = { _, _, _ in false }
    private var forwardingDrop = false
    private var documentDrop = false
    private var acceptedDrop = false
    private var holdingIconDrop = false
    var canOpenFiles: ([URL]) -> Bool = { _ in false }
    var openFiles: ([URL]) -> Bool = { _ in false }
    var launch: @MainActor () -> Void = {}
    var contextMenu: () -> NSMenu = { NSMenu() }
    var dragBegan: @MainActor (NSView) -> Void = { _ in }
    var dragEnded: @MainActor () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsIcon = false
        wantsLayer = true
        iconLayer.contentsGravity = .resizeAspect
        runningDot.cornerRadius = 1.5
        feedback.cornerRadius = 3
        feedback.isHidden = true
        layer?.addSublayer(iconLayer)
        layer?.addSublayer(runningDot)
        layer?.addSublayer(feedback)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        target = self
        action = #selector(openApplication)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    private var dockHost: DockDropHostingView? {
        var view = superview
        while let current = view {
            if let host = current as? DockDropHostingView { return host }
            view = current.superview
        }
        return nil
    }
    func stackPayload(_ sender: any NSDraggingInfo) -> (DockItemDrag?, [URL]) {
        if let source = sender.draggingSource as? ApplicationIconButton, source.entryKind == .application,
           let data = sender.draggingPasteboard.data(forType: Self.pasteboardType),
           let drag = try? JSONDecoder().decode(DockItemDrag.self, from: data) { return (drag, []) }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (nil, urls)
    }
    private func endIconDrop() {
        layer?.borderWidth = 0
        if holdingIconDrop { holdingIconDrop = false; interactionEnded() }
    }
    private func iconDropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptedDrop else { return [] }
        if documentDrop { return sender.draggingSourceOperationMask.contains(.copy) ? .copy : [] }
        if sender.draggingSource is ApplicationIconButton, sender.draggingSourceOperationMask.contains(.move) { return .move }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        endIconDrop()
        let payload = stackPayload(sender)
        let kind = DockFileDropClassifier.classify(payload.1)
        documentDrop = sender.draggingSource == nil && kind == .documents && entryKind == .application
        let groupDrop = isStackTarget && (payload.0 != nil || kind == .applications)
        forwardingDrop = !documentDrop && !groupDrop
        if forwardingDrop { return dockHost?.draggingEntered(sender) ?? [] }
        acceptedDrop = documentDrop ? canOpenFiles(payload.1) : groupDrop
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 8
        layer?.borderColor = (acceptedDrop ? NSColor.systemGreen : NSColor.systemRed).cgColor
        if acceptedDrop { holdingIconDrop = true; interactionBegan() }
        return iconDropOperation(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        forwardingDrop ? (dockHost?.draggingUpdated(sender) ?? []) : iconDropOperation(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        endIconDrop()
        if forwardingDrop { dockHost?.draggingExited(sender) }
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        endIconDrop()
        if forwardingDrop { dockHost?.draggingEnded(sender) }
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        forwardingDrop ? (dockHost?.prepareForDragOperation(sender) ?? false) : !iconDropOperation(sender).isEmpty
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { endIconDrop() }
        if forwardingDrop { return dockHost?.performDragOperation(sender) ?? false }
        guard !iconDropOperation(sender).isEmpty else { return false }
        let payload = stackPayload(sender)
        if documentDrop { return openFiles(payload.1) }
        return dropIntoStack(payload.0, payload.1, !sender.draggingSourceOperationMask.contains(.move))
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endIconDrop() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc private func openApplication() { launch() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = contextMenu()
        menu.delegate = self
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { interactionBegan() }
    func menuDidClose(_ menu: NSMenu) { interactionEnded() }

    // Animated bounds can generate enter/exit events without physical pointer movement.
    // Route coordinates to one coordinator; never latch this button's highlight locally.
    override func mouseEntered(with event: NSEvent) { hoverPointer(event) }
    override func mouseExited(with event: NSEvent) { hoverPointer(event) }
    override func mouseMoved(with event: NSEvent) { hoverPointer(event) }
    func setDockHovered(_ value: Bool) {
        guard isHovered != value else { return }
        setHovered(value)
        previewHover(value)
    }

    override func layout() { super.layout(); updateIconLayers() }
    override func updateLayer() { super.updateLayer(); updateIconLayers() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateIconLayers() }
    private func updateIconLayers() {
        // SwiftUI may replace a representable's backing layer. Reattach our owned
        // layers, and update their geometry after native size changes as well.
        if let layer, iconLayer.superlayer !== layer {
            layer.addSublayer(iconLayer); layer.addSublayer(runningDot); layer.addSublayer(feedback)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.bounds = CGRect(x: 0, y: 0, width: iconDrawSize, height: iconDrawSize)
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.contentsScale = window?.backingScaleFactor ?? 2
        runningDot.frame = orientation == .horizontal
            ? CGRect(x: bounds.midX - 1.5, y: isFlipped ? bounds.maxY - 4 : 1, width: 3, height: 3)
            : CGRect(x: 1, y: bounds.midY - 1.5, width: 3, height: 3)
        runningDot.backgroundColor = NSColor.labelColor.cgColor
        feedback.frame = CGRect(x: bounds.maxX - 8, y: isFlipped ? 2 : bounds.maxY - 8, width: 6, height: 6)
        CATransaction.commit()
        let renderSize = ceil(iconDrawSize * behavior.maximumScale * (window?.backingScaleFactor ?? 2))
        if lastImage !== applicationImage || lastRenderedSize != renderSize || lastTheme != iconTheme || lastTint != iconTint {
            lastImage = applicationImage
            lastRenderedSize = renderSize
            lastTheme = iconTheme
            lastTint = iconTint
            var proposed = CGRect(x: 0, y: 0, width: renderSize, height: renderSize)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let resolved = applicationImage.flatMap { $0.isTemplate ? ($0.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? $0) : $0 }
                let pixels = resolved?.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
                iconLayer.contents = pixels.map { IconThemeRenderer.render($0, theme: iconTheme, tint: iconTint) }
                runningDot.backgroundColor = NSColor.labelColor.cgColor
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lastImage = nil
        needsLayout = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lastImage = nil
        needsLayout = true
    }
    func setMagnification(_ value: CGFloat, duration: Double) {
        if reduceMotion { iconLayer.removeAnimation(forKey: "magnification") }
        let target = reduceMotion ? 1 : value
        guard abs(target - magnification) > 0.002 else { return }
        let start = (iconLayer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? Double(magnification)
        iconLayer.removeAnimation(forKey: "magnification")
        magnification = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.transform = CATransform3DMakeScale(target, target, 1)
        CATransaction.commit()
        if !reduceMotion && duration > 0 {
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = start
            animation.toValue = Double(target)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconLayer.add(animation, forKey: "magnification")
        }
    }
    func applyActivity(running: Bool, state: DockLaunchState) {
        if isApplicationRunning && !running { previewHover(false) }
        isApplicationRunning = running
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        runningDot.isHidden = !running || !behavior.showsRunningIndicators
        CATransaction.commit()
        if state == .launching && activityState != .launching && !reduceMotion {
            let animation = CAKeyframeAnimation(keyPath: orientation == .horizontal ? "transform.translation.y" : "transform.translation.x")
            let direction: CGFloat = orientation == .horizontal && isFlipped ? -1 : 1
            animation.values = [0, 6 * direction, 0, 3 * direction, 0]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.duration = 0.46
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            iconLayer.add(animation, forKey: "launchBounce")
        }
        if state == .failed || reduceMotion { iconLayer.removeAnimation(forKey: "launchBounce") }
        activityState = state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedback.isHidden = state == .idle
        switch state {
        case .idle, .launching: feedback.backgroundColor = NSColor.controlAccentColor.cgColor
        case .succeeded: feedback.backgroundColor = NSColor.systemGreen.cgColor
        case .failed: feedback.backgroundColor = NSColor.systemRed.cgColor
        }
        CATransaction.commit()
        toolTip = nil
    }


    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        interactionBegan()
        defer { interactionEnded() }
        let origin = event.locationInWindow
        highlight(true)
        defer { highlight(false) }
        // AppKit blocks for mouse tracking events. No timer or polling loop runs while idle.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                return
            }
            if hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) >= 5 {
                guard let drag else { return }
                do {
                    let writer = NSPasteboardItem()
                    writer.setData(try JSONEncoder().encode(drag), forType: Self.pasteboardType)
                    let draggingItem = NSDraggingItem(pasteboardWriter: writer)
                    draggingItem.setDraggingFrame(bounds.insetBy(dx: 5, dy: 5), contents: applicationImage)
                    highlight(false)
                    dragBegan(self)
                    let session = beginDraggingSession(with: [draggingItem], event: next, source: self)
                    session.animatesToStartingPositionsOnCancelOrFail = animatesDragCancellation
                } catch {
                    // UUID-only payloads have no fallible custom encoding; retain visible feedback if that changes.
                    NSSound.beep()
                }
                return
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded()
    }
}
