import AppKit
import SwiftUI

/// A single AppKit drop destination covers icons, whitespace, and an empty dock.
@MainActor
final class DockDropHostingView: NSHostingView<DockView>, NSMenuDelegate {
    var configuration: DockConfiguration
    var actions: DockActions
    var closeDock: @MainActor () -> Void
    private let insertion = CALayer()
    private var externalDropKind: DockFileDropKind?
    private var pointerTracking: NSTrackingArea?
    var pointerChanged: ((CGPoint?) -> Void)?
    var hoverPointer: ((NSEvent) -> Void)?
    var iconStrip: DockIconStripView? {
        func find(_ view: NSView) -> DockIconStripView? {
            (view as? DockIconStripView) ?? view.subviews.lazy.compactMap(find).first
        }
        return find(self)
    }
    var applicationButtons: [ApplicationIconButton] { iconStrip?.buttons ?? icons(in: self) }
    func setManagementVisible(_ visible: Bool) {
        func visit(_ view: NSView) {
            (view as? any DockManagementControl)?.setManagementVisible(visible)
            view.subviews.forEach(visit)
        }
        visit(self)
    }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
        pointerTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    private func routePointer(_ event: NSEvent) {
        if let hoverPointer { hoverPointer(event) }
        else { pointerChanged?(bounds.contains(convert(event.locationInWindow, from: nil)) ? event.locationInWindow : nil) }
    }
    override func mouseEntered(with event: NSEvent) { routePointer(event) }
    override func mouseMoved(with event: NSEvent) { routePointer(event) }
    override func mouseExited(with event: NSEvent) { routePointer(event) }
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        routePointer(event)
    }
    func menuWillOpen(_ menu: NSMenu) { actions.interactionBegan() }
    func menuDidClose(_ menu: NSMenu) { actions.interactionEnded() }

    init(rootView: DockView, configuration: DockConfiguration, actions: DockActions, close: @escaping @MainActor () -> Void) {
        self.configuration = configuration
        self.actions = actions
        closeDock = close
        super.init(rootView: rootView)
        sizingOptions = []
        wantsLayer = true
        insertion.backgroundColor = NSColor.controlAccentColor.cgColor
        insertion.cornerRadius = 1
        insertion.isHidden = true
        layer?.addSublayer(insertion)
        registerForDraggedTypes([.fileURL, ApplicationIconButton.pasteboardType])
    }
    @available(*, unavailable)
    required init(rootView: DockView) { fatalError("Use designated initializer") }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use designated initializer") }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = dockOptionsMenu(actions: actions)
        menu.delegate = self
        return menu
    }

    private func internalDrag(_ sender: any NSDraggingInfo) -> DockItemDrag? {
        // Never trust an external program's private payload or an arbitrary source item.
        guard sender.draggingSource is ApplicationIconButton,
              let data = sender.draggingPasteboard.data(forType: ApplicationIconButton.pasteboardType) else { return nil }
        return try? JSONDecoder().decode(DockItemDrag.self, from: data)
    }
    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if internalDrag(sender) != nil {
            return sender.draggingSourceOperationMask.contains(.move) ? .move :
                sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
        }
        if externalDropKind == nil { externalDropKind = DockFileDropClassifier.classify(fileURLs(sender)) }
        return sender.draggingSourceOperationMask.contains(.copy) && externalDropKind == .applications ? .copy : []
    }
    private func icons(in view: NSView) -> [ApplicationIconButton] {
        (view as? ApplicationIconButton).map { [$0] } ?? view.subviews.flatMap { icons(in: $0) }
    }
    private func gap(_ sender: any NSDraggingInfo) -> Int {
        let buttons = icons(in: self)
        for (index, item) in configuration.applications.enumerated() {
            guard let button = buttons.first(where: { $0.itemID == item.id }) else { continue }
            let rect = button.convert(button.bounds, to: nil)
            if configuration.orientation == .horizontal ? sender.draggingLocation.x < rect.midX : sender.draggingLocation.y > rect.midY {
                return index
            }
        }
        return configuration.applications.count
    }
    private func showInsertion(at index: Int) {
        let metrics = DockMetrics(configuration.appearance, behavior: configuration.behavior)
        let horizontal = configuration.orientation == .horizontal
        let start = metrics.padding + metrics.gripSide + metrics.spacing
        let end = max(start, (horizontal ? bounds.width : bounds.height)
            - metrics.padding)
        let buttons = icons(in: self)
        let entries = configuration.applications
        let item = index < entries.count ? entries[index] : entries.last
        var rect = horizontal
            ? CGRect(x: start, y: metrics.padding, width: metrics.itemSide, height: metrics.itemSide)
            : CGRect(x: metrics.padding, y: start, width: metrics.itemSide, height: metrics.itemSide)
        if let item, let button = buttons.first(where: { $0.itemID == item.id }) {
            rect = button.convert(button.bounds, to: self)
        }
        let after = index == entries.count && !entries.isEmpty
        let halfGap = metrics.spacing / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        insertion.backgroundColor = NSColor.controlAccentColor.cgColor
        if horizontal {
            let x = after ? rect.maxX + halfGap - 1 : rect.minX - halfGap - 1
            insertion.frame = CGRect(x: min(max(x, start - 1), end), y: rect.minY + 3,
                                     width: 2, height: max(1, rect.height - 6))
        } else {
            let leading = isFlipped ? rect.minY - halfGap - 1 : rect.maxY + halfGap - 1
            let trailing = isFlipped ? rect.maxY + halfGap - 1 : rect.minY - halfGap - 1
            insertion.frame = CGRect(x: rect.minX + 3, y: min(max(after ? trailing : leading, start - 1), end),
                                     width: max(1, rect.width - 6), height: 2)
        }
        layer?.addSublayer(insertion)
        insertion.isHidden = false
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }
    private var holdingDrop = false
    private func endDropHold() {
        if holdingDrop { holdingDrop = false; actions.interactionEnded() }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        externalDropKind = nil
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let result = operation(sender)
        if result.isEmpty { insertion.isHidden = true; endDropHold() }
        else {
            if !holdingDrop { holdingDrop = true; actions.interactionBegan() }
            showInsertion(at: gap(sender))
        }
        return result
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { insertion.isHidden = true; endDropHold() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { insertion.isHidden = true; endDropHold() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !operation(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { endDropHold() }
        insertion.isHidden = true
        let result = operation(sender)
        guard !result.isEmpty else { return false }
        return actions.drop(internalDrag(sender), fileURLs(sender), gap(sender), result == .copy)
    }
}
