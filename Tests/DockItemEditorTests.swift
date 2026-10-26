import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct DockItemEditorTests {
    private func item(_ name: String) -> ApplicationItem { ApplicationItem(bundleIdentifier: "test.\(name)", name: name) }
    private func dock(_ apps: [ApplicationItem] = [], duplicates: Bool = false) -> DockConfiguration {
        DockConfiguration(name: "Test", position: DockPosition(x: 0, y: 0), applications: apps, allowsDuplicateApplications: duplicates)
    }

    @Test func largeStackPersistsAndNestedGroupsCannotOverwriteIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        var group = DockItem.stack(name: "Large")
        group.children = (0..<1000).map { item(String($0)) }
        var original = dock([group])
        try await store.save([original], revision: 1)
        let restored = try await store.load()
        #expect(restored == [original])
        let bytes = try Data(contentsOf: store.url)
        original.applications[0].children.append(.stack(name: "Forbidden nested stack"))
        await #expect(throws: (any Error).self) { try await store.save([original], revision: 2) }
        #expect(try Data(contentsOf: store.url) == bytes)
    }

    @Test func stackMovesCopiesAndDuplicateFailuresAreTransactional() throws {
        let a = item("A"), b = item("B")
        var first = dock([a, b, .stack(name: "Tools")])
        let stack = first.applications[2].id
        let second = dock([.stack(name: "Other")])
        let other = second.applications[0].id
        var docks = [first, second]
        try DockItemEditor.transfer(DockItemDrag(dockID: first.id, itemID: a.id), to: first.id, at: 0, copy: false, toStack: stack, in: &docks)
        #expect(docks[0].applications.count == 2 && docks[0].applications[1].children == [a])
        try DockItemEditor.transfer(DockItemDrag(dockID: first.id, itemID: a.id, stackID: stack), to: second.id, at: 0, copy: true, toStack: other, in: &docks)
        let copy = docks[1].applications[0].children[0]
        #expect(copy.id != a.id && copy.bundleIdentifier == a.bundleIdentifier)
        let unchanged = docks
        #expect(throws: DockEditError.self) {
            try DockItemEditor.transfer(DockItemDrag(dockID: first.id, itemID: a.id, stackID: stack), to: second.id, at: 1, copy: false, toStack: other, in: &docks)
        }
        #expect(docks == unchanged)
        try DockItemEditor.transfer(DockItemDrag(dockID: first.id, itemID: a.id, stackID: stack), to: first.id, at: 0, copy: false, in: &docks)
        #expect(docks[0].applications[0] == a && docks[0].applications.last!.children.isEmpty)
        first = docks[0]
        #expect(throws: DockEditError.self) {
            try DockItemEditor.transfer(DockItemDrag(dockID: first.id, itemID: stack), to: second.id, at: 0, copy: false, toStack: other, in: &docks)
        }
        #expect(first.applications.last!.copy().id != stack)
    }

    @Test func stackChildrenRoundTripWithIndependentDuplicateIdentities() throws {
        var stack = DockItem.stack(name: "Developer")
        stack.children = [item("A"), item("B")]
        let decoded = try JSONDecoder().decode(DockItem.self, from: JSONEncoder().encode(stack))
        #expect(decoded == stack && decoded.kind == .stack)
        let copy = stack.copy()
        #expect(copy.id != stack.id && copy.children.map(\.id) != stack.children.map(\.id))
        #expect(copy.children.map(\.bundleIdentifier) == stack.children.map(\.bundleIdentifier))
    }

    @Test func insertsAtRequestedGapAndClampsBounds() throws {
        let a = item("A"), b = item("B"), c = item("C")
        var target = dock([a])
        try DockItemEditor.insert([b], at: -5, into: &target)
        try DockItemEditor.insert([c], at: Int.max, into: &target)
        #expect(target.applications == [b, a, c])
    }

    @Test func removalOnlyChangesSpecifiedEntryAndDock() {
        let a = item("A"), duplicate = a.copy()
        var first = dock([a, duplicate], duplicates: true)
        let second = dock([a.copy()])
        DockItemEditor.remove(a.id, from: &first)
        #expect(first.applications == [duplicate])
        #expect(second.applications.count == 1)
        DockItemEditor.remove(UUID(), from: &first)
        #expect(first.applications == [duplicate])
    }

    @Test func defaultDuplicateRuleIsCaseInsensitiveAndAtomic() {
        let a = item("A")
        var target = dock([a])
        let sameApp = ApplicationItem(bundleIdentifier: "TEST.A", name: "A elsewhere", location: URL(fileURLWithPath: "/different/A.app"))
        #expect(throws: DockEditError.self) {
            try DockItemEditor.insert([item("B"), sameApp], at: 0, into: &target)
        }
        #expect(target.applications == [a])
    }

    @Test func rejectsDuplicatesWithinOneIncomingBatch() {
        var target = dock()
        let a = item("A")
        #expect(throws: DockEditError.self) { try DockItemEditor.insert([a, a.copy()], at: 0, into: &target) }
        #expect(target.applications.isEmpty)
    }

    @Test func explicitOptInAllowsDuplicatesWithDistinctIdentity() throws {
        var target = dock(duplicates: true)
        let a = item("A")
        try DockItemEditor.insert([a, a], at: 0, into: &target)
        #expect(target.applications.count == 2)
        #expect(target.applications[0].id != target.applications[1].id)
        #expect(target.applications[0].duplicateKey == target.applications[1].duplicateKey)
    }

    @Test func reordersForwardBackwardAndToSameGapWithoutChangingIdentity() throws {
        let a = item("A"), b = item("B"), c = item("C")
        var docks = [dock([a, b, c])]
        let drag = DockItemDrag(dockID: docks[0].id, itemID: a.id)
        try DockItemEditor.transfer(drag, to: docks[0].id, at: 3, copy: false, in: &docks)
        #expect(docks[0].applications == [b, c, a])
        try DockItemEditor.transfer(drag, to: docks[0].id, at: 0, copy: false, in: &docks)
        #expect(docks[0].applications == [a, b, c])
        try DockItemEditor.transfer(drag, to: docks[0].id, at: 1, copy: false, in: &docks)
        #expect(docks[0].applications == [a, b, c])
    }

    @Test func crossDockMovePreservesIdentityAndCopiesLeaveSourceIntact() throws {
        let a = item("A"), b = item("B")
        var docks = [dock([a]), dock([b]), dock()]
        let drag = DockItemDrag(dockID: docks[0].id, itemID: a.id)
        try DockItemEditor.transfer(drag, to: docks[1].id, at: 0, copy: true, in: &docks)
        #expect(docks[0].applications == [a])
        #expect(docks[1].applications[0].id != a.id)
        #expect(docks[1].applications[0].bundleIdentifier == a.bundleIdentifier)
        try DockItemEditor.transfer(drag, to: docks[2].id, at: 100, copy: false, in: &docks)
        #expect(docks[0].applications.isEmpty)
        #expect(docks[2].applications == [a])
        #expect(docks[1].applications.last == b)
    }

    @Test func duplicateDestinationRejectsMoveWithoutRemovingSource() {
        let a = item("A")
        var docks = [dock([a]), dock([a.copy()])]
        let original = docks
        let drag = DockItemDrag(dockID: docks[0].id, itemID: a.id)
        #expect(throws: DockEditError.self) {
            try DockItemEditor.transfer(drag, to: docks[1].id, at: 0, copy: false, in: &docks)
        }
        #expect(docks == original)
    }

    @Test func sameDockOptionCopyRequiresExplicitDuplicateOptIn() throws {
        let a = item("A")
        var docks = [dock([a])]
        let drag = DockItemDrag(dockID: docks[0].id, itemID: a.id)
        #expect(throws: DockEditError.self) {
            try DockItemEditor.transfer(drag, to: docks[0].id, at: 1, copy: true, in: &docks)
        }
        docks[0].allowsDuplicateApplications = true
        try DockItemEditor.transfer(drag, to: docks[0].id, at: 1, copy: true, in: &docks)
        #expect(docks[0].applications.count == 2)
        #expect(docks[0].applications[0].id != docks[0].applications[1].id)
    }

    @Test func staleSourceItemOrDockDoesNotModifyAnyDock() {
        var docks = [dock([item("A")]), dock()]
        let original = docks
        for drag in [DockItemDrag(dockID: UUID(), itemID: UUID()), DockItemDrag(dockID: docks[0].id, itemID: UUID())] {
            #expect(throws: DockEditError.self) {
                try DockItemEditor.transfer(drag, to: docks[1].id, at: 0, copy: false, in: &docks)
            }
            #expect(docks == original)
        }
    }
}
