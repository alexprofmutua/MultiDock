import Foundation
import CoreGraphics

struct DockBehavior: Codable, Equatable, Sendable {
    var clickMode = DockClickMode.standard
    var restoreMinimizedOnClick = true
    var positionLocked = false
    var magnificationEnabled = false
    var magnificationStrength = 0.5
    var magnificationDuration = 0.12
    var autoHideEnabled = false
    var autoHideDelay = 0.8
    var visibilityDuration = 0.18
    var showsRunningIndicators = false
    var collapseEnabled = false
    var isCollapsed = false
    var windowPreviewsEnabled = false

    enum CodingKeys: String, CodingKey {
        case clickMode, restoreMinimizedOnClick, positionLocked, magnificationEnabled, magnificationStrength, magnificationDuration, autoHideEnabled, autoHideDelay
        case visibilityDuration, showsRunningIndicators, collapseEnabled, isCollapsed, windowPreviewsEnabled
    }
    var normalized: Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        var value = self
        value.magnificationStrength = clamp(magnificationStrength, 0...1, 0.5)
        value.magnificationDuration = clamp(magnificationDuration, 0.04...0.4, 0.12)
        value.autoHideDelay = clamp(autoHideDelay, 0.2...5, 0.8)
        value.visibilityDuration = clamp(visibilityDuration, 0.05...0.5, 0.18)
        if !collapseEnabled { value.isCollapsed = false }
        return value
    }
    var maximumScale: Double { magnificationEnabled ? 1 + normalized.magnificationStrength : 1 }
}

extension DockBehavior {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clickMode = try c.decodeIfPresent(DockClickMode.self, forKey: .clickMode) ?? .standard
        restoreMinimizedOnClick = try c.decodeIfPresent(Bool.self, forKey: .restoreMinimizedOnClick) ?? true
        positionLocked = try c.decodeIfPresent(Bool.self, forKey: .positionLocked) ?? false
        magnificationEnabled = try c.decode(Bool.self, forKey: .magnificationEnabled)
        magnificationStrength = try c.decode(Double.self, forKey: .magnificationStrength)
        magnificationDuration = try c.decode(Double.self, forKey: .magnificationDuration)
        autoHideEnabled = try c.decode(Bool.self, forKey: .autoHideEnabled)
        autoHideDelay = try c.decode(Double.self, forKey: .autoHideDelay)
        visibilityDuration = try c.decode(Double.self, forKey: .visibilityDuration)
        showsRunningIndicators = try c.decode(Bool.self, forKey: .showsRunningIndicators)
        collapseEnabled = try c.decode(Bool.self, forKey: .collapseEnabled)
        isCollapsed = try c.decode(Bool.self, forKey: .isCollapsed)
        windowPreviewsEnabled = try c.decodeIfPresent(Bool.self, forKey: .windowPreviewsEnabled) ?? false
    }

}

enum DockLaunchState: Equatable, Sendable {
    case idle, launching, succeeded, failed
}

/// All instances, not just one PID, contribute to a bundle's running indicator.
struct RunningApplicationState: Equatable, Sendable {
    private(set) var processes: [Int32: String] = [:]
    mutating func launched(pid: Int32, bundleIdentifier: String) { processes[pid] = bundleIdentifier.lowercased() }
    mutating func terminated(pid: Int32) { processes.removeValue(forKey: pid) }
    func isRunning(_ bundleIdentifier: String) -> Bool { processes.values.contains(bundleIdentifier.lowercased()) }
}

enum DockInteractionGeometry {
    static func scale(pointer: CGPoint?, center: CGPoint, itemSide: CGFloat,
                      behavior: DockBehavior, reduceMotion: Bool) -> CGFloat {
        guard let pointer, pointer.x.isFinite, pointer.y.isFinite, itemSide > 0,
              behavior.magnificationEnabled, !reduceMotion else { return 1 }
        let distance = hypot(pointer.x - center.x, pointer.y - center.y)
        let radius = itemSide * 1.8
        guard distance < radius else { return 1 }
        return 1 + behavior.normalized.magnificationStrength * (cos(.pi * distance / radius) + 1) / 2
    }

