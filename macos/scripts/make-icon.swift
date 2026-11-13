import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: make-icon.swift iconset-directory") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rect = NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
        // Explicit pixel backing avoids Retina-dependent icon dimensions.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let inset = CGFloat(pixels) * 0.06
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.14, green: 0.28, blue: 0.29, alpha: 1),
                                  ending: NSColor(srgbRed: 0.04, green: 0.07, blue: 0.12, alpha: 1))!
        gradient.draw(in: shape, angle: -65)
        NSColor.white.withAlphaComponent(0.2).setStroke()
        shape.lineWidth = max(1, CGFloat(pixels) * 0.003); shape.stroke()
        if let symbol = NSImage(systemSymbolName: "rotate.3d", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.48, weight: .light))?
            .withSymbolConfiguration(.init(paletteColors: [NSColor(srgbRed: 0.52, green: 0.97, blue: 0.83, alpha: 1)])) {
            let side = CGFloat(pixels) * 0.62
            symbol.draw(in: NSRect(x: (CGFloat(pixels) - side) / 2, y: (CGFloat(pixels) - side) / 2, width: side, height: side))
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
