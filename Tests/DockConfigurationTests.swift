import CoreGraphics
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct DockConfigurationTests {
    @Test func configurationRoundTripPreservesIdentityAndCoordinates() throws {
        let original = DockConfiguration(name: "Work", orientation: .vertical,
                                         position: DockPosition(x: -1024, y: 48),
                                         applications: [ApplicationItem(bundleIdentifier: "com.apple.finder", name: "Finder")])
        let restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.id == original.id)
    }

    @Test func separateDocksHaveIndependentIdentityAndItems() {
        var first = DockConfiguration(name: "One", position: DockPosition(x: 0, y: 0))
        let second = DockConfiguration(name: "Two", position: DockPosition(x: 20, y: 20))
        first.applications.append(ApplicationItem(bundleIdentifier: "example.test", name: "Test"))
        #expect(first.id != second.id)
        #expect(second.applications.isEmpty)
    }

    @Test func orientationSwapsDimensionsIncludingEmptyDock() {
        for count in [0, 1, 3] {
            var configuration = DockConfiguration(name: "Test", position: DockPosition(x: 0, y: 0),
                applications: (0..<count).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "Test") })
            let horizontal = DockLayout.size(for: configuration)
            configuration.orientation = .vertical
            let vertical = DockLayout.size(for: configuration)
            #expect(horizontal.width == vertical.height)
            #expect(horizontal.height == vertical.width)
            #expect(horizontal.width > horizontal.height)
        }
    }

    @Test func constrainToDisplayWithNegativeOrigin() {
        let frame = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let size = CGSize(width: 200, height: 62)
        #expect(DockLayout.constrainedOrigin(DockPosition(x: 500, y: 1000), size: size, visibleFrame: frame)
                == CGPoint(x: -200, y: 638))
        #expect(DockLayout.constrainedOrigin(DockPosition(x: -2000, y: -800), size: size, visibleFrame: frame)
                == CGPoint(x: -1440, y: -200))
    }

    @Test func oversizedDockPinsToVisibleOrigin() {
        #expect(DockLayout.constrainedOrigin(DockPosition(x: 800, y: 800), size: CGSize(width: 500, height: 500),
                                             visibleFrame: CGRect(x: 50, y: 60, width: 100, height: 100))
                == CGPoint(x: 50, y: 60))
    }
}
