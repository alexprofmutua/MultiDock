import Foundation

/// Serial disk access with revision checks so an older debounce cannot overwrite a final flush.
actor DockStore {
    struct Document: Codable {
        var version = DockArchive.currentVersion
        let docks: [DockConfiguration]
        var globalPositionLocked = false
        var globalRevealStyle = DockRevealStyle()
        enum CodingKeys: String, CodingKey { case version, docks, globalRevealStyle, globalPositionLocked }
        init(version: Int = DockArchive.currentVersion, docks: [DockConfiguration], globalRevealStyle: DockRevealStyle = DockRevealStyle(), globalPositionLocked: Bool = false) {
            self.globalPositionLocked = globalPositionLocked
            self.version = version
            self.docks = docks
            self.globalRevealStyle = globalRevealStyle
        }
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            globalPositionLocked = try fields.decodeIfPresent(Bool.self, forKey: .globalPositionLocked) ?? false
            version = try fields.decode(Int.self, forKey: .version)
            docks = try fields.decode([DockConfiguration].self, forKey: .docks)
            globalRevealStyle = try fields.decodeIfPresent(DockRevealStyle.self, forKey: .globalRevealStyle) ?? DockRevealStyle()
        }
    }
    enum StoreError: LocalizedError {
        case unsupportedVersion, duplicateIdentifiers, invalidStack
        var errorDescription: String? {
            switch self {
            case .invalidStack: "Stacks may contain applications only, with no nested groups."
            case .unsupportedVersion: "This saved dock file uses an unsupported format."
            case .duplicateIdentifiers: "The saved dock file contains repeated dock or entry identifiers."
            }
        }
    }
    nonisolated let url: URL
    private var lastRevision: UInt64 = 0
    private var lastSavedPositionLocked: Bool?
    private var lastSavedRevealStyle: DockRevealStyle?
    private var lastSavedDocks: [DockConfiguration]?
    private(set) var writeCount = 0

    struct LoadResult: Sendable {
        let docks: [DockConfiguration]?
        let globalRevealStyle: DockRevealStyle
        let globalPositionLocked: Bool
        let notices: [String]
        let backupURL: URL?
    }

    func loadRecovering() throws -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadResult(docks: nil, globalRevealStyle: DockRevealStyle(), globalPositionLocked: false, notices: [], backupURL: nil)
        }
        let data = try Data(contentsOf: url)
        let recovery = try DockArchive.recover(data)
        var backup: URL?
        if recovery.needsRewrite {
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("docks-backup-\(UUID().uuidString).json")
            // A failed backup stops restoration from overwriting recoverable input.
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            backup = destination
        } else { lastSavedDocks = recovery.docks; lastSavedRevealStyle = recovery.globalRevealStyle; lastSavedPositionLocked = recovery.globalPositionLocked }
        return LoadResult(docks: recovery.docks, globalRevealStyle: recovery.globalRevealStyle, globalPositionLocked: recovery.globalPositionLocked, notices: recovery.notices, backupURL: backup)
    }

    init(url: URL) { self.url = url }
    nonisolated static var standard: DockStore {
        DockStore(url: URL.applicationSupportDirectory.appendingPathComponent("org.multidock.MultiDock", isDirectory: true)
            .appendingPathComponent("docks.json"))
    }

    func load() throws -> [DockConfiguration]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
        guard (1...DockArchive.currentVersion).contains(document.version) else { throw StoreError.unsupportedVersion }
        guard Set(document.docks.map(\.id)).count == document.docks.count,
              document.docks.allSatisfy({ Set($0.allEntries.map(\.id)).count == $0.allEntries.count }) else {
            throw StoreError.duplicateIdentifiers
        }
        return document.docks
    }

    func save(_ docks: [DockConfiguration], revision: UInt64, globalRevealStyle: DockRevealStyle? = nil, globalPositionLocked: Bool? = nil) throws {
        guard revision >= lastRevision else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard Set(docks.map(\.id)).count == docks.count,
              docks.allSatisfy({ Set($0.allEntries.map(\.id)).count == $0.allEntries.count }) else {
            throw StoreError.duplicateIdentifiers
        }
        guard docks.allSatisfy({ dock in dock.applications.allSatisfy { item in
            item.kind == .stack ? item.children.allSatisfy { $0.kind == .application && $0.children.isEmpty } : item.children.isEmpty
        } }) else { throw StoreError.invalidStack }
        let normalized = docks.map { original in
            var dock = original
            dock.appearance = dock.appearance.normalized
            dock.behavior = dock.behavior.normalized
            if !DockPositioning.valid(dock.position) { dock.position = DockPosition(x: 0, y: 0) }
            dock.placement.relativeX = DockPositioning.fraction(dock.placement.relativeX)
            dock.placement.relativeY = DockPositioning.fraction(dock.placement.relativeY)
            return dock
        }
        let revealStyle = (globalRevealStyle ?? lastSavedRevealStyle ?? DockRevealStyle()).normalized
        let locked = globalPositionLocked ?? lastSavedPositionLocked ?? false
        if normalized == lastSavedDocks && revealStyle == lastSavedRevealStyle && locked == lastSavedPositionLocked {
            lastRevision = revision
            return
        }
        let data = try encoder.encode(Document(docks: normalized, globalRevealStyle: revealStyle, globalPositionLocked: locked))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastRevision = revision
        lastSavedDocks = normalized
        lastSavedRevealStyle = revealStyle
        lastSavedPositionLocked = locked
        writeCount += 1
    }
}
