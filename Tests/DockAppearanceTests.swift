import CoreGraphics
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import MultiDockCore
#else
@testable import MultiDock
#endif

struct DockAppearanceTests {
    private func dock(count: Int, style: DockAppearance = DockAppearance()) -> DockConfiguration {
        DockConfiguration(name: "Design", position: DockPosition(x: 0, y: 0),
            applications: (0..<count).map { ApplicationItem(bundleIdentifier: "test.\($0)", name: "App \($0)") }, appearance: style)
    }

    @Test func hoverLabelsStayVisibleAtEveryScreenEdge() {
        for visible in [CGRect(x: 0, y: 25, width: 1440, height: 850), CGRect(x: -1920, y: -300, width: 1920, height: 1050)] {
            for orientation in DockOrientation.allCases {
                for x in [visible.minX, visible.midX, visible.maxX - 80] {
                    for y in [visible.minY, visible.midY, visible.maxY - 160] {
                        let dock = CGRect(x: x, y: y, width: 80, height: 160)
                        for icon in [CGRect(x: x, y: y, width: 64, height: 64), CGRect(x: x, y: y + 96, width: 64, height: 64)] {
                            let frame = DockLabelGeometry.frame(icon: icon, dock: dock, visible: visible,
                                size: CGSize(width: 280, height: 28), orientation: orientation)
                            #expect(visible.contains(frame))
                            #expect(!frame.intersects(dock))
                        }
                    }
                }
            }
        }
    }

    @Test func revealThemeInheritanceRetainsIndividualChoices() throws {
        var appearance = DockAppearance()
        let global = DockRevealStyle(color: .blue, opacity: 0.6)
        appearance.revealTabStyle = DockRevealStyle(color: .orange, opacity: 0.8)
        #expect(appearance.effectiveRevealStyle(global: global) == global)
        appearance.revealTabUsesGlobal = false
        #expect(appearance.effectiveRevealStyle(global: global) == appearance.revealTabStyle)
        appearance.revealTabUsesGlobal = true
        #expect(appearance.revealTabStyle.color == .orange)
        #expect(try JSONDecoder().decode(DockAppearance.self, from: JSONEncoder().encode(appearance)) == appearance)
    }

    @Test func revealOpacityIsBoundedAndRespectsAccessibility() {
        #expect(DockRevealStyle(opacity: .nan).normalized.opacity == 1)
        #expect(DockRevealStyle(opacity: -1).normalized.opacity == 0.25)
        #expect(DockRevealStyle(opacity: 10).normalized.opacity == 1)
        let style = DockRevealStyle(opacity: 0.4)
        #expect(style.effectiveOpacity(reduceTransparency: false, increaseContrast: false) == 0.4)
        #expect(style.effectiveOpacity(reduceTransparency: true, increaseContrast: false) == 1)
        #expect(style.effectiveOpacity(reduceTransparency: false, increaseContrast: true) == 1)
    }

    @Test func threeDefaultIconsTightlyWrapAt154By52Points() {
        let configuration = dock(count: 3)
        #expect(DockLayout.size(for: configuration) == CGSize(width: 154, height: 52))
        #expect(DockLayout.contentLength(for: configuration) == 128)
    }

    @Test func collapseOptionDoesNotReserveToolbarSpace() {
        var configuration = dock(count: 3)
        let regular = DockLayout.size(for: configuration)
        configuration.behavior.collapseEnabled = true
        #expect(DockLayout.size(for: configuration) == regular)
        configuration.behavior.magnificationEnabled = true
        #expect(DockLayout.size(for: configuration) == CGSize(width: 202, height: 68))
    }

    @Test func horizontalAndVerticalShareProportionsAcrossSizesAndCounts() {
        for count in [0, 1, 3, 80] {
            for size in [24.0, 32.0, 64.0] {
                for spacing in [0.0, 16.0] {
                    for padding in [2.0, 18.0] {
                        let style = DockAppearance(iconSize: size, spacing: spacing, padding: padding)
                        var configuration = dock(count: count, style: style)
                        let horizontal = DockLayout.size(for: configuration, maximumLength: 300)
                        configuration.orientation = .vertical
                        let vertical = DockLayout.size(for: configuration, maximumLength: 300)
                        #expect(horizontal.width == vertical.height)
                        #expect(horizontal.height == vertical.width)
                        #expect(horizontal.width <= 300)
                        #expect(Double(horizontal.height) == size + 8 + padding * 2)
                        let metrics = DockMetrics(style)
                        #expect(horizontal.width - metrics.overhead > 0)
                        if count == 3 {
                            let natural = metrics.overhead + 3 * metrics.itemSide + 2 * metrics.spacing
                            #expect(horizontal.width == min(natural, 300))
                        }
                    }
                }
            }
        }
    }

    @Test func unsafeAppearanceValuesAreClampedBeforeLayout() {
        let style = DockAppearance(iconSize: .infinity, spacing: -10, padding: .nan,
                                   backgroundOpacity: 8, cornerRadius: -12).normalized
        #expect(style.iconSize == 32)
        #expect(style.spacing == 0)
        #expect(style.padding == 6)
        #expect(style.backgroundOpacity == 1)
        #expect(style.cornerRadius == 0)
        #expect(DockLayout.size(for: dock(count: 3, style: style)).width.isFinite)
    }

