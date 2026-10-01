import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for name in ["AppIcon", "AppIconDev"] {
    let directory = root.appendingPathComponent("SunMouse/Assets.xcassets/\(name).appiconset")
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "png" {
        let existing = NSImage(contentsOf: url)!
        let n = (existing.representations.first as? NSBitmapImageRep)?.pixelsWide ?? 512
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(n) / 1024); transform.concat()
        NSColor(calibratedRed: 0.98, green: 0.54, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200).fill()
        NSColor.white.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: NSRect(x: 175, y: 175, width: 674, height: 674)).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 335, y: 220, width: 354, height: 584), xRadius: 177, yRadius: 177).fill()
        NSColor(calibratedRed: 0.97, green: 0.49, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 491, y: 574, width: 42, height: 120), xRadius: 21, yRadius: 21).fill()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
