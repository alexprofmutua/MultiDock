import CoreGraphics
import Foundation

enum DockAnchor: String, Codable, CaseIterable, Sendable {
    case free, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    var title: String {
        switch self {
        case .free: "Free position"
        case .left: "Left edge"
        case .right: "Right edge"
        case .top: "Top edge"
        case .bottom: "Bottom edge"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
    var left: Bool { [.left, .topLeft, .bottomLeft].contains(self) }
    var right: Bool { [.right, .topRight, .bottomRight].contains(self) }
    var top: Bool { [.top, .topLeft, .topRight].contains(self) }
    var bottom: Bool { [.bottom, .bottomLeft, .bottomRight].contains(self) }
}

struct DockPlacement: Codable, Equatable, Sendable {
    var displayID: String?
    // Fractions of the available travel inside visibleFrame, not physical pixels.
    var relativeX: Double = 0.5
    var relativeY: Double = 0.5
    var anchor: DockAnchor = .free
    var snappingEnabled = true
}

struct DockDisplay: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    var scale: Double = 1
    var isPrimary = false

    var isUsable: Bool {
        [visibleFrame.minX, visibleFrame.minY, visibleFrame.width, visibleFrame.height].allSatisfy { $0.isFinite && abs($0) < 10_000_000 }
            && visibleFrame.width > 0 && visibleFrame.height > 0
    }
}

struct DockPlacementResult: Equatable, Sendable {
    let frame: CGRect
    let display: DockDisplay
    var maximumLength: CGFloat
}

/// Pure AppKit-coordinate geometry. Display pixels and CoreGraphics' top-left origin never enter it.
enum DockPositioning {
    static let snapDistance: CGFloat = 12

    static func valid(_ position: DockPosition) -> Bool {
        [position.x, position.y].allSatisfy { $0.isFinite && abs($0) < 10_000_000 }
    }
    static func fraction(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0.5 }

    static func display(for frame: CGRect, in displays: [DockDisplay]) -> DockDisplay? {
        let usable = displays.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }
        let ranked = usable.map { display -> (DockDisplay, CGFloat) in
            let intersection = frame.intersection(display.frame)
            return (display, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        if let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return usable.first(where: \.isPrimary) ?? usable.first
    }

    static func resolve(_ dock: DockConfiguration, displays: [DockDisplay], restoring: Bool) -> DockPlacementResult? {
        let usable = displays.filter(\.isUsable)
        let preferred = usable.first { $0.id == dock.placement.displayID }
        let pointValid = valid(dock.position)
        let natural = DockLayout.size(for: dock)
        let current = CGRect(x: pointValid ? dock.position.x : 0, y: pointValid ? dock.position.y : 0,
                             width: natural.width, height: natural.height)
        let target: DockDisplay?
        if restoring, dock.placement.displayID != nil {
            target = preferred ?? usable.first(where: \.isPrimary) ?? usable.first
        } else if pointValid {
            let point = CGPoint(x: dock.position.x, y: dock.position.y)
            // Growing a long dock must not make another display win an intersection comparison.
            target = preferred.flatMap { $0.frame.contains(point) ? $0 : nil }
                ?? usable.first(where: { $0.frame.contains(point) }) ?? display(for: current, in: usable)
        } else {
            target = preferred ?? usable.first(where: \.isPrimary) ?? usable.first
        }
        guard let target else { return nil }
        let maximumLength = dock.orientation == .horizontal ? target.visibleFrame.width : target.visibleFrame.height
        let size = DockLayout.size(for: dock, maximumLength: maximumLength)
        let bounds = target.visibleFrame
        let travelX = max(0, bounds.width - size.width), travelY = max(0, bounds.height - size.height)
        var position = dock.position
        if !pointValid || (restoring && dock.placement.displayID != nil) {
            position = DockPosition(x: bounds.minX + fraction(dock.placement.relativeX) * travelX,
                                    y: bounds.minY + fraction(dock.placement.relativeY) * travelY)
        }
        if dock.placement.anchor.left { position.x = bounds.minX }
        if dock.placement.anchor.right { position.x = bounds.minX + travelX }
        if dock.placement.anchor.bottom { position.y = bounds.minY }
        if dock.placement.anchor.top { position.y = bounds.minY + travelY }
        let origin = DockLayout.constrainedOrigin(position, size: size, visibleFrame: bounds)
        return DockPlacementResult(frame: CGRect(origin: origin, size: size), display: target, maximumLength: maximumLength)
    }

    /// Resizing a free dock preserves its origin unless containment requires a correction.
    /// A temporary fallback must not erase the disconnected display's saved position.
    static func recordLayout(_ result: DockPlacementResult, in dock: inout DockConfiguration) {
        dock.position = DockPosition(x: result.frame.minX, y: result.frame.minY)
        if dock.placement.displayID == nil || dock.placement.displayID == result.display.id {
            recordFractions(result.frame, display: result.display, in: &dock)
        }
    }

    private static func recordFractions(_ frame: CGRect, display: DockDisplay, in dock: inout DockConfiguration) {
        dock.placement.displayID = display.id
        let x = max(0, display.visibleFrame.width - frame.width)
        let y = max(0, display.visibleFrame.height - frame.height)
        dock.placement.relativeX = x > 0 ? fraction((frame.minX - display.visibleFrame.minX) / x) : 0
        dock.placement.relativeY = y > 0 ? fraction((frame.minY - display.visibleFrame.minY) / y) : 0
    }

    static func finishDrag(_ frame: CGRect, dock: inout DockConfiguration, displays: [DockDisplay]) {
        guard let target = display(for: frame, in: displays) else { return }
        dock.position = DockPosition(x: frame.minX, y: frame.minY)
        dock.placement.anchor = .free
        dock.placement.displayID = target.id
        guard var result = resolve(dock, displays: [target], restoring: false) else { return }
        var x: DockAnchor = .free, y: DockAnchor = .free
        if dock.placement.snappingEnabled {
            let bounds = target.visibleFrame
            if abs(result.frame.minX - bounds.minX) <= snapDistance { x = .left }
            else if abs(result.frame.maxX - bounds.maxX) <= snapDistance { x = .right }
            if abs(result.frame.minY - bounds.minY) <= snapDistance { y = .bottom }
            else if abs(result.frame.maxY - bounds.maxY) <= snapDistance { y = .top }
        }
        switch (x, y) {
        case (.left, .top): dock.placement.anchor = .topLeft
        case (.right, .top): dock.placement.anchor = .topRight
        case (.left, .bottom): dock.placement.anchor = .bottomLeft
        case (.right, .bottom): dock.placement.anchor = .bottomRight
        case (.free, _): dock.placement.anchor = y
        default: dock.placement.anchor = x
        }
        if let snapped = resolve(dock, displays: [target], restoring: false) { result = snapped }
        dock.position = DockPosition(x: result.frame.minX, y: result.frame.minY)
        recordFractions(result.frame, display: target, in: &dock)
    }

    static func place(_ dock: inout DockConfiguration, on display: DockDisplay, anchor: DockAnchor) {
        dock.placement.displayID = display.id
        dock.placement.anchor = anchor
        guard let result = resolve(dock, displays: [display], restoring: true) else { return }
        recordLayout(result, in: &dock)
    }
}
