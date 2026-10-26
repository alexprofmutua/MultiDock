import Foundation
import CoreGraphics

/// ScreenCaptureKit and Accessibility both use the global, top-left display coordinate system.
struct PreviewWindowDescriptor: Equatable, Sendable, Identifiable {
    let id: UInt32
    let pid: Int32
    let title: String
    let frame: CGRect
    let isOnScreen: Bool

    var canCapture: Bool { isOnScreen && Self.valid(frame) }
    static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 1 && frame.height > 1
    }
}

struct AccessibleWindowDescriptor: Sendable {
    let title: String
    let frame: CGRect
}

enum PreviewWindowMatching {
    /// There is no documented cross-framework window-ID bridge. Refuse ambiguous matches.
    static func uniqueIndex(for window: PreviewWindowDescriptor, shared: [PreviewWindowDescriptor],
                            accessible: [AccessibleWindowDescriptor]) -> Int? {
        guard PreviewWindowDescriptor.valid(window.frame) else { return nil }
        func matches(_ title: String, _ frame: CGRect) -> Bool {
            title == window.title && PreviewWindowDescriptor.valid(frame)
                && abs(frame.minX - window.frame.minX) <= 2 && abs(frame.minY - window.frame.minY) <= 2
                && abs(frame.width - window.frame.width) <= 2 && abs(frame.height - window.frame.height) <= 2
        }
        guard shared.filter({ $0.pid == window.pid && matches($0.title, $0.frame) }).count == 1 else { return nil }
        let indices = accessible.indices.filter { matches(accessible[$0].title, accessible[$0].frame) }
        return indices.count == 1 ? indices.first : nil
    }

}
