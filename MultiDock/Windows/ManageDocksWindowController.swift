import AppKit
import SwiftUI

@MainActor
final class ManageDocksWindowController: NSWindowController {
    init(manager: DockManager) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MultiDock Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ManageDocksView(manager: manager))
        window.minSize = NSSize(width: 820, height: 600)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use init(manager:)") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
