import AppKit
import SwiftUI

@MainActor
final class WindowPreviewModel: ObservableObject {
    @Published var title = "Windows"
    @Published var message = "Loading windows…"
    @Published var rows: [WindowPreview] = []
    @Published var needsScreenAccess = false
    @Published var needsAccessibility = false
    @Published var selecting = false
    var openApplication: () -> Void = {}
    var select: (PreviewWindowDescriptor) -> Void = { _ in }
    var requestScreen: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var close: () -> Void = {}

    func clear() {
        rows.removeAll()
        openApplication = {}; select = { _ in }; requestScreen = {}; requestAccessibility = {}; close = {}
    }
}

struct WindowPreviewView: View {
    @ObservedObject var model: WindowPreviewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.title).font(.headline).lineLimit(1)
                Spacer()
                Button(action: model.close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close previews")
                    .accessibilityLabel("Close previews")
            }
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if model.needsScreenAccess {
                Text("MultiDock takes temporary window snapshots only while this popover is open. Images stay in memory, are never saved, and never leave your Mac. macOS may require you to reopen MultiDock after granting access.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("Request Screen Recording Access…", action: model.requestScreen)
            }
            if model.needsAccessibility {
                Text("To select a particular window, MultiDock needs Accessibility access to read its title and frame and ask the application to raise it. Open Application works without this permission.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("Request Accessibility Access…", action: model.requestAccessibility)
            }
            if !model.rows.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.rows) { row in
                            Button { model.select(row.window) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    if let image = row.image {
                                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                            .frame(maxWidth: .infinity).frame(height: 130)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    Text(row.window.title.isEmpty ? "Untitled window" : row.window.title).lineLimit(2)
                                    if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.bordered).disabled(model.selecting)
                                .accessibilityLabel("Select \(row.window.title.isEmpty ? "untitled window" : row.window.title)")
                        }
                    }
                }.frame(height: min(330, CGFloat(model.rows.count) * 205))
            }
            HStack {
                Button("Open Application", action: model.openApplication)
                Spacer()
                if model.selecting { ProgressView().controlSize(.small) }
            }
        }.padding(14).frame(width: 290)
    }
}

/// Native tracking holds the popover open while crossing from the icon into its content.
@MainActor
final class PreviewHostingView: NSHostingView<WindowPreviewView> {
    var hoverChanged: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hoverChanged(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged(false) }
}

struct StackPopoverContent: View {
    @ObservedObject var manager: DockManager
    let dockID: UUID
    let fallback: DockItem
    @State private var folderURLs: [URL] = []
    @State private var folderError: String?
    private var item: DockItem {
        manager.configurations.first { $0.id == dockID }?.applications.first { $0.id == fallback.id } ?? fallback
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name.isEmpty ? "Untitled Stack" : item.name).font(.headline).lineLimit(2)
            if item.kind == .folder {
                Button("Open Folder in Finder") { manager.openFolder(item) }
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(folderURLs, id: \.self) { url in
                            Button(url.lastPathComponent) { manager.openFolderEntry(url) }.lineLimit(1)
                        }
                        if let folderError { Text(folderError).foregroundStyle(.secondary) }
                        else if folderURLs.isEmpty { Text("No visible items.").foregroundStyle(.secondary) }
                    }
                }
                Text("Up to 100 direct items. Files are opened with their default apps; nothing is moved or deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView { StackItemList(manager: manager, dockID: dockID, stackID: item.id) }
                Button("Add Applications…") { manager.addApplications(to: dockID, stackID: item.id) }
                StackDropZone(actions: manager.stackActions(dockID: dockID, stackID: item.id)).frame(height: 34)
            }
        }.padding(14)
        .task(id: item.id) {
            guard item.kind == .folder else { return }
            do { folderURLs = try await FolderListingWorker.shared.contents(item) }
            catch { folderError = "Folder unavailable: \(error.localizedDescription)" }
        }
    }
}

