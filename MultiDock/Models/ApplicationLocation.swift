import Foundation
import UniformTypeIdentifiers

struct ValidatedApplication: Sendable {
    let url: URL
    let bundleIdentifier: String
    let name: String
}

enum ApplicationLocationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let name): "\(name) is not an accessible macOS application. Select an installed .app bundle or an alias to one. Check that its volume is mounted and that you have read and execute access."
        }
    }
}

/// Filesystem validation is independent of AppKit and Launch Services for unit tests.
enum ApplicationLocation {
    static func validate(_ input: URL) throws -> ValidatedApplication {
        guard input.isFileURL else { throw ApplicationLocationError.invalid(input.lastPathComponent) }
        let url = try URL(resolvingAliasFileAt: input, options: [.withoutUI, .withoutMounting])
            .resolvingSymlinksInPath().standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard url.pathExtension.lowercased() == "app", values.isDirectory == true, values.isReadable == true else {
            throw ApplicationLocationError.invalid(input.lastPathComponent)
        }
        // Read current metadata rather than NSBundle's cached dictionary: the app may have been replaced.
        let info = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let metadata = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let identifier = metadata["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let packageType = metadata["CFBundlePackageType"] as? String,
              // Finder uses Apple's FNDR package type rather than APPL.
              (packageType == "APPL" || (packageType == "FNDR" && identifier == "com.apple.finder")),
              let executableName = metadata["CFBundleExecutable"] as? String, !executableName.isEmpty,
              executableName == (executableName as NSString).lastPathComponent else {
            throw ApplicationLocationError.invalid(input.lastPathComponent)
        }
        let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        let executableValues = try executable.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
        guard executableValues.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: executable.path),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ApplicationLocationError.invalid(input.lastPathComponent)
        }
        return ValidatedApplication(url: url, bundleIdentifier: identifier,
                                    name: FileManager.default.displayName(atPath: url.path))
    }
}

enum FolderReference {
    static func validate(_ input: URL) throws -> URL {
        guard input.isFileURL else { throw ApplicationLocationError.invalid(input.lastPathComponent) }
        let url = try URL(resolvingAliasFileAt: input, options: [.withoutUI, .withoutMounting]).resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isPackageKey])
        guard values.isDirectory == true, values.isReadable == true, values.isPackage != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return url
    }
    static func resolve(_ item: DockItem) throws -> URL {
        if let bookmark = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               let valid = try? validate(url) { return valid }
        }
        guard let url = item.location else { throw CocoaError(.fileNoSuchFile) }
        return try validate(url)
    }
    static func contents(_ item: DockItem) throws -> [URL] {
        let url = try resolve(item)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isReadableKey],
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants, .skipsHiddenFiles]) else { throw CocoaError(.fileReadNoPermission) }
        var result: [URL] = []
        for case let entry as URL in enumerator {
            result.append(entry)
            if result.count == 100 { break }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

enum DockFileDropKind: Equatable { case applications, documents, invalid }
enum DockFileDropClassifier {
    static func classify(_ urls: [URL]) -> DockFileDropKind {
        guard !urls.isEmpty, urls.count <= 256 else { return .invalid }
        var appCount = 0
        for input in urls {
            guard input.isFileURL,
                  let url = try? URL(resolvingAliasFileAt: input, options: [.withoutUI, .withoutMounting]).resolvingSymlinksInPath(),
                  FileManager.default.isReadableFile(atPath: url.path) else { return .invalid }
            if url.pathExtension.lowercased() == "app" {
                guard (try? ApplicationLocation.validate(url)) != nil else { return .invalid }
                appCount += 1
            }
        }
        if appCount == urls.count { return .applications }
        return appCount == 0 ? .documents : .invalid
    }
}

/// Launch Services may not have indexed a newly installed bundle yet. Its documented
/// document-type declarations provide a local fallback, never a forced open override.
enum ApplicationDocumentSupport {
    static func declarations(at application: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    }
    static func supports(_ url: URL, declarations: [[String: Any]]) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]) else { return false }
        let type = values.isDirectory == true ? UTType.folder : (values.contentType ?? UTType(filenameExtension: url.pathExtension))
        return declarations.contains { declaration in
            if let role = declaration["CFBundleTypeRole"] as? String, role == "None" { return false }
            if let identifiers = declaration["LSItemContentTypes"] as? [String], let type,
               identifiers.contains(where: { UTType($0).map { type.conforms(to: $0) } ?? false }) { return true }
            if let extensions = declaration["CFBundleTypeExtensions"] as? [String], values.isDirectory != true {
                return extensions.contains("*") || extensions.contains { $0.lowercased() == url.pathExtension.lowercased() }
            }
            return false
        }
    }
}
