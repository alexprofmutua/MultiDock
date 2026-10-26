import AppKit
import CoreImage

/// Transform only in-memory icon pixels. No installed bundle or system appearance preference changes.
@MainActor
enum IconThemeRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func render(_ image: CGImage, theme: DockIconTheme, tint: DockIconTint) -> CGImage {
        guard theme != .original else { return image }
        let source = CIImage(cgImage: image)
        let filtered: CIImage
        if theme == .monochrome {
            filtered = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        } else {
            let color: NSColor = switch tint {
            case .accent: .controlAccentColor
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .green: .systemGreen
            case .orange: .systemOrange
            case .graphite: .gray
            }
            let rgb = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)
            let tintColor = CIColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            filtered = source.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: tintColor, kCIInputIntensityKey: 1])
        }
        return context.createCGImage(filtered, from: source.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) ?? image
    }
}
