import AppKit

/// Installed examples belong only to test fixtures; production docks always start empty.
@MainActor
enum TestApplications {
    static func installed() -> [ApplicationItem] {
        ["com.apple.finder", "com.apple.Safari", "com.apple.TextEdit"].compactMap { identifier in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            return ApplicationItem(bundleIdentifier: identifier, name: FileManager.default.displayName(atPath: url.path), location: url)
        }
    }
}
