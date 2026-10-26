import AppKit

@MainActor
struct PolishSmoke {
    static func run() async throws {
        let apps = ApplicationService()
        defer { apps.activity.shutdown() }
        var configuration = DockConfiguration(name: "Polish", position: DockPosition(x: 300, y: 300), applications: TestApplications.installed(),
            behavior: DockBehavior(magnificationEnabled: true, autoHideEnabled: true, autoHideDelay: 0.2, visibilityDuration: 0.05))
        let owner = DockWindowController(configuration: configuration)
        defer { owner.dispose() }
        owner.update(configuration: configuration, applications: apps, launch: { _ in }, accessibility: DockAccessibility(reduceMotion: false))
        owner.show()
        let host = owner.window!.contentView as! DockDropHostingView
        host.layoutSubtreeIfNeeded()
        let button = host.applicationButtons[0]
        let frame = button.convert(button.bounds, to: nil)
        let originalFrame = owner.window!.frame
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: CGPoint(x: frame.midX, y: frame.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.window!.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: CGPoint(x: frame.midX, y: frame.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.window!.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        // Exercise the real icon tracking callbacks without invoking the outer host's pointer handler.
        button.mouseEntered(with: entered)
        precondition(owner.interactions.nameLabel.text == configuration.applications[0].name)
        precondition(owner.interactions.nameLabel.panel?.isVisible == true)
        owner.interactions.beginInteraction()
        precondition(owner.interactions.nameLabel.panel?.isVisible == false)
        owner.interactions.endInteraction()
        precondition(owner.interactions.nameLabel.panel?.isVisible == true)
        // A layout-generated exit with the pointer still inside must not dismiss its name.
        button.mouseExited(with: exited)
        precondition(owner.interactions.nameLabel.text == configuration.applications[0].name)
        precondition(host.applicationButtons.filter(\.isHovered).count == 1)
        let second = host.applicationButtons[1]
        let secondRect = host.iconStrip!.targetWindowRect(for: second)!
        let secondPoint = CGPoint(x: secondRect.midX, y: secondRect.midY)
        func trackingEvent(_ type: NSEvent.EventType, point: CGPoint) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: owner.window!.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)!
        }
        second.mouseEntered(with: trackingEvent(.mouseEntered, point: secondPoint))
        precondition(owner.interactions.nameLabel.text == configuration.applications[1].name)
        // An older exit must not overwrite the later pointer position.
        button.mouseExited(with: exited)
        precondition(owner.interactions.nameLabel.text == configuration.applications[1].name)
        let stableLabelFrame = owner.interactions.nameLabel.panel!.frame
        for index in 0..<40 {
            let source = index.isMultiple(of: 2) ? button : second
            source.mouseEntered(with: trackingEvent(.mouseEntered, point: secondPoint))
            source.mouseExited(with: trackingEvent(.mouseExited, point: secondPoint))
            precondition(owner.interactions.nameLabel.text == configuration.applications[1].name)
            precondition(host.applicationButtons.filter(\.isHovered).count == 1 && second.isHovered && !button.isHovered)
            precondition(owner.interactions.nameLabel.panel!.frame == stableLabelFrame)
        }
        second.mouseExited(with: trackingEvent(.mouseExited, point: CGPoint(x: -40, y: -40)))
        precondition(owner.interactions.nameLabel.panel?.isVisible == false)
        precondition(host.applicationButtons.allSatisfy { !$0.isHovered })
        owner.interactions.pointerChanged(nil)
        let management = host.subviews.flatMap { descendants($0) }.filter {
            String(describing: type(of: $0)) == "DragHandleView"
        }
        precondition(!management.isEmpty && management.allSatisfy(\.isHidden))
        owner.interactions.pointerChanged(CGPoint(x: frame.midX, y: frame.midY))
        precondition(management.allSatisfy { !$0.isHidden })
        precondition(button.magnification > 1.4 && owner.window!.frame == originalFrame)
        precondition(owner.interactions.nameLabel.text == configuration.applications[0].name)
        precondition(owner.interactions.nameLabel.panel?.isVisible == true)
        precondition(owner.interactions.nameLabel.panel?.canBecomeKey == false)
        precondition(owner.interactions.nameLabel.panel?.ignoresMouseEvents == true)
        try await Task.sleep(for: .milliseconds(180))
        if let directory = ProcessInfo.processInfo.environment["MULTIDOCK_DOCK_SNAPSHOTS"] {
            for (name, view) in [("magnification-wave", host as NSView), ("app-name-label", owner.interactions.nameLabel.panel!.contentView!)] {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
                }
            }
        }
        let clickFrame = button.frame
        let clickScale = button.magnification
        owner.interactions.beginInteraction()
        owner.interactions.pointerChanged(nil)
        precondition(button.frame == clickFrame && button.magnification == clickScale,
                     "A click or drag hold must freeze magnified hit targets")
        owner.interactions.endInteraction()
        owner.interactions.pointerChanged(nil)
        precondition(owner.interactions.nameLabel.panel?.isVisible == false)
        button.applyActivity(running: true, state: .launching)
        precondition(button.isLaunchAnimating)
        button.applyActivity(running: true, state: .succeeded)
        precondition(button.isLaunchAnimating, "Fast launches must not truncate their finite bounce")
        button.reduceMotion = true
        precondition(!button.isLaunchAnimating)
        button.applyActivity(running: true, state: .idle)
        button.applyActivity(running: true, state: .launching)
        precondition(!button.isLaunchAnimating)
        // Management actions remain reachable without occupying icon-tray space.
        var settingsRequests = 0
        let options = dockOptionsMenu(actions: DockActions(settings: { settingsRequests += 1 }))
        precondition(options.items.map(\.title) == ["Lock Position", "Settings…"])
        let command = options.items[1]
        NSApp.sendAction(command.action!, to: command.target, from: command)
        precondition(settingsRequests == 1)
        for state in [DockLaunchState.idle, .launching, .succeeded, .failed] {
            button.applyActivity(running: true, state: state)
            precondition(button.applicationName == configuration.applications[0].name && button.toolTip == nil)
        }
        precondition(descendants(host).compactMap { $0 as? NSButton }.count == configuration.applications.count, "The tray must contain only application buttons")
        if let directory = ProcessInfo.processInfo.environment["MULTIDOCK_DOCK_SNAPSHOTS"] {
            for orientation in [DockOrientation.horizontal, .vertical] {
                configuration.orientation = orientation
                configuration.behavior = DockBehavior()
                owner.update(configuration: configuration, applications: apps, launch: { _ in }, accessibility: DockAccessibility(reduceTransparency: true))
                host.layoutSubtreeIfNeeded()
                owner.interactions.pointerChanged(nil)
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Missing tray snapshot") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("Unable to encode tray snapshot") }
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("compact-\(orientation.rawValue).png"))
            }
        }
        let original = apps.icon(for: configuration.applications[0])
        var rectangle = CGRect(x: 0, y: 0, width: 64, height: 64)
        let pixels = original.cgImage(forProposedRect: &rectangle, context: nil, hints: nil)!
        precondition(IconThemeRenderer.render(pixels, theme: .original, tint: .blue) === pixels)
        for theme in [DockIconTheme.monochrome, .tinted] {
            let result = IconThemeRenderer.render(pixels, theme: theme, tint: .purple)
            precondition(result.width == pixels.width && result.height == pixels.height)
            let bitmap = NSBitmapImageRep(cgImage: result)
            if theme == .monochrome {
                let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                precondition(abs(color.redComponent - color.greenComponent) < 0.02 && abs(color.greenComponent - color.blueComponent) < 0.02)
            }
        }
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let source = context.makeImage()!
        let gray = NSBitmapImageRep(cgImage: IconThemeRenderer.render(source, theme: .monochrome, tint: .accent)).colorAt(x: 2, y: 2)!.usingColorSpace(.deviceRGB)!
        precondition(abs(gray.redComponent - gray.greenComponent) < 0.02 && abs(gray.greenComponent - gray.blueComponent) < 0.02)
        precondition(abs(gray.alphaComponent - 0.5) < 0.02)
        let blue = NSBitmapImageRep(cgImage: IconThemeRenderer.render(source, theme: .tinted, tint: .blue)).colorAt(x: 2, y: 2)!.usingColorSpace(.deviceRGB)!
        precondition(blue.blueComponent > blue.redComponent && abs(blue.alphaComponent - 0.5) < 0.02)
        configuration.appearance.iconTheme = .tinted
        configuration.appearance.iconTint = .purple
        owner.update(configuration: configuration, applications: apps, launch: { _ in })
        host.layoutSubtreeIfNeeded()
        precondition(host.applicationButtons.allSatisfy { $0.iconTheme == .tinted && $0.iconTint == .purple })
        configuration.appearance.backgroundColor = .blue
        configuration.appearance.backgroundTintStrength = 0.7
        owner.update(configuration: configuration, applications: apps, launch: { _ in }, accessibility: DockAccessibility(reduceTransparency: true))
        host.layoutSubtreeIfNeeded()
        let surface = descendants(host).compactMap { $0 as? DockSurface }.first!
        precondition(surface.style.backgroundColor == .blue)
        precondition(abs((surface.tintOverlay.layer?.backgroundColor?.alpha ?? 0) - 0.7) < 0.001)
        precondition(surface.effect.isHidden && surface.layer?.backgroundColor?.alpha == 1)
        if let directory = ProcessInfo.processInfo.environment["MULTIDOCK_DOCK_SNAPSHOTS"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("blue-background.png"))
        }
        let permissionDenied = ApplicationWindowService(permissionCheck: { false })
        do { try await permissionDenied.perform(bundleIdentifier: "com.apple.finder", minimized: true); preconditionFailure("Access must gate AX operations") }
        catch WindowCommandError.permission {} // This never prompts or reads another application's windows.

        let manager = DockManager()
        defer { manager.shutdown() }
        manager.createDock()
        let dock = manager.configurations[0]
        precondition(!dock.behavior.autoHideEnabled && dock.behavior.magnificationEnabled)
        precondition(dock.applications.isEmpty)
        try await Task.sleep(for: .milliseconds(900))
        let emptyPanel = NSApp.windows.first { ($0.contentView as? DockDropHostingView)?.configuration.id == dock.id }!
        precondition(emptyPanel.isVisible, "An empty first dock remains visible so users can add apps")
        manager.setBehavior(DockBehavior(), in: dock.id)
        manager.useDockStyleInteractions()
        precondition(manager.configurations[0].behavior.autoHideEnabled && manager.configurations[0].behavior.magnificationEnabled)
        print("PASS: single hover owner, stale event rejection, 80 moving-boundary callbacks without name flicker, exit cleanup, Settings-only management, immediate nonactivating app-name label, moving magnification wave, background color, finite launch bounce, Reduce Motion cancellation, original/monochrome/tinted icon rendering, AX denial without prompts, new dock defaults and one-click existing dock setup")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
