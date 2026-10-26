import AppKit

@MainActor
final class ApplicationService {
    let activity: ApplicationActivityService
    private let workspace: NSWorkspace
    private var icons: [String: NSImage] = [:]

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        activity = ApplicationActivityService(workspace: workspace)
    }

    func item(at input: URL) throws -> ApplicationItem {
        let application = try ApplicationLocation.validate(input)
        // A plain bookmark follows moved files. No security-scoped permission is requested.
        let bookmark = try application.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ApplicationItem(bundleIdentifier: application.bundleIdentifier, name: application.name,
                               location: application.url, bookmark: bookmark)
    }

    func resolvedURL(for item: ApplicationItem) throws -> URL {
        var candidates: [URL] = []
        if let bookmark = item.bookmark {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                candidates.append(url)
            } catch {
                // A stale bookmark must not prevent fallback to the saved URL or Launch Services.
            }
        }
        if let location = item.location { candidates.append(location) }
        if let registered = workspace.urlForApplication(withBundleIdentifier: item.bundleIdentifier) { candidates.append(registered) }
        for url in candidates {
            do {
                let application = try ApplicationLocation.validate(url)
                if application.bundleIdentifier == item.bundleIdentifier { return application.url }
            } catch {
                // Try the remaining recorded locations before reporting a useful final error.
            }
        }
        throw ApplicationError.notInstalled(item.name)
    }

    func folderItem(at input: URL) throws -> DockItem {
        let url = try FolderReference.validate(input)
        return DockItem(bundleIdentifier: "org.multidock.folder.\(UUID().uuidString)", name: FileManager.default.displayName(atPath: url.path),
            location: url, bookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), kind: .folder)
    }

    func icon(for item: ApplicationItem) -> NSImage {
        if item.kind == .stack {
            return NSImage(systemSymbolName: item.stackSymbol, accessibilityDescription: item.name)!
        }
        if item.kind == .folder {
            guard let url = try? FolderReference.resolve(item) else {
                return NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: "Folder unavailable")!
            }
            if let image = icons[url.path] { return image }
            if icons.count >= 256 { icons.removeAll() }
            let image = workspace.icon(forFile: url.path); icons[url.path] = image; return image
        }
        guard let url = try? resolvedURL(for: item) else {
            return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "\(item.name) unavailable")!
        }
        if let image = icons[url.path] { return image }
        if icons.count >= 256 { icons.removeAll() }
        let image = workspace.icon(forFile: url.path)
        icons[url.path] = image
        return image
    }

    func reveal(_ item: ApplicationItem) throws {
        workspace.activateFileViewerSelecting([try resolvedURL(for: item)])
    }

    func launch(_ item: ApplicationItem) async throws {
        // Opening the resolved bundle also activates an existing instance. Avoid a new instance.
        guard activity.launchState(item.id) != .launching else { return }
        activity.setLaunchState(.launching, for: item.id)
        do {
            let url = try resolvedURL(for: item)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            _ = try await workspace.openApplication(at: url, configuration: configuration)
            activity.setLaunchState(.succeeded, for: item.id)
        } catch {
            activity.setLaunchState(.failed, for: item.id)
            throw error
        }
    }

    func quit(_ item: ApplicationItem) throws {
        // Request normal termination so the app can save documents or let the user cancel.
        // Never force-terminate, launch a stopped app, or require Accessibility access.
        let instances = workspace.runningApplications.filter {
            $0.bundleIdentifier == item.bundleIdentifier && !$0.isTerminated
        }
        var rejected = false
        for instance in instances {
            if !instance.terminate() && !instance.isTerminated { rejected = true }
        }
        if rejected { throw ApplicationError.quitRejected(item.name) }
    }

    func canOpen(_ urls: [URL], with item: DockItem) -> Bool {
        guard item.kind == .application, DockFileDropClassifier.classify(urls) == .documents,
              let app = try? resolvedURL(for: item) else { return false }
        let declarations = ApplicationDocumentSupport.declarations(at: app)
        return urls.allSatisfy { url in
            workspace.urlsForApplications(toOpen: url).contains { Bundle(url: $0)?.bundleIdentifier == item.bundleIdentifier }
                || ApplicationDocumentSupport.supports(url, declarations: declarations)
        }
    }
    func open(_ urls: [URL], with item: DockItem) async throws {
        guard canOpen(urls, with: item) else { throw ApplicationError.unsupportedDocuments(item.name) }
        let app = try resolvedURL(for: item)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        _ = try await workspace.open(urls, withApplicationAt: app, configuration: configuration)
    }

    func trimIconCache() { icons.removeAll() }
}

enum ApplicationError: LocalizedError {
    case notInstalled(String)
    case quitRejected(String)
    case unsupportedDocuments(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedDocuments(let name): "These files could not be opened with \(name). Check that they still exist and are readable, and that macOS lists this application as compatible. Select at most 256 items at once. You can also use the application’s Open command."
        case .quitRejected(let name): "\(name) did not accept the quit request. Finish any open dialogs or save your work, then try again. You can also quit from the application's own menu."
        case .notInstalled(let name): "\(name) could not be found or opened. It may have been deleted, replaced, or be on an inaccessible volume. Reconnect its volume or remove this entry and add the application again."
        }
    }
}

actor FolderListingWorker {
    static let shared = FolderListingWorker()
    func contents(_ item: DockItem) throws -> [URL] { try FolderReference.contents(item) }
}
