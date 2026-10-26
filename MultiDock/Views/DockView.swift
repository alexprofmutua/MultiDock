import AppKit
import SwiftUI

struct DockView: View {
    let configuration: DockConfiguration
    let applications: ApplicationService
    let launch: @MainActor (ApplicationItem) -> Void
    let close: @MainActor () -> Void
    var actions = DockActions()
    var maximumLength: CGFloat = .greatestFiniteMagnitude
    var accessibility = DockAccessibility()

    private var metrics: DockMetrics { DockMetrics(configuration.appearance, behavior: configuration.behavior) }
    private var viewportLength: CGFloat {
        let size = DockLayout.size(for: configuration, maximumLength: maximumLength)
        return (configuration.orientation == .horizontal ? size.width : size.height) - metrics.overhead
    }

    var body: some View {
        Group {
            if configuration.orientation == .horizontal {
                HStack(spacing: metrics.spacing) { contents }
            } else {
                VStack(spacing: metrics.spacing) { contents }
            }
        }
        .padding(metrics.padding)
        .background(DockBackground(appearance: configuration.appearance, accessibility: accessibility))
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder private var icons: some View {
        if configuration.applications.isEmpty {
            Text("Drop apps here").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: configuration.orientation == .horizontal ? metrics.emptyLength : metrics.itemSide,
                       height: configuration.orientation == .horizontal ? metrics.itemSide : metrics.emptyLength)
        } else {
            DockIconStrip(configuration: configuration, applications: applications, actions: actions,
                          launch: launch, close: close, accessibility: accessibility)
                .frame(width: configuration.orientation == .horizontal ? DockLayout.contentLength(for: configuration) : metrics.itemSide,
                       height: configuration.orientation == .horizontal ? metrics.itemSide : DockLayout.contentLength(for: configuration))
        }
    }

    @ViewBuilder private var contents: some View {
        DockDragHandle()
            .frame(width: configuration.orientation == .horizontal ? metrics.gripSide : metrics.itemSide,
                   height: configuration.orientation == .horizontal ? metrics.itemSide : metrics.gripSide)
        if configuration.orientation == .horizontal {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: metrics.spacing) { icons } }
                .frame(width: viewportLength, height: metrics.itemSide)
        } else {
            ScrollView(.vertical, showsIndicators: false) { VStack(spacing: metrics.spacing) { icons } }
                .frame(width: metrics.itemSide, height: viewportLength)
        }
    }
}

/// AppKit owns moving hit targets, tracking areas and neighboring icon frames inside SwiftUI's scroll view.
private struct DockIconStrip: NSViewRepresentable {
    let configuration: DockConfiguration
    let applications: ApplicationService
    let actions: DockActions
    let launch: @MainActor (ApplicationItem) -> Void
    let close: @MainActor () -> Void
    let accessibility: DockAccessibility
    func makeNSView(context: Context) -> DockIconStripView { DockIconStripView() }
    func updateNSView(_ view: DockIconStripView, context: Context) {
        view.configure(configuration: configuration, applications: applications, actions: actions,
                       launch: launch, close: close, accessibility: accessibility)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DockIconStripView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

@MainActor
final class DockIconStripView: NSView {
    override var isFlipped: Bool { true }
    private(set) var buttons: [ApplicationIconButton] = []
    private var configuration: DockConfiguration?
    private var accessibility = DockAccessibility()
    private var pointer: CGPoint?
    private(set) var targetPlacements: [DockIconPlacement] = []

    func configure(configuration: DockConfiguration, applications: ApplicationService, actions: DockActions,
                   launch: @escaping @MainActor (ApplicationItem) -> Void, close: @escaping @MainActor () -> Void,
                   accessibility: DockAccessibility) {
        self.configuration = configuration
        self.accessibility = accessibility
        let existing = Dictionary(uniqueKeysWithValues: buttons.compactMap { button in button.itemID.map { ($0, button) } })
        let ids = Set(configuration.applications.map(\.id))
        for button in buttons where !ids.contains(button.itemID ?? UUID()) { button.removeFromSuperview() }
        buttons = configuration.applications.map { item in
            let button = existing[item.id] ?? ApplicationIconButton()
            if button.superview == nil { addSubview(button) }
            ApplicationIcon(item: item, configuration: configuration, image: applications.icon(for: item), actions: actions,
                launch: { launch(item) }, close: close, accessibility: accessibility,
                running: applications.activity.isRunning(item.bundleIdentifier), launchState: applications.activity.launchState(item.id)).configure(button)
            return button
        }
        needsLayout = true
    }
    override func layout() { super.layout(); applyLayout(animated: false) }
    func updatePointer(_ windowPoint: CGPoint?) {
        pointer = windowPoint
        applyLayout(animated: true)
    }
    func targetButton(at windowPoint: CGPoint) -> ApplicationIconButton? {
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point) else { return nil }
        guard let index = targetPlacements.firstIndex(where: { $0.frame.contains(point) }), buttons.indices.contains(index) else { return nil }
        return buttons[index]
    }
    func targetWindowRect(for button: ApplicationIconButton) -> CGRect? {
        guard let index = buttons.firstIndex(where: { $0 === button }), targetPlacements.indices.contains(index) else { return nil }
        return convert(targetPlacements[index].frame, to: nil)
    }
    private func applyLayout(animated: Bool) {
        guard let configuration else { return }
        let placements = DockMagnificationLayout.placements(count: buttons.count, bounds: bounds, pointer: pointer.map { convert($0, from: nil) },
            orientation: configuration.orientation, appearance: configuration.appearance,
            behavior: configuration.behavior, reduceMotion: accessibility.reduceMotion)
        targetPlacements = placements
        let duration = animated && !accessibility.reduceMotion ? configuration.behavior.normalized.magnificationDuration : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (button, placement) in zip(buttons, placements) {
                if button.frame != placement.frame {
                    if duration > 0 { button.animator().frame = placement.frame }
                    else { button.frame = placement.frame }
                }
                button.setMagnification(placement.scale, duration: duration)
                button.layoutSubtreeIfNeeded()
            }
        }
    }
}
