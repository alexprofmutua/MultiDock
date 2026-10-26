import Foundation
import CoreGraphics
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct WindowPreviewTests {
    let frame = CGRect(x: -900, y: 150, width: 600, height: 400)
    private func window(id: UInt32 = 1, pid: Int32 = 20, title: String = "Document", frame: CGRect? = nil) -> PreviewWindowDescriptor {
        PreviewWindowDescriptor(id: id, pid: pid, title: title, frame: frame ?? self.frame, isOnScreen: true)
    }
    @Test func uniqueTitleAndGeometryMatchWithRoundingTolerance() {
        let target = window()
        let candidate = AccessibleWindowDescriptor(title: target.title, frame: frame.offsetBy(dx: 1, dy: -1))
        #expect(PreviewWindowMatching.uniqueIndex(for: target, shared: [target], accessible: [candidate]) == 0)
    }
    @Test func duplicateAccessibilityMatchesAreRefused() {
        let target = window()
        let candidate = AccessibleWindowDescriptor(title: target.title, frame: frame)
        #expect(PreviewWindowMatching.uniqueIndex(for: target, shared: [target], accessible: [candidate, candidate]) == nil)
    }
    @Test func duplicateScreenWindowsAreRefusedEvenWithOneAXMatch() {
        let target = window()
        #expect(PreviewWindowMatching.uniqueIndex(for: target, shared: [target, window(id: 2)],
            accessible: [AccessibleWindowDescriptor(title: target.title, frame: frame)]) == nil)
    }
    @Test func sameTitleDifferentFrameAndOtherProcessesDoNotCauseAmbiguity() {
        let target = window()
        let second = window(id: 2, frame: frame.offsetBy(dx: 50, dy: 0))
        #expect(PreviewWindowMatching.uniqueIndex(for: target, shared: [target, second, window(id: 3, pid: 99)],
            accessible: [AccessibleWindowDescriptor(title: "Document", frame: second.frame),
                         AccessibleWindowDescriptor(title: "Document", frame: frame)]) == 1)
    }
    @Test func closedRenamedResizedAndInvalidWindowsAreRefused() {
        let target = window()
        for accessible in [[], [AccessibleWindowDescriptor(title: "Renamed", frame: frame)],
                           [AccessibleWindowDescriptor(title: "Document", frame: CGRect(x: -900, y: 150, width: 600, height: 500))],
                           [AccessibleWindowDescriptor(title: "Document", frame: .zero)]] {
            #expect(PreviewWindowMatching.uniqueIndex(for: target, shared: [target], accessible: accessible) == nil)
        }
        let invalid = window(frame: CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20))
        #expect(!invalid.canCapture)
        #expect(!PreviewWindowDescriptor.valid(invalid.frame))
    }
    @Test func offscreenWindowsRemainDiscoverableWithoutCapture() {
        let hidden = PreviewWindowDescriptor(id: 2, pid: 20, title: "Hidden", frame: frame, isOnScreen: false)
        #expect(!hidden.canCapture)
        #expect(PreviewWindowDescriptor.valid(hidden.frame))
    }
    @Test func oldArchiveMigratesWithPreviewsDisabledAndExistingBehaviorRetained() throws {
        var dock = DockConfiguration(name: "Saved", orientation: .vertical, position: DockPosition(x: -300, y: 90))
        dock.behavior.autoHideEnabled = true
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(version: 3, docks: [dock]))) as! [String: Any]
        var records = root["docks"] as! [[String: Any]]
        var behavior = records[0]["behavior"] as! [String: Any]
        behavior.removeValue(forKey: "windowPreviewsEnabled")
        records[0]["behavior"] = behavior
        root["docks"] = records
        let result = try DockArchive.recover(JSONSerialization.data(withJSONObject: root))
        #expect(result.needsRewrite && result.notices.isEmpty)
        #expect(result.docks == [dock] && !result.docks[0].behavior.windowPreviewsEnabled)
    }
    @Test func previewPreferenceRoundTripsAndCorruptionDoesNotDiscardOtherBehavior() throws {
        var dock = DockConfiguration(name: "Saved", position: DockPosition(x: 40, y: 90))
        dock.behavior.windowPreviewsEnabled = true
        dock.behavior.magnificationEnabled = true
        #expect(try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(dock)) == dock)
        #expect(dock.duplicate(name: "Copy").behavior.windowPreviewsEnabled)
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(docks: [dock]))) as! [String: Any]
        var records = root["docks"] as! [[String: Any]]
        var behavior = records[0]["behavior"] as! [String: Any]
        behavior["windowPreviewsEnabled"] = "invalid"
        records[0]["behavior"] = behavior
        root["docks"] = records
        let recovered = try DockArchive.recover(JSONSerialization.data(withJSONObject: root))
        #expect(!recovered.docks[0].behavior.windowPreviewsEnabled)
        #expect(recovered.docks[0].behavior.magnificationEnabled)
        #expect(recovered.notices.count == 1)
    }
}
