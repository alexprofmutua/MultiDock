import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct DockArchiveTests {
    private func dock() -> DockConfiguration {
        DockConfiguration(name: "Work", orientation: .vertical, position: DockPosition(x: -800, y: 80),
                          applications: [ApplicationItem(bundleIdentifier: "example.editor", name: "Editor")],
                          appearance: DockAppearance(iconSize: 48, spacing: 9, colorMode: .dark), isEnabled: false)
    }
    private func object(_ docks: [DockConfiguration], version: Int = DockArchive.currentVersion) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(version: version, docks: docks))) as! [String: Any]
    }
    private func bytes(_ root: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: root) }

    @Test func locksAndClickModesPersistWithSafeLegacyDefaults() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DockStore(url: folder.appendingPathComponent("docks.json"))
        var original = dock()
        original.behavior.positionLocked = true
        original.behavior.clickMode = .cycleWindows
        original.behavior.restoreMinimizedOnClick = false
        try await store.save([original], revision: 1, globalPositionLocked: true)
        let recovered = try await DockStore(url: store.url).loadRecovering()
        #expect(recovered.globalPositionLocked && recovered.docks == [original])
        var root = try object([dock()], version: 7)
        root.removeValue(forKey: "globalPositionLocked")
        var records = root["docks"] as! [[String: Any]]
        var behavior = records[0]["behavior"] as! [String: Any]
        for key in ["positionLocked", "clickMode", "restoreMinimizedOnClick"] { behavior.removeValue(forKey: key) }
        records[0]["behavior"] = behavior; root["docks"] = records
        let old = try DockArchive.recover(bytes(root))
        #expect(!old.globalPositionLocked && old.docks[0].behavior.clickMode == .standard)
        #expect(!old.docks[0].behavior.positionLocked)
    }

    @Test func applicationOnlyArchiveMigratesAndBadStackChildIsRecovered() throws {
        var expected = dock()
        var group = DockItem.stack(name: "Tools")
        group.children = expected.applications
        expected.applications = [group]
        var root = try object([expected], version: 7)
        var records = root["docks"] as! [[String: Any]]
        var entries = records[0]["applications"] as! [[String: Any]]
        var children = entries[0]["children"] as! [[String: Any]]
        children.append(["name": "Broken child"])
        entries[0]["children"] = (children as [Any]) + ["broken child record"]
        records[0]["applications"] = entries
        root["docks"] = records
        let recovered = try DockArchive.recover(bytes(root))
        #expect(recovered.docks == [expected])
        #expect(recovered.needsRewrite && !recovered.notices.isEmpty)
        let old = dock()
        root = try object([old], version: 7)
        records = root["docks"] as! [[String: Any]]
        entries = records[0]["applications"] as! [[String: Any]]
        for index in entries.indices {
            entries[index].removeValue(forKey: "kind"); entries[index].removeValue(forKey: "children")
            entries[index].removeValue(forKey: "stackSymbol")
        }
        records[0]["applications"] = entries; root["docks"] = records
        #expect(try DockArchive.recover(bytes(root)).docks == [old])
    }

    @Test func versionSixMigratesRevealThemesWithoutChangingDocks() throws {
        let expected = dock()
        var root = try object([expected], version: 6)
        root.removeValue(forKey: "globalRevealStyle")
        var records = root["docks"] as! [[String: Any]]
        var appearance = records[0]["appearance"] as! [String: Any]
        appearance.removeValue(forKey: "revealTabUsesGlobal")
        appearance.removeValue(forKey: "revealTabStyle")
        records[0]["appearance"] = appearance
        root["docks"] = records
        let recovered = try DockArchive.recover(bytes(root))
        #expect(recovered.docks == [expected])
        #expect(recovered.globalRevealStyle == DockRevealStyle())
        #expect(recovered.needsRewrite && recovered.notices.isEmpty)
        let decoded = try JSONDecoder().decode(DockStore.Document.self, from: bytes(root))
        #expect(decoded.globalRevealStyle == DockRevealStyle())
    }

    @Test func invalidRevealThemeRetainsOtherSettings() throws {
        let expected = dock()
        var root = try object([expected])
        root["globalRevealStyle"] = ["color": "invalid", "opacity": "invalid"]
        let recovered = try DockArchive.recover(bytes(root))
        #expect(recovered.docks == [expected])
        #expect(recovered.globalRevealStyle == DockRevealStyle())
        #expect(recovered.needsRewrite && !recovered.notices.isEmpty)
    }

    @Test func revealThemesPersistWithoutRedundantWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        var original = dock()
        original.appearance.revealTabUsesGlobal = false
        original.appearance.revealTabStyle = DockRevealStyle(color: .pink, opacity: 0.7)
        let global = DockRevealStyle(color: .green, opacity: 0.5)
        try await store.save([original], revision: 1, globalRevealStyle: global)
        try await store.save([original], revision: 2, globalRevealStyle: global)
        #expect(await store.writeCount == 1)
        let reopened = DockStore(url: store.url)
        let loaded = try await reopened.loadRecovering()
        #expect(loaded.globalRevealStyle == global && loaded.docks == [original])
        #expect(loaded.backupURL == nil)
        try await reopened.save([original], revision: 3) // Legacy caller retains loaded global style.
        #expect(await reopened.writeCount == 0)
        let changed = DockRevealStyle(color: .blue, opacity: 0.5)
        try await reopened.save([original], revision: 4, globalRevealStyle: changed)
        #expect(await reopened.writeCount == 1)
        #expect(try await DockStore(url: store.url).loadRecovering().globalRevealStyle == changed)
        try await reopened.save([], revision: 5, globalRevealStyle: global)
        #expect(try await DockStore(url: store.url).loadRecovering().globalRevealStyle == global)
    }

    @Test func versionOneMigratesWithoutChangingIDsOrderOrSettings() throws {
        let expected = dock()
        var root = try object([expected], version: 1)
        var records = root["docks"] as! [[String: Any]]
        records[0].removeValue(forKey: "isEnabled")
        root["docks"] = records
        let result = try DockArchive.recover(bytes(root))
        #expect(result.needsRewrite)
        #expect(result.notices.isEmpty)
        var enabled = expected
        enabled.isEnabled = true
        #expect(result.docks == [enabled])
    }

    @Test func currentVersionRestoresDisabledDocksExactly() throws {
        let expected = [dock(), dock().duplicate(name: "Copy")]
        let result = try DockArchive.recover(bytes(object(expected)))
        #expect(result.docks == expected)
        #expect(!result.needsRewrite)
    }

    @Test func duplicationPreservesSettingsWithIndependentIdentities() {
        let original = dock()
        let copy = original.duplicate(name: "Copy")
        #expect(copy.id != original.id)
        #expect(copy.applications[0].id != original.applications[0].id)
        #expect(copy.applications[0].bundleIdentifier == original.applications[0].bundleIdentifier)
        #expect(copy.orientation == original.orientation && copy.appearance == original.appearance)
        #expect(copy.placement == original.placement && copy.isEnabled == original.isEnabled)
    }

    @Test func malformedDockDoesNotLoseHealthyNeighbor() throws {
        let expected = dock()
        var root = try object([expected])
        root["docks"] = ["broken", (root["docks"] as! [Any])[0]]
        let result = try DockArchive.recover(bytes(root))
        #expect(result.docks == [expected])
        #expect(result.needsRewrite && !result.notices.isEmpty)
    }

    @Test func brokenFieldRetainsOtherAppearanceAndApplicationSettings() throws {
        var root = try object([dock()])
        var records = root["docks"] as! [[String: Any]]
        var appearance = records[0]["appearance"] as! [String: Any]
        appearance["spacing"] = "broken"
        records[0]["appearance"] = appearance
        records[0]["orientation"] = "invalid"
        root["docks"] = records
        let recovered = try DockArchive.recover(bytes(root))
        let result = try #require(recovered.docks.first)
        #expect(result.name == "Work" && !result.isEnabled)
        #expect(result.appearance.iconSize == 48 && result.appearance.colorMode == .dark)
        #expect(result.appearance.spacing == DockAppearance().spacing)
        #expect(result.orientation == .horizontal && result.applications.count == 1)
        #expect(recovered.needsRewrite)
    }

    @Test func repeatedDockIdentityIsRestoredOnceAndEntriesGetUniqueIDs() throws {
        var original = dock()
        original.applications.append(original.applications[0])
        let result = try DockArchive.recover(bytes(object([original, original])))
        #expect(result.docks.count == 1)
        #expect(result.docks[0].id == original.id)
        #expect(result.docks[0].applications.count == 2)
        #expect(Set(result.docks[0].applications.map(\.id)).count == 2)
        #expect(result.needsRewrite)
    }

    @Test func badEntryAndBookmarkDoNotDiscardOtherApplications() throws {
        var root = try object([dock()])
        var records = root["docks"] as! [[String: Any]]
        var apps = records[0]["applications"] as! [[String: Any]]
        apps[0]["bookmark"] = "not base64!"
        records[0]["applications"] = [apps[0], ["name": "broken"]]
        root["docks"] = records
        let result = try DockArchive.recover(bytes(root))
        #expect(result.docks[0].applications.count == 1)
        #expect(result.docks[0].applications[0].bookmark == nil)
        #expect(result.docks[0].applications[0].bundleIdentifier == "example.editor")
        #expect(result.needsRewrite)
    }

    @Test func invalidEnvelopeFutureVersionAndUnrecoverableRecordsAreRejected() throws {
        for root: [String: Any] in [["version": 99, "docks": []], ["version": true, "docks": []],
                                    ["version": 2, "docks": ["bad"]], ["version": 2, "docks": "wrong"]] {
            #expect(throws: (any Error).self) { try DockArchive.recover(bytes(root)) }
        }
    }

    @Test func recoveryBacksUpOriginalBeforeSavingRepairedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        let expected = dock()
        let original = try bytes(object([expected, expected]))
        try original.write(to: store.url)
        let loaded = try await store.loadRecovering()
        let backup = try #require(loaded.backupURL)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try Data(contentsOf: store.url) == original)
        try await store.save(try #require(loaded.docks), revision: 1)
        #expect(try await store.load() == [expected])
        #expect(try Data(contentsOf: backup) == original)
        let again = try await DockStore(url: store.url).loadRecovering()
        #expect(again.backupURL == nil && again.notices.isEmpty)
    }

    @Test func unchangedStateDoesNotWriteAgainEvenAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        let docks = [dock()]
        try await store.save(docks, revision: 1)
        try await store.save(docks, revision: 2)
        #expect(await store.writeCount == 1)
        let reopened = DockStore(url: store.url)
        _ = try await reopened.loadRecovering()
        try await reopened.save(docks, revision: 1)
        #expect(await reopened.writeCount == 0)
    }

    @Test func futureAndSyntacticallyBrokenFilesRemainUntouchedDuringRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DockStore(url: directory.appendingPathComponent("docks.json"))
        for data in [Data("{broken".utf8), try bytes(object([dock()], version: 99))] {
            try data.write(to: store.url)
            await #expect(throws: (any Error).self) { try await store.loadRecovering() }
            #expect(try Data(contentsOf: store.url) == data)
        }
    }
}
