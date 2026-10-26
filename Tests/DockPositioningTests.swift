import CoreGraphics
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct DockPositioningTests {
    private var main: DockDisplay {
        DockDisplay(id: "main", name: "Main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 806), scale: 2, isPrimary: true)
    }
    private var external: DockDisplay {
        DockDisplay(id: "external", name: "External", frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: -1920, y: 250, width: 1920, height: 1006))
    }
    private func dock() -> DockConfiguration {
        DockConfiguration(name: "Position", position: DockPosition(x: 300, y: 300),
            applications: (0..<3).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "Test") })
    }

    @Test func allEdgesAndCornersRespectMenuBarAndDockInsets() throws {
        for orientation in DockOrientation.allCases {
            for anchor in DockAnchor.allCases {
                var configuration = dock()
                configuration.orientation = orientation
                DockPositioning.place(&configuration, on: main, anchor: anchor)
                let result = try #require(DockPositioning.resolve(configuration, displays: [main], restoring: true))
                #expect(main.visibleFrame.contains(result.frame))
                if anchor.left { #expect(result.frame.minX == main.visibleFrame.minX) }
                if anchor.right { #expect(result.frame.maxX == main.visibleFrame.maxX) }
                if anchor.top { #expect(result.frame.maxY == main.visibleFrame.maxY) }
                if anchor.bottom { #expect(result.frame.minY == main.visibleFrame.minY) }
            }
        }
    }

    @Test func snappingOnDropChoosesNearestEdgesAndCorners() {
        var configuration = dock()
        let size = DockLayout.size(for: configuration)
        let nearCorner = CGRect(x: main.visibleFrame.maxX - size.width - 6, y: main.visibleFrame.maxY - size.height - 4,
                                width: size.width, height: size.height)
        DockPositioning.finishDrag(nearCorner, dock: &configuration, displays: [main])
        #expect(configuration.placement.anchor == .topRight)
        #expect(configuration.position.x == Double(main.visibleFrame.maxX - size.width))
        #expect(configuration.position.y == Double(main.visibleFrame.maxY - size.height))
    }

    @Test func disabledSnappingKeepsNearEdgePosition() {
        var configuration = dock()
        configuration.placement.snappingEnabled = false
        let frame = CGRect(x: 6, y: 76, width: 194, height: 52)
        DockPositioning.finishDrag(frame, dock: &configuration, displays: [main])
        #expect(configuration.placement.anchor == .free)
        #expect(configuration.position == DockPosition(x: 6, y: 76))
    }

    @Test func resizingFreeDockPreservesOrigin() throws {
        var configuration = dock()
        DockPositioning.finishDrag(CGRect(origin: CGPoint(x: 300, y: 300), size: DockLayout.size(for: configuration)),
                                  dock: &configuration, displays: [main])
        configuration.applications += (3..<10).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "Test") }
        let result = try #require(DockPositioning.resolve(configuration, displays: [main], restoring: false))
        #expect(result.frame.origin == CGPoint(x: 300, y: 300))
    }

    @Test func resizingPinnedDockKeepsChosenEdges() throws {
        var configuration = dock()
        DockPositioning.place(&configuration, on: main, anchor: .topRight)
        configuration.applications += (3..<20).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "Test") }
        configuration.appearance.iconSize = 64
        let result = try #require(DockPositioning.resolve(configuration, displays: [main], restoring: false))
        #expect(result.frame.maxX == main.visibleFrame.maxX)
        #expect(result.frame.maxY == main.visibleFrame.maxY)
    }

    @Test func negativeAndRearrangedScreenOriginsUseLocalTravelFractions() throws {
        var configuration = dock()
        configuration.placement = DockPlacement(displayID: external.id, relativeX: 0.25, relativeY: 0.75)
        let result = try #require(DockPositioning.resolve(configuration, displays: [main, external], restoring: true))
        #expect(result.frame.minX == external.visibleFrame.minX + (external.visibleFrame.width - result.frame.width) * 0.25)
        #expect(result.frame.minY == external.visibleFrame.minY + (external.visibleFrame.height - result.frame.height) * 0.75)
        let moved = DockDisplay(id: external.id, name: "Moved", frame: external.frame.offsetBy(dx: 4000, dy: -800),
                               visibleFrame: external.visibleFrame.offsetBy(dx: 4000, dy: -800))
        let rearranged = try #require(DockPositioning.resolve(configuration, displays: [main, moved], restoring: true))
        #expect(rearranged.frame.origin == CGPoint(x: result.frame.minX + 4000, y: result.frame.minY - 800))
    }

    @Test func disconnectFallbackRetainsHomeAndReconnectRestoresIt() throws {
        var configuration = dock()
        DockPositioning.place(&configuration, on: external, anchor: .bottomRight)
        let home = configuration
        let fallback = try #require(DockPositioning.resolve(configuration, displays: [main], restoring: true))
        DockPositioning.recordLayout(fallback, in: &configuration)
        #expect(main.visibleFrame.contains(fallback.frame))
        #expect(configuration.placement == home.placement)
        let restored = try #require(DockPositioning.resolve(configuration, displays: [external, main], restoring: true))
        #expect(restored.display.id == external.id)
        #expect(restored.frame.origin == CGPoint(x: home.position.x, y: home.position.y))
    }

    @Test func movingFallbackIntentionallyChoosesNewHome() throws {
        var configuration = dock()
        DockPositioning.place(&configuration, on: external, anchor: .left)
        let frame = CGRect(x: 250, y: 250, width: 194, height: 52)
        DockPositioning.finishDrag(frame, dock: &configuration, displays: [main])
        let restored = try #require(DockPositioning.resolve(configuration, displays: [external, main], restoring: true))
        #expect(configuration.placement.displayID == main.id)
        #expect(restored.display.id == main.id)
        #expect(restored.frame.origin == frame.origin)
    }

    @Test func resolutionAndScalingChangesDoNotMixPixelsWithPoints() throws {
        var configuration = dock()
        configuration.placement = DockPlacement(displayID: main.id, relativeX: 0.4, relativeY: 0.6)
        let atTwoX = try #require(DockPositioning.resolve(configuration, displays: [main], restoring: true))
        var oneX = main
        oneX.scale = 1
        let atOneX = try #require(DockPositioning.resolve(configuration, displays: [oneX], restoring: true))
        #expect(atTwoX.frame == atOneX.frame)
        let resized = DockDisplay(id: main.id, name: "Smaller", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  visibleFrame: CGRect(x: 50, y: 0, width: 750, height: 575), isPrimary: true)
        let result = try #require(DockPositioning.resolve(configuration, displays: [resized], restoring: true))
        #expect(resized.visibleFrame.contains(result.frame))
        #expect(result.frame.minX == 50 + (750 - result.frame.width) * 0.4)
    }

    @Test func invalidCoordinatesAndFractionsBecomeReachable() throws {
        for position in [DockPosition(x: .nan, y: .infinity), DockPosition(x: 1e300, y: -1e300)] {
            var configuration = dock()
            configuration.position = position
            configuration.placement = DockPlacement(displayID: "missing", relativeX: .nan, relativeY: 100)
            let result = try #require(DockPositioning.resolve(configuration, displays: [main], restoring: true))
            #expect(main.visibleFrame.contains(result.frame))
            #expect(result.frame.minX.isFinite && result.frame.minY.isFinite)
        }
        #expect(DockPositioning.resolve(dock(), displays: [], restoring: true) == nil)
    }

    @Test func dragUsesLargestScreenIntersectionRatherThanScreenArrayOrder() {
        let frame = CGRect(x: -180, y: 300, width: 194, height: 52)
        #expect(DockPositioning.display(for: frame, in: [main, external])?.id == external.id)
        #expect(DockPositioning.display(for: frame, in: [external, main])?.id == external.id)
    }

    @Test func longDocksFitBothScreenOrientations() throws {
        for orientation in DockOrientation.allCases {
            var configuration = dock()
            configuration.orientation = orientation
            configuration.applications += (3..<100).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "Test") }
            DockPositioning.place(&configuration, on: main, anchor: .topRight)
            let result = try #require(DockPositioning.resolve(configuration, displays: [main], restoring: true))
            #expect(main.visibleFrame.contains(result.frame))
        }
    }

    @Test func growingLongDockDoesNotJumpToNeighboringDisplay() throws {
        var configuration = dock()
        configuration.position = DockPosition(x: -1000, y: 400)
        configuration.placement.displayID = external.id
        configuration.applications += (3..<100).map { ApplicationItem(bundleIdentifier: "long.\($0)", name: "Test") }
        let result = try #require(DockPositioning.resolve(configuration, displays: [main, external], restoring: false))
        #expect(result.display.id == external.id)
        #expect(external.visibleFrame.contains(result.frame))
    }

    @Test func legacyConfigurationWithoutPlacementRetainsAbsolutePosition() throws {
        let configuration = dock()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object.removeValue(forKey: "placement")
        let restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        let result = try #require(DockPositioning.resolve(restored, displays: [main], restoring: true))
        #expect(result.frame.origin == CGPoint(x: 300, y: 300))
    }
}
