import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import ScreenCaptureKit

struct WindowPreview: Identifiable {
    let window: PreviewWindowDescriptor
    var image: CGImage?
    var note: String?
    var id: UInt32 { window.id }
}

@MainActor
protocol WindowPreviewProviding: AnyObject {
    var screenAccess: Bool { get }
    var accessibilityAccess: Bool { get }
    func requestScreenAccess()
    func requestAccessibilityAccess()
    func load(bundleIdentifier: String) async throws -> [WindowPreview]
    func activate(_ window: PreviewWindowDescriptor, bundleIdentifier: String) async throws
}

enum WindowPreviewError: LocalizedError {
    case screenAccess, accessibilityAccess, busy, unavailable, ambiguous, activation
    var errorDescription: String? {
        switch self {
        case .screenAccess: "Screen Recording access is needed to show window thumbnails. Ordinary dock icons work without it."
        case .accessibilityAccess: "Accessibility access is needed to select a particular window. You can still open the application normally."
        case .busy: "A previous preview request is finishing. Close this popover and hover again."
        case .unavailable: "This window is no longer available. Close this popover and hover again to refresh."
        case .ambiguous: "macOS did not expose a unique window match. Use Open Application instead."
        case .activation: "The application could not bring this window forward. It may be busy, minimized, or in another Space. Use Open Application instead."
        }
    }
}

/// No SCStream, file output, image persistence, or background refresh. One bounded snapshot batch at a time.
@MainActor
final class WindowPreviewService: WindowPreviewProviding {
    var screenAccess: Bool { CGPreflightScreenCaptureAccess() }
    var accessibilityAccess: Bool { AXIsProcessTrusted() }
    private var busy = false
    private let activation = WindowActivationWorker()
    func requestScreenAccess() { _ = CGRequestScreenCaptureAccess() }
    func requestAccessibilityAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private func shareableWindows(_ bundleIdentifier: String) async throws -> [SCWindow] {
        guard screenAccess else { throw WindowPreviewError.screenAccess }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        return content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.bundleIdentifier.lowercased() == bundleIdentifier.lowercased()
                && PreviewWindowDescriptor.valid($0.frame)
        }.sorted { $0.windowID < $1.windowID }
    }
    private func descriptor(_ window: SCWindow) -> PreviewWindowDescriptor {
        PreviewWindowDescriptor(id: window.windowID, pid: window.owningApplication?.processID ?? 0,
                                title: window.title ?? "", frame: window.frame, isOnScreen: window.isOnScreen)
    }
    func load(bundleIdentifier: String) async throws -> [WindowPreview] {
        guard !busy else { throw WindowPreviewError.busy }
        busy = true
        defer { busy = false }
        let windows = try await shareableWindows(bundleIdentifier)
        var result: [WindowPreview] = []
        var captures = 0
        // Bound memory and work even for applications with hundreds of windows.
        for window in windows.prefix(32) {
            try Task.checkCancellation()
            let item = descriptor(window)
            var row = WindowPreview(window: item, note: "Preview unavailable while this window is offscreen or minimized.")
            if item.canCapture && captures < 8 {
                captures += 1
                guard screenAccess else { throw WindowPreviewError.screenAccess }
                let configuration = SCStreamConfiguration()
                let scale = min(640 / item.frame.width, 400 / item.frame.height, 1)
                configuration.width = max(1, Int(item.frame.width * scale))
                configuration.height = max(1, Int(item.frame.height * scale))
                configuration.showsCursor = false
                configuration.scalesToFit = true
                configuration.preservesAspectRatio = true
                configuration.ignoreShadowsSingleWindow = true
                do {
                    row.image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                    row.note = nil
                } catch {
                    try Task.checkCancellation()
                    row.note = "macOS could not capture this window. Protected or closed windows may be unavailable."
                }
            } else if item.canCapture { row.note = "Thumbnail limit reached. Select this window or reopen previews to refresh." }
            try Task.checkCancellation()
            result.append(row)
        }
        return result
    }
    func activate(_ window: PreviewWindowDescriptor, bundleIdentifier: String) async throws {
        guard accessibilityAccess else { throw WindowPreviewError.accessibilityAccess }
        guard !busy else { throw WindowPreviewError.busy }
        busy = true
        defer { busy = false }
        let current = try await shareableWindows(bundleIdentifier).map { descriptor($0) }
        guard let fresh = current.first(where: { $0.id == window.id && $0.pid == window.pid }),
              fresh.title == window.title, fresh.frame == window.frame else { throw WindowPreviewError.unavailable }
        try await activation.raise(fresh, shared: current)
        try Task.checkCancellation()
        guard let app = NSRunningApplication(processIdentifier: fresh.pid), !app.isTerminated else { throw WindowPreviewError.unavailable }
        if app.isHidden { app.unhide() }
        guard app.activate(options: []) else { throw WindowPreviewError.activation }
    }
}

/// AX messaging may block a nonresponsive application; keep it off the UI thread and set a short timeout.
private actor WindowActivationWorker {
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    func raise(_ window: PreviewWindowDescriptor, shared: [PreviewWindowDescriptor]) throws {
        try Task.checkCancellation()
        let application = AXUIElementCreateApplication(window.pid)
        guard AXUIElementSetMessagingTimeout(application, 0.2) == .success,
              let windows = value(application, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32 else {
            throw WindowPreviewError.unavailable
        }
        func description(_ element: AXUIElement) throws -> AccessibleWindowDescriptor {
            try Task.checkCancellation()
            var point = CGPoint.zero
            var size = CGSize.zero
            guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let dimensions = value(element, kAXSizeAttribute), CFGetTypeID(dimensions) == AXValueGetTypeID(),
                  AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(dimensions as! AXValue, .cgSize, &size) else {
                return AccessibleWindowDescriptor(title: "", frame: .zero)
            }
            return AccessibleWindowDescriptor(title: value(element, kAXTitleAttribute) as? String ?? "", frame: CGRect(origin: point, size: size))
        }
        let descriptions = try windows.map { try description($0) }
        try Task.checkCancellation()
        guard let index = PreviewWindowMatching.uniqueIndex(for: window, shared: shared, accessible: descriptions) else {
            throw WindowPreviewError.ambiguous
        }
        let target = windows[index]
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(target, &actionNames) == .success,
              (actionNames as? [String])?.contains(kAXRaiseAction) == true else { throw WindowPreviewError.activation }
        if (value(target, kAXMinimizedAttribute) as? Bool) == true {
            guard AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                throw WindowPreviewError.activation
            }
        }
        try Task.checkCancellation()
        guard AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success else { throw WindowPreviewError.activation }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(application, kAXFocusedWindowAttribute as CFString, &settable) == .success,
           settable.boolValue {
            guard AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target) == .success else {
                throw WindowPreviewError.activation
            }
        }
    }
}