    @Test func customAppearanceRoundTripsAndRemainsIndependent() throws {
        let style = DockAppearance(iconSize: 48, spacing: 8, padding: 10, colorMode: .dark,
                                   backgroundOpacity: 0.5, cornerRadius: 24)
        let first = dock(count: 3, style: style)
        let second = dock(count: 3)
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
        #expect(decoded.appearance == style)
        #expect(second.appearance == DockAppearance())
    }

    @Test func phaseTwoConfigurationWithoutAppearanceGetsDefaults() throws {
        let configuration = dock(count: 3)
        let encoded = try JSONEncoder().encode(configuration)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "appearance")
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.appearance == DockAppearance())
        #expect(decoded.id == configuration.id)
        #expect(decoded.applications == configuration.applications)
    }

    @Test func accessibilityOverridesOpacityAndDragReturnMotion() {
        let style = DockAppearance(backgroundOpacity: 0.3)
        let standard = DockAccessibility()
        let reduced = DockAccessibility(reduceTransparency: true, reduceMotion: true, increaseContrast: true)
        #expect(standard.surfaceOpacity(for: style) == 0.3)
        #expect(standard.animatesDragCancellation)
        #expect(reduced.surfaceOpacity(for: style) == 1)
        #expect(!reduced.animatesDragCancellation)
    }
    @Test func iconThemesMigrateWithoutChangingExistingChoices() throws {
        let dock = DockConfiguration(name: "Saved", position: DockPosition(x: 10, y: 20),
                                     appearance: DockAppearance(iconSize: 48, colorMode: .dark))
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(version: 4, docks: [dock]))) as! [String: Any]
        var docks = root["docks"] as! [[String: Any]]
        var appearance = docks[0]["appearance"] as! [String: Any]
        appearance.removeValue(forKey: "iconTheme"); appearance.removeValue(forKey: "iconTint")
        docks[0]["appearance"] = appearance; root["docks"] = docks
        let recovered = try DockArchive.recover(JSONSerialization.data(withJSONObject: root))
        #expect(recovered.docks == [dock] && recovered.needsRewrite)
        #expect(!recovered.docks[0].behavior.autoHideEnabled)
    }
    @Test func iconThemesRoundTripAndRepairOnlyTheirInvalidField() throws {
        var dock = DockConfiguration(name: "Saved", position: DockPosition(x: 10, y: 20))
        dock.appearance.iconTheme = .tinted
        dock.appearance.iconTint = .purple
        #expect(try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(dock)) == dock)
        #expect(dock.duplicate(name: "Copy").appearance == dock.appearance)
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(docks: [dock]))) as! [String: Any]
        var docks = root["docks"] as! [[String: Any]]
        var appearance = docks[0]["appearance"] as! [String: Any]
        appearance["iconTheme"] = "invalid"; docks[0]["appearance"] = appearance; root["docks"] = docks
        let recovered = try DockArchive.recover(JSONSerialization.data(withJSONObject: root))
        #expect(recovered.docks[0].appearance.iconTheme == .original)
        #expect(recovered.docks[0].appearance.iconTint == .purple)
        #expect(recovered.notices.count == 1)
    }

    @Test func backgroundColorsMigrateAndRoundTrip() throws {
        var configuration = dock(count: 3)
        configuration.appearance.backgroundColor = .purple
        configuration.appearance.backgroundTintStrength = 0.7
        #expect(try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(version: 5, docks: [configuration]))) as! [String: Any]
        var docks = root["docks"] as! [[String: Any]]
        var appearance = docks[0]["appearance"] as! [String: Any]
        appearance.removeValue(forKey: "backgroundColor")
        appearance.removeValue(forKey: "backgroundTintStrength")
        docks[0]["appearance"] = appearance; root["docks"] = docks
        let recovered = try DockArchive.recover(JSONSerialization.data(withJSONObject: root))
        #expect(recovered.needsRewrite && recovered.notices.isEmpty)
        #expect(recovered.docks[0].appearance.backgroundColor == .material)
        #expect(recovered.docks[0].id == configuration.id)
        #expect(recovered.docks[0].applications == configuration.applications)
    }
    @Test func invalidBackgroundRepairsOnlyItsOwnField() throws {
        var configuration = dock(count: 3)
        configuration.appearance.iconTheme = .tinted
        configuration.appearance.backgroundTintStrength = 0.8
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DockStore.Document(docks: [configuration]))) as! [String: Any]
        var docks = root["docks"] as! [[String: Any]]
        var appearance = docks[0]["appearance"] as! [String: Any]
        appearance["backgroundColor"] = "unknown"
        docks[0]["appearance"] = appearance; root["docks"] = docks
        let recovered = try DockArchive.recover(JSONSerialization.data(withJSONObject: root))
        #expect(recovered.docks[0].appearance.backgroundColor == .material)
        #expect(recovered.docks[0].appearance.backgroundTintStrength == 0.8)
        #expect(recovered.docks[0].appearance.iconTheme == .tinted)
        #expect(DockAppearance(backgroundTintStrength: .nan).normalized.backgroundTintStrength == 0.35)
        #expect(DockAppearance(backgroundTintStrength: 4).normalized.backgroundTintStrength == 1)
    }

}
