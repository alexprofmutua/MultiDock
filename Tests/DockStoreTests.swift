import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct DockStoreTests {
    private func withStore(_ test: (DockStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await test(DockStore(url: root.appendingPathComponent("docks.json")), root)
    }
    private func dock(_ name: String) -> DockConfiguration {
        DockConfiguration(name: name, position: DockPosition(x: 200, y: 300),
                          applications: [ApplicationItem(bundleIdentifier: "test.app", name: "App", bookmark: Data([1, 2, 3]))],
                          appearance: DockAppearance(iconSize: 48, colorMode: .dark),
                          placement: DockPlacement(displayID: "stable", relativeX: 0.3, relativeY: 0.4, anchor: .right))
    }

    @Test func missingFileDiffersFromIntentionallyEmptySavedDocks() async throws {
        try await withStore { store, _ in
            #expect(try await store.load() == nil)
            try await store.save([], revision: 1)
            #expect(try await store.load() == [])
        }
    }

    @Test func independentPositionsAndApplicationAppearanceDataRoundTrip() async throws {
        try await withStore { store, root in
            var second = dock("Two")
            second.position = DockPosition(x: -1000, y: 500)
            second.orientation = .vertical
            second.placement.displayID = "external"
            let docks = [dock("One"), second]
            try await store.save(docks, revision: 1)
            let reopened = DockStore(url: root.appendingPathComponent("docks.json"))
            #expect(try await reopened.load() == docks)
        }
    }

    @Test func staleDebouncedRevisionCannotOverwriteFinalFlush() async throws {
        try await withStore { store, _ in
            let latest = dock("Latest")
            try await store.save([latest], revision: 10)
            try await store.save([dock("Old")], revision: 2)
            #expect(try await store.load() == [latest])
        }
    }

    @Test func corruptDataIsReportedAndLeftUnchanged() async throws {
        try await withStore { store, root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bad = Data("broken file".utf8)
            try bad.write(to: store.url)
            await #expect(throws: (any Error).self) { try await store.load() }
            #expect(try Data(contentsOf: store.url) == bad)
        }
    }

    @Test func futureVersionIsRejectedWithoutChangingFile() async throws {
        try await withStore { store, root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(DockStore.Document(version: 99, docks: [dock("Future")]))
            try bytes.write(to: store.url)
            await #expect(throws: DockStore.StoreError.self) { try await store.load() }
            #expect(try Data(contentsOf: store.url) == bytes)
        }
    }

    @Test func invalidCoordinatesAreSanitizedBeforeEncoding() async throws {
        try await withStore { store, _ in
            var invalid = dock("Invalid")
            invalid.position = DockPosition(x: .nan, y: .infinity)
            invalid.placement.relativeX = .nan
            try await store.save([invalid], revision: 1)
            let restored = try #require(try await store.load()?.first)
            #expect(DockPositioning.valid(restored.position))
            #expect(restored.placement.relativeX == 0.5)
        }
    }

    @Test func duplicateIdentifiersCannotReplaceValidFile() async throws {
        try await withStore { store, _ in
            let original = dock("Original")
            try await store.save([original], revision: 1)
            await #expect(throws: DockStore.StoreError.self) { try await store.save([original, original], revision: 2) }
            #expect(try await store.load() == [original])
        }
    }

    @Test func writeErrorsAreSurfaced() async throws {
        try await withStore { _, root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let blockingFile = root.appendingPathComponent("not-a-directory")
            try Data([0]).write(to: blockingFile)
            let blocked = DockStore(url: blockingFile.appendingPathComponent("docks.json"))
            await #expect(throws: (any Error).self) { try await blocked.save([dock("Test")], revision: 1) }
        }
    }
    @Test func savedConfigurationAndItsDirectoryArePrivate() async throws {
        try await withStore { store, root in
            try await store.save([dock("Private")], revision: 1)
            let fileMode = try #require(FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)
            let directoryMode = try #require(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
            #expect(fileMode.intValue == 0o600)
            #expect(directoryMode.intValue == 0o700)
        }
    }

}
