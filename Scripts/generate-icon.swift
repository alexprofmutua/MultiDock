import AppKit

// Original geometric artwork, generated locally. No system or third-party icon assets.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: CGRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196)
        NSColor(srgbRed: 0.12, green: 0.27, blue: 0.46, alpha: 1).setFill()
        background.fill()
        func dock(_ rect: CGRect, alpha: CGFloat, icons: Int) {
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 46, yRadius: 46).fill()
            for index in 0..<icons {
                let colors: [NSColor] = [NSColor(srgbRed: 0.17, green: 0.48, blue: 0.85, alpha: 1),
                                         NSColor(srgbRed: 0.15, green: 0.63, blue: 0.58, alpha: 1),
                                         NSColor(srgbRed: 0.91, green: 0.54, blue: 0.23, alpha: 1)]
                colors[index].setFill()
                let icon = CGRect(x: rect.minX + 42 + CGFloat(index) * 130, y: rect.midY - 42, width: 84, height: 84)
                NSBezierPath(roundedRect: icon, xRadius: 19, yRadius: 19).fill()
            }
        }
        dock(CGRect(x: 300, y: 575, width: 420, height: 160), alpha: 0.78, icons: 2)
        dock(CGRect(x: 220, y: 320, width: 550, height: 180), alpha: 0.96, icons: 3)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
