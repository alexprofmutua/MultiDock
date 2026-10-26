import AppKit
import SwiftUI

extension DockAccessibility {
    @MainActor static var current: Self {
        let workspace = NSWorkspace.shared
        return Self(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                    reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                    increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }
}

struct DockBackground: NSViewRepresentable {
    let appearance: DockAppearance
    let accessibility: DockAccessibility
    func makeNSView(context: Context) -> DockSurface { DockSurface() }
    func updateNSView(_ view: DockSurface, context: Context) { view.apply(appearance, accessibility: accessibility) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DockSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// The material alone changes opacity. App icons and the border remain fully opaque.
@MainActor
final class DockSurface: NSView {
    let effect = NSVisualEffectView()
    let tintOverlay = NSView()
    private(set) var style = DockAppearance()
    private(set) var preferences = DockAccessibility()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        tintOverlay.wantsLayer = true
        addSubview(tintOverlay)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func apply(_ style: DockAppearance, accessibility: DockAccessibility) {
        self.style = style.normalized
        preferences = accessibility
        needsLayout = true
        updateSurface()
    }
    override func layout() {
        super.layout()
        effect.frame = bounds
        tintOverlay.frame = bounds
        updateSurface()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurface()
    }
    private func updateSurface() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer?.cornerRadius = min(style.cornerRadius, min(bounds.width, bounds.height) / 2)
        effect.isHidden = preferences.reduceTransparency
        effect.alphaValue = preferences.surfaceOpacity(for: style)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = preferences.reduceTransparency ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
            let color: NSColor = switch style.backgroundColor {
            case .material: .clear
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .pink: .systemPink
            case .green: .systemGreen
            case .orange: .systemOrange
            case .graphite: .gray
            case .black: .black
            case .white: .white
            }
            tintOverlay.layer?.backgroundColor = color.withAlphaComponent(style.backgroundColor == .material ? 0 : style.backgroundTintStrength * preferences.surfaceOpacity(for: style)).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(preferences.increaseContrast ? 0.65 : 0.16).cgColor
        }
        layer?.borderWidth = preferences.increaseContrast ? 1.5 : 1 / (window?.backingScaleFactor ?? 2)
    }
    // This is a background, so controls and the parent drop destination receive all events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Native dynamic colors adapt to each dock's appearance and the system accent.
extension DockBackgroundColor {
    @MainActor var revealTabColor: NSColor {
        switch self {
        case .material: .windowBackgroundColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .green: .systemGreen
        case .orange: .systemOrange
        case .graphite: .gray
        case .black: .black
        case .white: .white
        }
    }
}
