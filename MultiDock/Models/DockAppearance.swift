import Foundation

enum DockColorMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    var title: String { rawValue.capitalized }
}

enum DockIconTheme: String, Codable, CaseIterable, Sendable {
    case original, monochrome, tinted
    var title: String { self == .original ? "App icons" : rawValue.capitalized }
}
enum DockIconTint: String, Codable, CaseIterable, Sendable {
    case accent, blue, purple, green, orange, graphite
    var title: String { self == .accent ? "System accent" : rawValue.capitalized }
}

enum DockBackgroundColor: String, Codable, CaseIterable, Sendable {
    case material, blue, purple, pink, green, orange, graphite, black, white
    var title: String { self == .material ? "Adaptive glass" : rawValue.capitalized }
}

/// Shared by the global reveal-tab theme and independent per-dock overrides.
struct DockRevealStyle: Codable, Equatable, Sendable {
    var color = DockBackgroundColor.material
    var opacity: Double = 1

    var normalized: Self {
        var result = self
        result.opacity = opacity.isFinite ? min(max(opacity, 0.25), 1) : 1
        return result
    }
    func effectiveOpacity(reduceTransparency: Bool, increaseContrast: Bool) -> Double {
        reduceTransparency || increaseContrast ? 1 : normalized.opacity
    }
}

struct DockAppearance: Codable, Equatable, Sendable {
    var iconSize: Double = 32
    var spacing: Double = 4
    var padding: Double = 6
    var colorMode: DockColorMode = .system
    var backgroundOpacity: Double = 0.9
    var cornerRadius: Double = 14

    var iconTheme = DockIconTheme.original
    var iconTint = DockIconTint.accent
    var backgroundColor = DockBackgroundColor.material
    var backgroundTintStrength: Double = 0.35
    var revealTabUsesGlobal = true
    var revealTabStyle = DockRevealStyle()

    static let iconRange: ClosedRange<Double> = 24...64
    static let spacingRange: ClosedRange<Double> = 0...16
    static let paddingRange: ClosedRange<Double> = 2...18
    static let opacityRange: ClosedRange<Double> = 0.25...1
    static let radiusRange: ClosedRange<Double> = 0...30

    /// Treat imported or programmatic values as untrusted layout input.
    var normalized: Self {
        func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        var result = self
        result.iconSize = clamp(iconSize, to: Self.iconRange, fallback: 32)
        result.spacing = clamp(spacing, to: Self.spacingRange, fallback: 4)
        result.padding = clamp(padding, to: Self.paddingRange, fallback: 6)
        result.backgroundOpacity = clamp(backgroundOpacity, to: Self.opacityRange, fallback: 0.9)
        result.cornerRadius = clamp(cornerRadius, to: Self.radiusRange, fallback: 14)
        result.backgroundTintStrength = clamp(backgroundTintStrength, to: 0...1, fallback: 0.35)
        result.revealTabStyle = revealTabStyle.normalized
        return result
    }

    func effectiveRevealStyle(global: DockRevealStyle) -> DockRevealStyle {
        (revealTabUsesGlobal ? global : revealTabStyle).normalized
    }
}

extension DockAppearance {
    enum CodingKeys: String, CodingKey {
        case iconSize, spacing, padding, colorMode, backgroundOpacity, cornerRadius, iconTheme, iconTint, backgroundColor, backgroundTintStrength, revealTabUsesGlobal, revealTabStyle
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iconSize = try c.decode(Double.self, forKey: .iconSize)
        spacing = try c.decode(Double.self, forKey: .spacing)
        padding = try c.decode(Double.self, forKey: .padding)
        colorMode = try c.decode(DockColorMode.self, forKey: .colorMode)
        backgroundOpacity = try c.decode(Double.self, forKey: .backgroundOpacity)
        cornerRadius = try c.decode(Double.self, forKey: .cornerRadius)
        iconTheme = try c.decodeIfPresent(DockIconTheme.self, forKey: .iconTheme) ?? .original
        iconTint = try c.decodeIfPresent(DockIconTint.self, forKey: .iconTint) ?? .accent
        backgroundColor = try c.decodeIfPresent(DockBackgroundColor.self, forKey: .backgroundColor) ?? .material
        backgroundTintStrength = try c.decodeIfPresent(Double.self, forKey: .backgroundTintStrength) ?? 0.35
        revealTabUsesGlobal = try c.decodeIfPresent(Bool.self, forKey: .revealTabUsesGlobal) ?? true
        revealTabStyle = try c.decodeIfPresent(DockRevealStyle.self, forKey: .revealTabStyle) ?? DockRevealStyle()
    }
}

struct DockAccessibility: Equatable, Sendable {
    var reduceTransparency = false
    var reduceMotion = false
    var increaseContrast = false

    func surfaceOpacity(for appearance: DockAppearance) -> Double {
        reduceTransparency ? 1 : appearance.normalized.backgroundOpacity
    }
    var animatesDragCancellation: Bool { !reduceMotion }
}
