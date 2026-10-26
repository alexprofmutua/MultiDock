import Foundation

struct DockItemDrag: Codable, Equatable, Sendable {
    let dockID: UUID
    let itemID: UUID
    var stackID: UUID? = nil
}

enum DockEditError: LocalizedError {
    case missingDock, missingItem, invalidGroup, duplicate(String)
    var errorDescription: String? {
        switch self {
        case .invalidGroup: "Stacks can contain applications only. Nested stacks are not supported."
        case .missingDock: "This dock has been closed. Drop the application into an open dock."
        case .missingItem: "This entry is no longer in its source dock. Try dragging it again."
        case .duplicate(let name): "\(name) is already in this dock. Enable Allow Duplicate Applications in this dock's options to add another entry."
        }
    }
}

/// All edits are transactional. A rejected move never removes the source entry.
enum DockItemEditor {
    static func insert(_ items: [ApplicationItem], at index: Int, into dock: inout DockConfiguration) throws {
        var entries = dock.applications
        var cursor = min(max(index, 0), entries.count)
        for item in items {
            guard dock.allowsDuplicateApplications || !entries.contains(where: { $0.duplicateKey == item.duplicateKey }) else {
                throw DockEditError.duplicate(item.name)
            }
            let entry = entries.contains(where: { $0.id == item.id }) ? item.copy() : item
            entries.insert(entry, at: cursor)
            cursor += 1
        }
        dock.applications = entries
    }

    static func remove(_ id: UUID, from dock: inout DockConfiguration) {
        dock.applications.removeAll { $0.id == id }
    }

    static func entries(in dock: DockConfiguration, stackID: UUID?) throws -> [DockItem] {
        guard let stackID else { return dock.applications }
        guard let stack = dock.applications.first(where: { $0.id == stackID && $0.kind == .stack }) else { throw DockEditError.missingItem }
        return stack.children
    }
    static func setEntries(_ entries: [DockItem], in dock: inout DockConfiguration, stackID: UUID?) throws {
        if let stackID {
            guard entries.allSatisfy({ $0.kind == .application }),
                  let index = dock.applications.firstIndex(where: { $0.id == stackID && $0.kind == .stack }) else { throw DockEditError.invalidGroup }
            dock.applications[index].children = entries
        } else { dock.applications = entries }
    }
    /// Index is an insertion gap before the edit. Commit only after all duplicate/type checks pass.
    static func transfer(_ drag: DockItemDrag, to destination: UUID, at index: Int, copy: Bool,
                         toStack: UUID? = nil, in docks: inout [DockConfiguration]) throws {
        var edited = docks
        guard let sourceIndex = edited.firstIndex(where: { $0.id == drag.dockID }),
              let destinationIndex = edited.firstIndex(where: { $0.id == destination }) else { throw DockEditError.missingDock }
        var source = try entries(in: edited[sourceIndex], stackID: drag.stackID)
        var target = try entries(in: edited[destinationIndex], stackID: toStack)
        guard let itemIndex = source.firstIndex(where: { $0.id == drag.itemID }) else { throw DockEditError.missingItem }
        let item = source[itemIndex]
        guard toStack == nil || item.kind == .application else { throw DockEditError.invalidGroup }
        let gap = min(max(index, 0), target.count)
        if sourceIndex == destinationIndex && drag.stackID == toStack && !copy {
            source.remove(at: itemIndex)
            source.insert(item, at: gap > itemIndex ? gap - 1 : gap)
            try setEntries(source, in: &edited[sourceIndex], stackID: drag.stackID)
        } else {
            guard edited[destinationIndex].allowsDuplicateApplications || !target.contains(where: { $0.duplicateKey == item.duplicateKey }) else {
                throw DockEditError.duplicate(item.name)
            }
            if !copy {
                source.remove(at: itemIndex)
                try setEntries(source, in: &edited[sourceIndex], stackID: drag.stackID)
                if sourceIndex == destinationIndex { target = try entries(in: edited[destinationIndex], stackID: toStack) }
            }
            target.insert(copy ? item.copy() : item, at: min(gap, target.count))
            try setEntries(target, in: &edited[destinationIndex], stackID: toStack)
        }
        docks = edited
    }
}
