import CoreGraphics
import Foundation

/// All geometry is in logical points. AppKit supplies each display's backing scale.
struct DockMetrics: Equatable, Sendable {
    let iconSize: CGFloat
    let itemSide: CGFloat
    let spacing: CGFloat
    let padding: CGFloat
    let gripSide: CGFloat = 10
    let emptyLength: CGFloat = 96

    init(_ appearance: DockAppearance, behavior: DockBehavior = DockBehavior()) {
        let style = appearance.normalized
        iconSize = style.iconSize
        itemSide = ceil(style.iconSize * behavior.maximumScale) + 8
        spacing = style.spacing
        padding = style.padding
    }
    var overhead: CGFloat { padding * 2 + gripSide + spacing }
}

enum DockLayout {
    static func contentLength(for configuration: DockConfiguration) -> CGFloat {
        let metrics = DockMetrics(configuration.appearance, behavior: configuration.behavior)
        let count = configuration.applications.count
        if count == 0 { return metrics.emptyLength }
        let restingSide = metrics.iconSize + 8
        // The wave reaches fewer than four resting slots. Reserve its maximum growth once,
        // rather than leaving a full magnification envelope around every icon in long docks.
        let waveReserve = CGFloat(min(count, 4)) * (metrics.itemSide - restingSide)
        return CGFloat(count) * restingSide + CGFloat(count - 1) * metrics.spacing + waveReserve
    }

    static func size(for configuration: DockConfiguration, maximumLength: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let metrics = DockMetrics(configuration.appearance, behavior: configuration.behavior)
        let limit = maximumLength.isFinite ? maximumLength : .greatestFiniteMagnitude
        let length = min(metrics.overhead + contentLength(for: configuration), max(metrics.overhead + metrics.itemSide, limit))
        let thickness = metrics.padding * 2 + metrics.itemSide
        return configuration.orientation == .horizontal
            ? CGSize(width: length, height: thickness) : CGSize(width: thickness, height: length)
    }

    static func constrainedOrigin(_ position: DockPosition, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(position.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width)),
            y: min(max(position.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        )
    }
}

/// Screen-aware label placement shared by AppKit and coordinate tests.
enum DockLabelGeometry {
    static func frame(icon: CGRect, dock: CGRect, visible: CGRect, size: CGSize, orientation: DockOrientation) -> CGRect {
        let size = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        let above = CGPoint(x: icon.midX - size.width / 2, y: dock.maxY + 8)
        let below = CGPoint(x: icon.midX - size.width / 2, y: dock.minY - size.height - 8)
        let right = CGPoint(x: dock.maxX + 8, y: icon.midY - size.height / 2)
        let left = CGPoint(x: dock.minX - size.width - 8, y: icon.midY - size.height / 2)
        let candidates = orientation == .horizontal ? [above, below, right, left] : [right, left, above, below]
        let frames = candidates.map { point in
            CGRect(origin: DockLayout.constrainedOrigin(DockPosition(x: point.x, y: point.y), size: size, visibleFrame: visible), size: size)
        }
        // Prefer the orientation's natural side, then choose a side clear of the full dock.
        return frames.first { !$0.intersects(dock) } ?? frames.min { a, b in
            let x = a.intersection(dock), y = b.intersection(dock)
            return x.width * x.height < y.width * y.height
        }!
    }
}
