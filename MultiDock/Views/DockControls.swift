import AppKit
import SwiftUI

@MainActor
protocol DockManagementControl: AnyObject {
    func setManagementVisible(_ visible: Bool)
}

/// Shared static hover surface; application buttons draw their icons with interruptible native layers.
@MainActor
class DockHoverButton: NSButton {
    var drawsIcon = true
    var iconDrawSize: CGFloat = 32 { didSet { needsDisplay = true } }
    var increaseContrast = false { didSet { needsDisplay = true } }
    private(set) var isHovered = false
    private var hoverTracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        hoverTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool) { guard isHovered != value else { return }; isHovered = value; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            let rect = bounds.insetBy(dx: 1, dy: 1)
            NSColor.labelColor.withAlphaComponent(increaseContrast ? 0.22 : (isHighlighted ? 0.18 : 0.09)).setFill()
            let shape = NSBezierPath(roundedRect: rect, xRadius: min(8, rect.width / 4), yRadius: min(8, rect.height / 4))
            shape.fill()
            if increaseContrast {
                NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                shape.lineWidth = 1
                shape.stroke()
            }
        }
        guard drawsIcon else { return }
        let side = min(iconDrawSize, min(bounds.width, bounds.height))
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let renderedImage = image.flatMap { image in
            image.isTemplate ? (image.withSymbolConfiguration(.init(paletteColors: [.labelColor])) ?? image) : image
        }
        renderedImage?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

struct DockDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.needsDisplay = true }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 14, height: proposal.height ?? 14)
    }
}

private final class DragHandleView: NSImageView, DockManagementControl {
    func setManagementVisible(_ visible: Bool) { isHidden = !visible }
    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { (window as? DockPanel)?.positionLocked == false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        image = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "Move dock")
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
        toolTip = "Drag to move dock"
        setAccessibilityLabel("Move dock using this drag handle")
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func mouseDown(with event: NSEvent) {
        (window as? DockPanel)?.startPositionDrag(with: event)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

}

/// One reusable, noninteractive name bubble per dock. No timer or global tooltip delay.
@MainActor
final class DockNameLabelController {
    private(set) var panel: NSPanel?
    private(set) var text = ""
    private let label = NSTextField(labelWithString: "")

    func show(_ name: String, anchor: NSView, orientation: DockOrientation, windowRect: CGRect? = nil) {
        guard let parent = anchor.window, parent.isVisible else { hide(); return }
        if panel == nil {
            let panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
            let surface = NSVisualEffectView()
            surface.material = .popover
            surface.blendingMode = .behindWindow
            surface.state = .active
            surface.wantsLayer = true
            surface.layer?.cornerRadius = 7
            surface.layer?.masksToBounds = true
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            surface.addSubview(label)
            panel.contentView = surface
            self.panel = panel
        }
        guard let panel else { return }
        if text != name {
            text = name
            label.stringValue = name
            panel.title = name
        }
        panel.appearance = parent.appearance
        let icon = parent.convertToScreen(windowRect ?? anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.max { a, b in
            let x = a.frame.intersection(icon), y = b.frame.intersection(icon)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        } ?? parent.screen
        guard let screen else { hide(); return }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(280, max(40, min(visible.width, label.fittingSize.width + 20))), height: 28)
        let frame = DockLabelGeometry.frame(icon: icon, dock: parent.frame, visible: visible, size: size, orientation: orientation)
        if let surface = panel.contentView as? NSVisualEffectView {
            let preferences = DockAccessibility.current
            surface.blendingMode = preferences.reduceTransparency ? .withinWindow : .behindWindow
            surface.effectiveAppearance.performAsCurrentDrawingAppearance {
                surface.layer?.backgroundColor = preferences.reduceTransparency ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
                surface.layer?.borderColor = NSColor.labelColor.withAlphaComponent(preferences.increaseContrast ? 0.8 : 0.2).cgColor
            }
            surface.layer?.borderWidth = preferences.increaseContrast ? 2 : 0.5
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        label.frame = CGRect(x: 10, y: 6, width: size.width - 20, height: 16)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func hide() { text = ""; panel?.orderOut(nil) }
    func shutdown() {
        if let panel { panel.parent?.removeChildWindow(panel); panel.close() }
        panel = nil
        text = ""
    }
}
