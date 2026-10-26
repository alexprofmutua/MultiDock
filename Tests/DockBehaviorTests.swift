import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct DockBehaviorTests {
    private func dock() -> DockConfiguration {
        DockConfiguration(name: "Work", position: DockPosition(x: -600, y: 50),
                          applications: [ApplicationItem(bundleIdentifier: "example.editor", name: "Editor")])
    }
    @Test func endpointWaveIsContinuousAndContained() {
        for orientation in DockOrientation.allCases {
            for count in [1, 2, 3, 12] {
                for icon in [24.0, 64.0] {
                    var appearance = DockAppearance()
                    appearance.iconSize = icon
                    let behavior = DockBehavior(magnificationEnabled: true, magnificationStrength: 1)
                    let dock = DockConfiguration(name: "Endpoints", orientation: orientation, position: DockPosition(x: 0, y: 0),
                        applications: (0..<count).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "App") }, appearance: appearance, behavior: behavior)
                    let metrics = DockMetrics(appearance, behavior: behavior)
                    let length = DockLayout.contentLength(for: dock)
                    let bounds = orientation == .horizontal ? CGRect(x: 0, y: 0, width: length, height: metrics.itemSide)
                        : CGRect(x: 0, y: 0, width: metrics.itemSide, height: length)
                    var previous: [DockIconPlacement]?
                    for coordinate in stride(from: -2.0, through: Double(length) + 2, by: 0.5) {
                        let pointer = orientation == .horizontal ? CGPoint(x: coordinate, y: bounds.midY) : CGPoint(x: bounds.midX, y: coordinate)
                        let placements = DockMagnificationLayout.placements(count: count, bounds: bounds, pointer: pointer,
                            orientation: orientation, appearance: appearance, behavior: behavior, reduceMotion: false)
                        #expect(placements.allSatisfy { bounds.insetBy(dx: -0.001, dy: -0.001).contains($0.frame) })
                        if let previous {
                            for (a, b) in zip(previous, placements) {
                                #expect(abs(a.frame.minX - b.frame.minX) < 2)
                                #expect(abs(a.frame.minY - b.frame.minY) < 2)
                            }
                        }
                        previous = placements
                    }
                }
            }
        }
    }

    @Test func cycleOrderHandlesClosingWindowsAndApplicationSwitches() {
        let a = UUID(), b = UUID(), c = UUID()
        var cursor = WindowCycleCursor()
        #expect(cursor.select(application: "A", windows: [a, b, c], cycling: true) == a)
        #expect(cursor.select(application: "A", windows: [a, b, c], cycling: true) == b)
        #expect(cursor.select(application: "A", windows: [a, c], cycling: true) == a)
        #expect(cursor.select(application: "B", windows: [b, c], cycling: true) == b)
        #expect(cursor.select(application: "A", windows: [a, c], cycling: true) == a)
        #expect(cursor.select(application: "A", windows: [], cycling: true) == nil)
        #expect(cursor.select(application: "A", windows: [c], cycling: true) == c)
        #expect(cursor.select(application: "A", windows: [a, c], cycling: false) == a)
    }

    @Test func oldConfigurationsGetDefaultOffInteractions() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dock())) as! [String: Any]
        object.removeValue(forKey: "behavior")
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.behavior == DockBehavior())
        #expect(!decoded.behavior.magnificationEnabled && !decoded.behavior.autoHideEnabled && !decoded.behavior.isCollapsed)
    }
    @Test func customBehaviorRoundTripsAndDuplicatesIndependently() throws {
        var original = dock()
        original.behavior = DockBehavior(magnificationEnabled: true, magnificationStrength: 0.75,
            magnificationDuration: 0.2, autoHideEnabled: true, autoHideDelay: 2, visibilityDuration: 0.3,
            showsRunningIndicators: true, collapseEnabled: true, isCollapsed: true)
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        var copy = original.duplicate(name: "Copy")
        #expect(copy.behavior == original.behavior && copy.id != original.id)
        copy.behavior.autoHideEnabled = false
        #expect(original.behavior.autoHideEnabled)
    }
    @Test func invalidBehaviorValuesAreFiniteAndBounded() {
        let value = DockBehavior(magnificationStrength: .nan, magnificationDuration: -.infinity,
                                autoHideDelay: 500, visibilityDuration: -1, isCollapsed: true).normalized
        #expect(value.magnificationStrength == 0.5 && value.magnificationDuration == 0.12)
        #expect(value.autoHideDelay == 5 && value.visibilityDuration == 0.05 && !value.isCollapsed)
    }
    @Test func magnificationFallsOffSmoothlyAndSymmetrically() {
        let behavior = DockBehavior(magnificationEnabled: true, magnificationStrength: 0.8)
        let center = CGPoint(x: 100, y: 100)
        func scale(_ dx: Double) -> CGFloat {
            DockInteractionGeometry.scale(pointer: CGPoint(x: 100 + dx, y: 100), center: center,
                                          itemSide: 60, behavior: behavior, reduceMotion: false)
        }
        #expect(abs(scale(0) - 1.8) < 0.0001)
        #expect(scale(30) == scale(-30))
        #expect(scale(0) > scale(30) && scale(30) > scale(70))
        #expect(scale(108) == 1 && scale(1000) == 1)
        #expect(abs(scale(107.9) - scale(108)) < 0.001)
    }
    @Test func reducedMotionDisabledMagnificationAndInvalidPointerAreStationary() {
        for point: CGPoint? in [nil, CGPoint(x: CGFloat.nan, y: 0), .zero] {
            #expect(DockInteractionGeometry.scale(pointer: point, center: .zero, itemSide: 48,
                behavior: DockBehavior(magnificationEnabled: true), reduceMotion: true) == 1)
            #expect(DockInteractionGeometry.scale(pointer: point, center: .zero, itemSide: 48,
                behavior: DockBehavior(), reduceMotion: false) == 1)
        }
    }
    @Test func reservedMagnificationEnvelopeFitsBothOrientationsWithoutCollapseSpace() {
        var configuration = dock()
        configuration.behavior.magnificationEnabled = true
        configuration.behavior.magnificationStrength = 1
        let metrics = DockMetrics(configuration.appearance, behavior: configuration.behavior)
        #expect(metrics.itemSide >= metrics.iconSize * 2 + 8)
        let horizontal = DockLayout.size(for: configuration)
        configuration.orientation = .vertical
        let vertical = DockLayout.size(for: configuration)
        #expect(horizontal.width == vertical.height && horizontal.height == vertical.width)
        configuration.behavior.collapseEnabled = true
        #expect(DockLayout.size(for: configuration) == vertical)

    }
    @Test func nearbyRevealTabsStayDistinctAndWithinNegativeDisplayBounds() throws {
        let bounds = CGRect(x: -1280, y: -100, width: 1280, height: 760)
        let dockFrame = CGRect(x: -1260, y: 0, width: 200, height: 60)
        var frames: [CGRect] = []
        for index in 0..<30 {
            let frame = try #require(DockInteractionGeometry.revealFrame(dockFrame: dockFrame,
                orientation: index.isMultiple(of: 2) ? .horizontal : .vertical, visibleFrame: bounds, occupied: frames))
            #expect(bounds.contains(frame))
            #expect(!frames.contains(where: { $0.intersects(frame) }))
            frames.append(frame)
        }
    }
    @Test func noAvailableRevealSpaceRequestsVisibleFallback() {
        let bounds = CGRect(x: 0, y: 0, width: 30, height: 20)
        #expect(DockInteractionGeometry.revealFrame(dockFrame: bounds, orientation: .horizontal,
            visibleFrame: bounds, occupied: [bounds]) == nil)
        #expect(DockInteractionGeometry.revealFrame(dockFrame: .zero, orientation: .vertical,
            visibleFrame: .zero, occupied: []) == nil)
    }
    @Test func multipleRunningInstancesRemainIndicatedUntilLastTermination() {
        var state = RunningApplicationState()
        state.launched(pid: 10, bundleIdentifier: "example.Editor")
        state.launched(pid: 11, bundleIdentifier: "example.editor")
        state.terminated(pid: 10)
        #expect(state.isRunning("example.Editor"))
        state.terminated(pid: 99)
        #expect(state.isRunning("example.editor"))
        state.terminated(pid: 11)
        #expect(!state.isRunning("example.editor"))
    }
    @Test func phaseFiveArchiveMigratesWithoutChangingExistingConfiguration() throws {
        let original = dock()
        var envelope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(version: 2, docks: [original]))) as! [String: Any]
        var records = envelope["docks"] as! [[String: Any]]
        records[0].removeValue(forKey: "behavior")
        envelope["docks"] = records
        let result = try DockArchive.recover(JSONSerialization.data(withJSONObject: envelope))
        #expect(result.docks == [original] && result.needsRewrite)
        #expect(result.notices.isEmpty)
    }
    @Test func corruptBehaviorFieldDoesNotDiscardHealthyNeighbors() throws {
        var original = dock()
        original.behavior.autoHideEnabled = true
        original.behavior.magnificationStrength = 0.75
        var envelope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(docks: [original]))) as! [String: Any]
        var records = envelope["docks"] as! [[String: Any]]
        var behavior = records[0]["behavior"] as! [String: Any]
        behavior["autoHideDelay"] = "broken"
        records[0]["behavior"] = behavior
        envelope["docks"] = records
        let result = try DockArchive.recover(JSONSerialization.data(withJSONObject: envelope))
        #expect(result.docks[0].behavior.autoHideEnabled)
        #expect(result.docks[0].behavior.magnificationStrength == 0.75)
        #expect(result.docks[0].behavior.autoHideDelay == 0.8)
        #expect(result.needsRewrite && !result.notices.isEmpty)
    }
    @Test func hoverStripsMeetUsableScreenEdgesWithoutFolderIcons() throws {
        let screen = CGRect(x: -1000, y: 25, width: 1000, height: 775)
        let left = try #require(DockInteractionGeometry.revealFrame(dockFrame: CGRect(x: -1000, y: 200, width: 68, height: 250),
            orientation: .vertical, visibleFrame: screen, occupied: []))
        #expect(left.minX == screen.minX && left.size == CGSize(width: 8, height: 44))
        let bottom = try #require(DockInteractionGeometry.revealFrame(dockFrame: CGRect(x: -500, y: 25, width: 250, height: 68),
            orientation: .horizontal, visibleFrame: screen, occupied: []))
        #expect(bottom.minY == screen.minY && bottom.size == CGSize(width: 44, height: 8))
    }

    @Test func waveMovesNeighborsAndNeverOverlapsInEitherOrientation() {
        let style = DockAppearance()
        let behavior = DockBehavior(magnificationEnabled: true, magnificationStrength: 1)
        for orientation in DockOrientation.allCases {
            for count in [1, 3, 30] {
                let configuration = DockConfiguration(name: "Wave", position: DockPosition(x: 0, y: 0),
                    applications: (0..<count).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "App") },
                    appearance: style, behavior: behavior)
                let length = DockLayout.contentLength(for: configuration)
                let bounds = orientation == .horizontal ? CGRect(x: 0, y: 0, width: length, height: 72)
                    : CGRect(x: 0, y: 0, width: 72, height: length)
                let resting = DockMagnificationLayout.placements(count: count, bounds: bounds, pointer: nil,
                    orientation: orientation, appearance: style, behavior: behavior, reduceMotion: false)
                let pointer = CGPoint(x: resting[0].frame.midX, y: resting[0].frame.midY)
                let wave = DockMagnificationLayout.placements(count: count, bounds: bounds, pointer: pointer,
                    orientation: orientation, appearance: style, behavior: behavior, reduceMotion: false)
                #expect(wave[0].scale == 2)
                #expect(wave.allSatisfy { bounds.contains($0.frame) })
                for index in 1..<count {
                    #expect(!wave[index - 1].frame.intersects(wave[index].frame))
                }
                if count > 1 { #expect(wave[1].frame != resting[1].frame) }
                let reduced = DockMagnificationLayout.placements(count: count, bounds: bounds, pointer: pointer,
                    orientation: orientation, appearance: style, behavior: behavior, reduceMotion: true)
                #expect(reduced == resting)
            }
        }
    }
    @Test func waveUsesStableRestCoordinatesAndIgnoresInvalidPointer() {
        let bounds = CGRect(x: 0, y: 0, width: 176, height: 56)
        let behavior = DockBehavior(magnificationEnabled: true)
        func positions(_ point: CGPoint?) -> [DockIconPlacement] {
            DockMagnificationLayout.placements(count: 3, bounds: bounds, pointer: point,
                orientation: .horizontal, appearance: DockAppearance(), behavior: behavior, reduceMotion: false)
        }
        #expect(positions(CGPoint(x: CGFloat.nan, y: 0)) == positions(nil))
        #expect(positions(CGPoint(x: 88, y: 0)) == positions(CGPoint(x: 88, y: 56)))
        #expect(positions(CGPoint(x: 88, y: 20))[1].scale == 1.5)
    }

}
