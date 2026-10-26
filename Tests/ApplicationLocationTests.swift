import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct ApplicationLocationTests {
    private func fixture(_ test: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.fixture.\(UUID().uuidString)", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try test(app, root)
    }

    @Test func documentSupportUsesDeclaredTypesWithoutForcingIncompatibleItems() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("file.txt"), image = folder.appendingPathComponent("image.png")
        try Data("text".utf8).write(to: text); try Data().write(to: image)
        let declared: [[String: Any]] = [["LSItemContentTypes": ["public.plain-text", "public.folder"], "CFBundleTypeRole": "Editor"]]
        #expect(ApplicationDocumentSupport.supports(text, declarations: declared))
        #expect(ApplicationDocumentSupport.supports(folder, declarations: declared))
        #expect(!ApplicationDocumentSupport.supports(image, declarations: declared))
        #expect(!ApplicationDocumentSupport.supports(text, declarations: []))
    }

    @Test func fileDropClassificationRejectsUnsafeAndMixedInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("file.txt")
        try Data("keep".utf8).write(to: text)
        #expect(DockFileDropClassifier.classify([text, directory]) == .documents)
        #expect(DockFileDropClassifier.classify([]) == .invalid)
        #expect(DockFileDropClassifier.classify([directory.appendingPathComponent("missing")]) == .invalid)
        #expect(DockFileDropClassifier.classify([URL(string: "https://example.com/file.txt")!]) == .invalid)
        #expect(DockFileDropClassifier.classify(Array(repeating: text, count: 257)) == .invalid)
        let app = directory.appendingPathComponent("Invalid.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(DockFileDropClassifier.classify([text, app]) == .invalid)
        #expect(try Data(contentsOf: text) == Data("keep".utf8))
    }

    @Test func folderListingIsBoundedNonrecursiveAndReadOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<120 { try Data("safe".utf8).write(to: directory.appendingPathComponent("file\(index).txt")) }
        try Data().write(to: directory.appendingPathComponent("Nested/hidden-deep.txt"))
        let item = DockItem(bundleIdentifier: "test.folder", name: "Folder", location: directory, kind: .folder)
        let contents = try FolderReference.contents(item)
        #expect(contents.count == 100)
        #expect(contents.allSatisfy { $0.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path })
        #expect(try Data(contentsOf: directory.appendingPathComponent("file0.txt")) == Data("safe".utf8))
        #expect(throws: (any Error).self) { try FolderReference.validate(directory.appendingPathComponent("missing")) }
    }

    @Test func validBundleAndSymlinkResolveToSameApplication() throws {
        try fixture { app, root in
            let link = root.appendingPathComponent("App link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
            let direct = try ApplicationLocation.validate(app)
            let linked = try ApplicationLocation.validate(link)
            #expect(direct.url == linked.url)
            #expect(direct.bundleIdentifier == linked.bundleIdentifier)
        }
    }

    @Test func finderAliasResolvesToApplication() throws {
        try fixture { app, root in
            let alias = root.appendingPathComponent("App alias")
            let data = try app.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: alias)
            #expect(try ApplicationLocation.validate(alias).url == app.standardizedFileURL.resolvingSymlinksInPath())
        }
    }

    @Test func rejectsDeletedAndNonFilePaths() throws {
        #expect(throws: (any Error).self) { try ApplicationLocation.validate(URL(string: "https://example.com/App.app")!) }
        try fixture { app, _ in
            try FileManager.default.removeItem(at: app)
            #expect(throws: (any Error).self) { try ApplicationLocation.validate(app) }
        }
    }

    @Test func rejectsOrdinaryFoldersAndMalformedApplicationBundles() throws {
        try fixture { _, root in
            #expect(throws: (any Error).self) { try ApplicationLocation.validate(root) }
            let fake = root.appendingPathComponent("Fake.app")
            try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try ApplicationLocation.validate(fake) }
        }
    }

    @Test func rejectsMissingOrInaccessibleExecutable() throws {
        try fixture { app, _ in
            let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: executable.path)
            #expect(throws: (any Error).self) { try ApplicationLocation.validate(app) }
            try FileManager.default.removeItem(at: executable)
            #expect(throws: (any Error).self) { try ApplicationLocation.validate(app) }
        }
    }

    @Test func rejectsDirectoryMasqueradingAsExecutable() throws {
        try fixture { app, _ in
            let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try ApplicationLocation.validate(app) }
        }
    }

    @Test func acceptsFindersSpecialBundlePackageType() throws {
        try fixture { app, _ in
            let info = app.appendingPathComponent("Contents/Info.plist")
            var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: String])
            plist["CFBundlePackageType"] = "FNDR"
            plist["CFBundleIdentifier"] = "com.apple.finder"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
            #expect(try ApplicationLocation.validate(app).bundleIdentifier == "com.apple.finder")
        }
    }

    @Test func replacementMetadataIsReadAgainInsteadOfUsingCachedBundle() throws {
        try fixture { app, _ in
            let original = try ApplicationLocation.validate(app)
            let info = app.appendingPathComponent("Contents/Info.plist")
            var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: String])
            plist["CFBundleIdentifier"] = "test.replaced"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
            let replacement = try ApplicationLocation.validate(app)
            #expect(replacement.bundleIdentifier != original.bundleIdentifier)
            #expect(replacement.bundleIdentifier == "test.replaced")
        }
    }

    @Test func bookmarkFollowsRelocatedApplication() throws {
        try fixture { app, root in
            let data = try app.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let moved = root.appendingPathComponent("Relocated.app")
            try FileManager.default.moveItem(at: app, to: moved)
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            #expect(try ApplicationLocation.validate(resolved).url == moved.standardizedFileURL.resolvingSymlinksInPath())
        }
    }
    @Test func executablePathsCannotEscapeTheBundle() throws {
        try fixture { app, _ in
            let info = app.appendingPathComponent("Contents/Info.plist")
            var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: String])
            for executable in ["/bin/sh", "../../bin/sh", "../Fixture", ".", ".."] {
                plist["CFBundleExecutable"] = executable
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
                #expect(throws: (any Error).self) { try ApplicationLocation.validate(app) }
            }
        }
    }

}
