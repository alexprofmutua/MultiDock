import AppKit
@preconcurrency import ApplicationServices

/// Supported window-state commands. macOS owns the minimize animation and its destination.
@MainActor
final class ApplicationWindowService {
    private let permissionCheck: () -> Bool
    private let worker = ApplicationWindowWorker()
    init(permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) { self.permissionCheck = permissionCheck }
    var hasAccess: Bool { permissionCheck() }
    func noteActivatedApplication(_ pid: Int32) {
        Task { await worker.resetIfDifferent(pid) }
    }
    func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    /// Advanced clicks never reopen an already running app or create new windows.
    /// Permission denial falls back to ordinary activation without prompting.
    func activate(bundleIdentifier: String, mode: DockClickMode, restoreMinimized: Bool) async throws {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }.sorted { $0.processIdentifier < $1.processIdentifier }
        guard let app = apps.first(where: \.isActive) ?? apps.first else { throw WindowCommandError.notRunning }
        if app.isHidden { app.unhide() }
        guard app.activate(options: []) else { throw WindowCommandError.activationFailed }
        guard hasAccess, mode != .standard else { return }
        try await worker.focus(pid: app.processIdentifier, cycling: mode == .cycleWindows, restoreMinimized: restoreMinimized)
    }

    func perform(bundleIdentifier: String, minimized: Bool) async throws {
        guard hasAccess else { throw WindowCommandError.permission }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased() && !$0.isTerminated
        }
        guard !apps.isEmpty else { throw WindowCommandError.notRunning }
        try await worker.perform(pids: apps.map(\.processIdentifier), minimized: minimized)
        try Task.checkCancellation()
        if !minimized, let app = apps.first(where: { !$0.isTerminated }) {
            if app.isHidden { app.unhide() }
            guard app.activate(options: []) else { throw WindowCommandError.unsupported }
        }
    }
}

enum WindowCommandError: LocalizedError {
    case permission, notRunning, unsupported, activationFailed, partial(Int)
    var errorDescription: String? {
        switch self {
        case .activationFailed: "macOS could not activate this application. Finish any open system dialogs and try again."
        case .permission: "Accessibility access is needed to minimize or restore another application's windows."
        case .notRunning: "This application is not running. Open it before using its window commands."
        case .unsupported: "This application did not expose eligible windows through macOS Accessibility. Full-screen and custom windows may not support this operation."
        case .partial(let count): "Changed \(count) windows, but some windows did not support this operation or stopped responding."
        }
    }
}

private actor ApplicationWindowWorker {
    private var currentPID: Int32?
    private var known: [(id: UUID, element: AXUIElement)] = []
    private var cursor = WindowCycleCursor()
    func resetIfDifferent(_ pid: Int32) {
        if currentPID != pid { currentPID = nil; known = []; cursor = WindowCycleCursor() }
    }
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success else { return nil }
        return raw
    }
    func focus(pid: Int32, cycling: Bool, restoreMinimized: Bool) throws {
        try Task.checkCancellation()
        if currentPID != pid { currentPID = pid; known = []; cursor = WindowCycleCursor() }
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.2) == .success,
              let windows = value(app, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32 else {
            known = []; throw WindowCommandError.unsupported
        }
        var eligible: [AXUIElement] = []
        for window in windows {
            try Task.checkCancellation()
            _ = AXUIElementSetMessagingTimeout(window, 0.2)
            guard value(window, kAXRoleAttribute) as? String == kAXWindowRole,
                  value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  let minimized = value(window, kAXMinimizedAttribute) as? Bool,
                  restoreMinimized || !minimized else { continue }
            eligible.append(window)
        }
        let retained = known.filter { old in eligible.contains { CFEqual($0, old.element) } }
        var added: [(element: AXUIElement, title: String, order: Int)] = []
        for (index, candidate) in eligible.enumerated() where !retained.contains(where: { CFEqual($0.element, candidate) }) {
            try Task.checkCancellation()
            // One IPC read per new window. Never call AX from the sort comparator:
            // titles may change while sorting and slow apps must remain cancellable.
            added.append((candidate, value(candidate, kAXTitleAttribute) as? String ?? "", index))
        }
        added.sort { $0.title == $1.title ? $0.order < $1.order : $0.title < $1.title }
        known = retained + added.map { (UUID(), $0.element) }
        guard !known.isEmpty else { return }
        let target: AXUIElement
        if cycling {
            let id = cursor.select(application: String(pid), windows: known.map(\.id), cycling: true)!
            target = known.first { $0.id == id }!.element
        } else {
            let focused = value(app, kAXFocusedWindowAttribute)
            target = known.first { entry in focused.map { CFEqual($0, entry.element) } ?? false }?.element
                ?? known.first { (value($0.element, kAXMinimizedAttribute) as? Bool) == false }?.element
                ?? known[0].element
        }
        try Task.checkCancellation()
        if (value(target, kAXMinimizedAttribute) as? Bool) == true {
            guard restoreMinimized,
                  AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                throw WindowCommandError.unsupported
            }
        }
        guard AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success else { throw WindowCommandError.unsupported }
        var writable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(app, kAXFocusedWindowAttribute as CFString, &writable) == .success, writable.boolValue {
            guard AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, target) == .success else { throw WindowCommandError.unsupported }
        }
    }

    func perform(pids: [Int32], minimized: Bool) throws {
        guard pids.count <= 8 else { throw WindowCommandError.unsupported }
        var eligible = 0
        var changed = 0
        var failed = 0
        for pid in pids {
            try Task.checkCancellation()
            let app = AXUIElementCreateApplication(pid)
            guard AXUIElementSetMessagingTimeout(app, 0.2) == .success else { failed += 1; continue }
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement], windows.count <= 32 else { failed += 1; continue }
            for window in windows {
                try Task.checkCancellation()
                var writable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &writable) == .success,
                      writable.boolValue else { continue }
                eligible += 1
                var state: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &state) == .success,
                      let current = state as? Bool else { failed += 1; continue }
                if current == minimized { continue }
                if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success { changed += 1 }
                else { failed += 1 }
            }
        }
        if failed > 0 && changed > 0 { throw WindowCommandError.partial(changed) }
        if eligible == 0 || (changed == 0 && failed > 0) { throw WindowCommandError.unsupported }
    }
}