struct StackItemList: View {
    @ObservedObject var manager: DockManager
    let dockID: UUID
    let stackID: UUID
    private var dock: DockConfiguration? { manager.configurations.first { $0.id == dockID } }
    private var entries: [DockItem] { dock?.applications.first { $0.id == stackID }?.children ?? [] }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty { Text("Empty stack. Add or drag applications here.").foregroundStyle(.secondary) }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                if var configuration = dock {
                    let _ = configuration.behavior.magnificationEnabled = false
                    let _ = configuration.behavior.windowPreviewsEnabled = false
                    HStack(spacing: 6) {
                        ApplicationIcon(item: item, configuration: configuration, image: manager.applicationIcon(item),
                            actions: manager.stackActions(dockID: dockID, stackID: stackID),
                            launch: { manager.launchFromStack(item, in: dockID) }, close: {},
                            running: manager.applicationIsRunning(item), launchState: manager.applicationLaunchState(item))
                            .frame(width: 40, height: 40)
                        Button(item.name) { manager.launchFromStack(item, in: dockID) }.buttonStyle(.plain).lineLimit(1)
                        Spacer(minLength: 0)
                        DockItemTransferMenu(manager: manager, drag: DockItemDrag(dockID: dockID, itemID: item.id, stackID: stackID))
                        Button { manager.moveStackItem(item.id, stackID: stackID, in: dockID, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).accessibilityLabel("Move \(item.name) earlier")
                        Button { manager.moveStackItem(item.id, stackID: stackID, in: dockID, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == entries.count - 1).accessibilityLabel("Move \(item.name) later")
                        Button { manager.removeApplication(item.id, from: dockID, stackID: stackID) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove \(item.name) from stack")
                    }
                }
            }
        }
    }
}

struct DockItemTransferMenu: View {
    @ObservedObject var manager: DockManager
    let drag: DockItemDrag
    var body: some View {
        Menu {
            ForEach([false, true], id: \.self) { copy in
                Menu(copy ? "Copy to" : "Move to") {
                    ForEach(manager.configurations) { dock in
                        Button("\(dock.name) dock") { manager.transferFromMenu(drag, to: dock.id, copy: copy) }
                        ForEach(dock.applications.filter { $0.kind == .stack }) { stack in
                            Button("\(dock.name) / \(stack.name)") { manager.transferFromMenu(drag, to: dock.id, stackID: stack.id, copy: copy) }
                        }
                    }
                }
            }
        } label: { Image(systemName: "arrow.turn.down.right") }
        .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Move or copy application")
    }
}

struct StackDropZone: NSViewRepresentable {
    let actions: DockActions
    func makeNSView(context: Context) -> StackDropZoneView { StackDropZoneView() }
    func updateNSView(_ view: StackDropZoneView, context: Context) { view.actions = actions }
}
@MainActor
final class StackDropZoneView: NSView {
    var actions = DockActions()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, ApplicationIconButton.pasteboardType])
        setAccessibilityElement(true); setAccessibilityLabel("Drop applications into stack")
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        ("Drop apps here" as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)])
    }
    private var validDrop = false
    private var internalSource = false
    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard validDrop else { return [] }
        if internalSource && sender.draggingSourceOperationMask.contains(.move) { return .move }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        internalSource = sender.draggingSource is ApplicationIconButton
        if let source = sender.draggingSource as? ApplicationIconButton {
            validDrop = source.entryKind == .application && source.drag != nil
        } else {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            validDrop = !urls.isEmpty && urls.allSatisfy { (try? ApplicationLocation.validate($0)) != nil }
        }
        return operation(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !operation(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let source = sender.draggingSource as? ApplicationIconButton
        let drag = source.flatMap { _ in sender.draggingPasteboard.data(forType: ApplicationIconButton.pasteboardType) }
            .flatMap { try? JSONDecoder().decode(DockItemDrag.self, from: $0) }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return actions.drop(drag, urls, Int.max, source == nil || !sender.draggingSourceOperationMask.contains(.move))
    }
}