    /// A failed allocation keeps the full dock visible. Never create overlapping invisible reveal zones.
    static func revealFrame(dockFrame: CGRect, orientation: DockOrientation, visibleFrame: CGRect,
                            occupied: [CGRect]) -> CGRect? {
        let size = orientation == .horizontal ? CGSize(width: 44, height: 8) : CGSize(width: 8, height: 44)
        guard visibleFrame.width >= size.width, visibleFrame.height >= size.height else { return nil }
        let desired: DockPosition
        if orientation == .horizontal {
            let y = abs(dockFrame.minY - visibleFrame.minY) <= 12 ? visibleFrame.minY
                : abs(dockFrame.maxY - visibleFrame.maxY) <= 12 ? visibleFrame.maxY - size.height
                : dockFrame.midY - size.height / 2
            desired = DockPosition(x: dockFrame.midX - size.width / 2, y: y)
        } else {
            let x = abs(dockFrame.minX - visibleFrame.minX) <= 12 ? visibleFrame.minX
                : abs(dockFrame.maxX - visibleFrame.maxX) <= 12 ? visibleFrame.maxX - size.width
                : dockFrame.midX - size.width / 2
            desired = DockPosition(x: x, y: dockFrame.midY - size.height / 2)
        }
        let origin = DockLayout.constrainedOrigin(desired, size: size, visibleFrame: visibleFrame)
        func candidate(_ x: Int, _ y: Int) -> CGRect? {
            let frame = CGRect(x: origin.x + CGFloat(x) * 34, y: origin.y + CGFloat(y) * 34,
                               width: size.width, height: size.height)
            guard visibleFrame.contains(frame), !occupied.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(frame) }) else { return nil }
            return frame
        }
        if let first = candidate(0, 0) { return first }
        let maxRing = Int(ceil(max(visibleFrame.width, visibleFrame.height) / 34)) + 1
        for ring in 1...maxRing {
            for coordinate in -ring...ring {
                for point in [(coordinate, ring), (coordinate, -ring), (ring, coordinate), (-ring, coordinate)] {
                    if let frame = candidate(point.0, point.1) { return frame }
                }
            }
        }
        return nil
    }
}

/// Stable resting coordinates drive a wave; moving icon frames never feed back into the next sample.
struct DockIconPlacement: Equatable, Sendable {
    let frame: CGRect
    let scale: CGFloat
}

enum DockMagnificationLayout {
    static func placements(count: Int, bounds: CGRect, pointer: CGPoint?, orientation: DockOrientation,
                           appearance: DockAppearance, behavior: DockBehavior, reduceMotion: Bool) -> [DockIconPlacement] {
        guard count > 0, bounds.width.isFinite, bounds.height.isFinite else { return [] }
        let metrics = DockMetrics(appearance, behavior: behavior)
        let horizontal = orientation == .horizontal
        let length = horizontal ? bounds.width : bounds.height
        let cross = horizontal ? bounds.height : bounds.width
        let rest = metrics.iconSize + 8
        let restLength = CGFloat(count) * rest + CGFloat(count - 1) * metrics.spacing
        let restStart = (length - restLength) / 2
        let coordinate = pointer.map { horizontal ? $0.x - bounds.minX : $0.y - bounds.minY }
        let scales = (0..<count).map { index in
            let center = restStart + rest / 2 + CGFloat(index) * (rest + metrics.spacing)
            return DockInteractionGeometry.scale(pointer: coordinate.map { CGPoint(x: $0, y: 0) },
                center: CGPoint(x: center, y: 0), itemSide: rest, behavior: behavior, reduceMotion: reduceMotion)
        }
        let sides = scales.map { metrics.iconSize * $0 + 8 }
        let total = sides.reduce(0, +) + CGFloat(count - 1) * metrics.spacing
        // Integrate growth to the pointer's resting coordinate. This keeps the wave
        // anchored beneath the pointer instead of shifting both endpoints equally.
        // Smoothstep gives continuous slope through icon boundaries and gaps.
        var growthBeforePointer: CGFloat = 0
        if let coordinate, coordinate.isFinite {
            for index in 0..<count {
                let start = restStart + CGFloat(index) * (rest + metrics.spacing)
                let fraction = min(max((coordinate - start) / rest, 0), 1)
                let smooth = fraction * fraction * (3 - 2 * fraction)
                growthBeforePointer += (sides[index] - rest) * smooth
            }
        }
        var offset = min(max(restStart - growthBeforePointer, 0), max(0, length - total))
        return zip(sides, scales).map { side, scale in
            defer { offset += side + metrics.spacing }
            // Horizontal icons share a bottom baseline; left-edge vertical icons grow rightward.
            let frame = horizontal
                ? CGRect(x: bounds.minX + offset, y: bounds.minY + cross - side, width: side, height: side)
                : CGRect(x: bounds.minX, y: bounds.minY + offset, width: side, height: side)
            return DockIconPlacement(frame: frame, scale: scale)
        }
    }
}

enum DockClickMode: String, Codable, CaseIterable, Sendable {
    case standard, smartActivate, cycleWindows
    var title: String {
        switch self {
        case .standard: "Standard"
        case .smartActivate: "Smart Activate"
        case .cycleWindows: "Cycle Windows"
        }
    }
}

/// Selection policy is independent of Accessibility handles and can be tested without permission.
struct WindowCycleCursor: Sendable {
    private var application: String?
    private var selected: UUID?
    mutating func select(application: String, windows: [UUID], cycling: Bool) -> UUID? {
        if self.application != application { self.application = application; selected = nil }
        guard !windows.isEmpty else { selected = nil; return nil }
        if cycling, let selected, let index = windows.firstIndex(of: selected) {
            self.selected = windows[(index + 1) % windows.count]
        } else { selected = windows[0] }
        return selected
    }
}
