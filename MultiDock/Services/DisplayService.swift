import AppKit
import CoreGraphics

@MainActor
enum DisplayService {
    static var current: [DockDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = number.uint32Value
            let id: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                id = "uuid:\(CFUUIDCreateString(nil, uuid) as String)"
            } else {
                // Runtime ID is the final fallback for hardware that cannot supply a stable UUID.
                id = "fallback:\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))-\(displayID)"
            }
            return DockDisplay(id: id, name: screen.localizedName, frame: screen.frame,
                               visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor,
                               isPrimary: displayID == CGMainDisplayID())
        }.filter(\.isUsable)
    }
}
