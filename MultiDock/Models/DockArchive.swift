import Foundation

/// Versioned boundary between local JSON and live models. Recovery never reads or changes app bundles.
enum DockArchive {
    static let currentVersion = 9
    struct Recovery: Sendable {
        let docks: [DockConfiguration]
        let globalPositionLocked: Bool
        let globalRevealStyle: DockRevealStyle
        let notices: [String]
        let needsRewrite: Bool
    }
    enum ArchiveError: LocalizedError {
        case invalidEnvelope, noRecoverableDocks, unsupportedVersion
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "This saved dock file uses an unsupported format."
            case .invalidEnvelope: "The configuration must contain a version and an array of docks."
            case .noRecoverableDocks: "No dock configurations could be recovered. The original file has been preserved."
            }
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }

    /// v1 adds enabled state; v2 adds default-off advanced interactions; v3 adds default-off previews. Future versions are never guessed.
    static func recover(_ data: Data) throws -> Recovery {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVersion = root["version"],
              let version = try? decode(Int.self, rawVersion),
              let records = root["docks"] as? [Any] else { throw ArchiveError.invalidEnvelope }
        guard (1...currentVersion).contains(version) else { throw ArchiveError.unsupportedVersion }
        var notices: [String] = []
        var docks: [DockConfiguration] = []
        var identities: Set<UUID> = []
        for (index, record) in records.enumerated() {
            let label = "Dock \(index + 1)"
            guard var object = record as? [String: Any], let rawID = object["id"],
                  let id = try? decode(UUID.self, rawID) else {
                notices.append("\(label): skipped a record without a valid identity.")
                continue
            }
            guard identities.insert(id).inserted else {
                notices.append("\(label): skipped a repeated dock identity.")
                continue
            }
            let defaults = DockConfiguration(id: id, name: "Recovered Dock", position: DockPosition(x: 0, y: 0))
            let defaultObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
            func repair<T: Decodable>(_ key: String, _ type: T.Type) {
                if let value = object[key], (try? decode(type, value)) != nil { return }
                // Fields introduced in previous phases are optional in older documents.
                if object[key] != nil || ["name", "orientation", "position"].contains(key) {
                    notices.append("\(label): reset invalid \(key).")
                }
                object[key] = defaultObject[key]
            }
            repair("name", String.self)
            repair("orientation", DockOrientation.self)
            repair("position", DockPosition.self)
            repair("isEnabled", Bool.self)
            repair("allowsDuplicateApplications", Bool.self)
            for key in ["appearance", "placement", "behavior"] {
                guard let raw = object[key] else { object[key] = defaultObject[key]; continue }
                guard let fields = raw as? [String: Any] else {
                    object[key] = defaultObject[key]; notices.append("\(label): reset invalid \(key)."); continue
                }
                var accepted = defaultObject[key] as! [String: Any]
                // Validate one field at a time so a broken slider value does not discard the whole appearance.
                for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
                    var candidate = accepted
                    candidate[field] = value
                    let valid: Bool
                    switch key {
                    case "appearance": valid = (try? decode(DockAppearance.self, candidate)) != nil
                    case "behavior": valid = (try? decode(DockBehavior.self, candidate)) != nil
                    default: valid = (try? decode(DockPlacement.self, candidate)) != nil
                    }
                    if valid { accepted = candidate }
                    else { notices.append("\(label): reset invalid \(key).\(field).") }
                }
                object[key] = accepted
            }
            var entries: [ApplicationItem] = []
            var itemIDs: Set<UUID> = []
            if let rawItems = object["applications"] as? [Any] {
                for raw in rawItems {
                    var entry = raw as? [String: Any] ?? [:]
                    if entry["kind"] as? String == "stack" {
                        let children = entry["children"] as? [Any] ?? []
                        if entry["children"] != nil && !(entry["children"] is [Any]) {
                            notices.append("\(label): recovered an empty stack from invalid contents.")
                        }
                        let valid = children.compactMap { raw -> [String: Any]? in
                            guard var child = raw as? [String: Any],
                                  (child["kind"] as? String ?? "application") == "application" else { return nil }
                            for field in ["location", "bookmark"] {
                                if let value = child[field] {
                                    let healthy = field == "location" ? (try? decode(URL?.self, value)) != nil : (try? decode(Data?.self, value)) != nil
                                    if !healthy { child.removeValue(forKey: field); notices.append("\(label): repaired stack application \(field).") }
                                }
                            }
                            return (try? decode(DockItem.self, child)) != nil ? child : nil
                        }
                        if valid.count != children.count { notices.append("\(label): skipped invalid or nested stack entries.") }
                        entry["children"] = valid
                    }
                    for field in ["location", "bookmark"] {
                        if let value = entry[field] {
                            let valid = field == "location" ? (try? decode(URL?.self, value)) != nil
                                : (try? decode(Data?.self, value)) != nil
                            if !valid {
                                entry.removeValue(forKey: field)
                                notices.append("\(label): removed invalid application \(field); the bundle identifier is retained.")
                            }
                        }
                    }
                    guard var item = try? decode(ApplicationItem.self, entry),
                          !item.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        notices.append("\(label): skipped an invalid application entry."); continue
                    }
                    if !itemIDs.insert(item.id).inserted {
                        item = item.copy()
                        itemIDs.insert(item.id)
                        notices.append("\(label): assigned a new identity to a repeated entry.")
                    }
                    for childIndex in item.children.indices {
                        if !itemIDs.insert(item.children[childIndex].id).inserted {
                            item.children[childIndex] = item.children[childIndex].copy()
                            itemIDs.insert(item.children[childIndex].id)
                            notices.append("\(label): assigned an independent stack-entry identity.")
                        }
                    }
                    entries.append(item)
                }
            } else { notices.append("\(label): recovered an empty application list.") }
            object["applications"] = []
            var dock = try decode(DockConfiguration.self, object)
            dock.applications = entries
            if let raw = object["behavior"], let behavior = try? decode(DockBehavior.self, raw), behavior != behavior.normalized {
                notices.append("\(label): constrained invalid behavior settings.")
            }
            if let raw = object["appearance"], let appearance = try? decode(DockAppearance.self, raw), appearance != appearance.normalized {
                notices.append("\(label): constrained out-of-range appearance values.")
            }
            if let raw = object["placement"], let placement = try? decode(DockPlacement.self, raw), placement != dock.placement {
                notices.append("\(label): constrained invalid placement fractions.")
            }
            if !DockPositioning.valid(dock.position) {
                dock.position = DockPosition(x: 0, y: 0)
                notices.append("\(label): reset invalid coordinates.")
            }
            docks.append(dock)
        }
        if !records.isEmpty && docks.isEmpty { throw ArchiveError.noRecoverableDocks }
        var globalRevealStyle = DockRevealStyle()
        if let raw = root["globalRevealStyle"] {
            if let decoded = try? decode(DockRevealStyle.self, raw) {
                globalRevealStyle = decoded.normalized
                if decoded != globalRevealStyle { notices.append("Constrained invalid global reveal-tab opacity.") }
            } else { notices.append("Reset invalid global reveal-tab theme; dock settings are retained.") }
        }
        let globalPositionLocked = root["globalPositionLocked"].flatMap { try? decode(Bool.self, $0) } ?? false
        if let raw = root["globalPositionLocked"], (try? decode(Bool.self, raw)) == nil {
            notices.append("Reset invalid global position lock.")
        }
        return Recovery(docks: docks, globalPositionLocked: globalPositionLocked, globalRevealStyle: globalRevealStyle, notices: notices,
                        needsRewrite: version != currentVersion || !notices.isEmpty)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try decoder().decode(type, from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }
}
