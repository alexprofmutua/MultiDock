import Foundation

enum DockItemKind: String, Codable, Sendable { case application, stack, folder }

/// The legacy ApplicationItem spelling and `applications` JSON key remain compatible.
struct DockItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let bundleIdentifier: String
    var name: String
    let location: URL?
    let bookmark: Data?
    var kind: DockItemKind
    var children: [DockItem]
    var stackSymbol: String
    static let stackSymbols = ["folder.fill", "hammer.fill", "terminal.fill", "briefcase.fill", "star.fill"]

    init(id: UUID = UUID(), bundleIdentifier: String, name: String, location: URL? = nil, bookmark: Data? = nil,
         kind: DockItemKind = .application, children: [DockItem] = [], stackSymbol: String = "folder.fill") {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.name = name
        self.location = location; self.bookmark = bookmark; self.kind = kind
        self.children = children; self.stackSymbol = Self.stackSymbols.contains(stackSymbol) ? stackSymbol : "folder.fill"
    }
    static func symbolTitle(_ symbol: String) -> String {
        switch symbol {
        case "hammer.fill": "Developer tools"
        case "terminal.fill": "Terminal"
        case "briefcase.fill": "Work"
        case "star.fill": "Favorites"
        default: "Folder"
        }
    }
    private enum CodingKeys: String, CodingKey { case id, bundleIdentifier, name, location, bookmark, kind, children, stackSymbol }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        name = try c.decode(String.self, forKey: .name)
        location = try c.decodeIfPresent(URL.self, forKey: .location)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        kind = try c.decodeIfPresent(DockItemKind.self, forKey: .kind) ?? .application
        // Decode children as leaf applications only; never recurse through untrusted nested groups.
        let raw = try c.decodeIfPresent([LeafApplication].self, forKey: .children) ?? []
        children = raw.map(\.item)
        stackSymbol = try c.decodeIfPresent(String.self, forKey: .stackSymbol) ?? "folder.fill"
        if !Self.stackSymbols.contains(stackSymbol) { stackSymbol = "folder.fill" }
        guard kind == .stack || children.isEmpty else { throw DockEditError.invalidGroup }
    }
    private struct LeafApplication: Decodable {
        let item: DockItem
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard (try c.decodeIfPresent(DockItemKind.self, forKey: .kind) ?? .application) == .application else { throw DockEditError.invalidGroup }
            item = DockItem(id: try c.decode(UUID.self, forKey: .id), bundleIdentifier: try c.decode(String.self, forKey: .bundleIdentifier),
                name: try c.decode(String.self, forKey: .name), location: try c.decodeIfPresent(URL.self, forKey: .location),
                bookmark: try c.decodeIfPresent(Data.self, forKey: .bookmark))
            if c.contains(.children), !(try c.nestedUnkeyedContainer(forKey: .children)).isAtEnd { throw DockEditError.invalidGroup }
        }
    }
    var duplicateKey: String {
        switch kind {
        case .application: bundleIdentifier.lowercased()
        case .stack: id.uuidString
        case .folder: location?.standardizedFileURL.path ?? id.uuidString
        }
    }
    func copy() -> Self {
        Self(bundleIdentifier: bundleIdentifier, name: name, location: location, bookmark: bookmark,
             kind: kind, children: children.map { $0.copy() }, stackSymbol: stackSymbol)
    }
    static func stack(name: String = "New Stack") -> Self {
        Self(bundleIdentifier: "org.multidock.stack.\(UUID().uuidString)", name: name, kind: .stack)
    }
}
typealias ApplicationItem = DockItem

enum DockOrientation: String, Codable, CaseIterable, Sendable {
    case horizontal, vertical
}

struct DockPosition: Codable, Equatable, Sendable {
    // AppKit global screen coordinates, measured from the bottom left.
    var x: Double
    var y: Double
}

struct DockConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var orientation: DockOrientation
    var position: DockPosition
    var applications: [ApplicationItem]
    var allowsDuplicateApplications: Bool
    var appearance: DockAppearance
    var placement: DockPlacement
    var behavior: DockBehavior
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, orientation: DockOrientation = .horizontal,
         position: DockPosition, applications: [ApplicationItem] = [], allowsDuplicateApplications: Bool = false, appearance: DockAppearance = DockAppearance(), placement: DockPlacement = DockPlacement(), isEnabled: Bool = true, behavior: DockBehavior = DockBehavior()) {
        self.id = id
        self.name = name
        self.orientation = orientation
        self.position = position
        self.applications = applications
        self.allowsDuplicateApplications = allowsDuplicateApplications
        self.appearance = appearance.normalized
        self.placement = placement
        self.isEnabled = isEnabled
        self.behavior = behavior.normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, orientation, position, applications, allowsDuplicateApplications, appearance, placement, isEnabled, behavior
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        behavior = try values.decodeIfPresent(DockBehavior.self, forKey: .behavior)?.normalized ?? DockBehavior()
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        name = try values.decode(String.self, forKey: .name)
        orientation = try values.decode(DockOrientation.self, forKey: .orientation)
        position = try values.decode(DockPosition.self, forKey: .position)
        applications = try values.decode([ApplicationItem].self, forKey: .applications)
        allowsDuplicateApplications = try values.decodeIfPresent(Bool.self, forKey: .allowsDuplicateApplications) ?? false
        placement = try values.decodeIfPresent(DockPlacement.self, forKey: .placement) ?? DockPlacement()
        placement.relativeX = DockPositioning.fraction(placement.relativeX)
        placement.relativeY = DockPositioning.fraction(placement.relativeY)
        appearance = try values.decodeIfPresent(DockAppearance.self, forKey: .appearance)?.normalized ?? DockAppearance()
    }

    var allEntries: [DockItem] { applications.flatMap { [$0] + $0.children } }

    /// A duplicated dock shares application references, never model or entry identities.
    func duplicate(name: String) -> Self {
        Self(name: name, orientation: orientation, position: position,
             applications: applications.map { $0.copy() }, allowsDuplicateApplications: allowsDuplicateApplications,
             appearance: appearance, placement: placement, isEnabled: isEnabled, behavior: behavior)
    }

}
