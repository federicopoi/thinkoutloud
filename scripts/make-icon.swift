// Concatenated with Brand.swift by build.sh to use the same vector artwork.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = destination.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = rect.insetBy(dx: CGFloat(pixels) * 0.08, dy: CGFloat(pixels) * 0.08)
        let shape = NSBezierPath(roundedRect: inset, xRadius: CGFloat(pixels) * 0.20, yRadius: CGFloat(pixels) * 0.20)
        NSColor.white.setFill()
        shape.fill()
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        let markRect = CGRect(x: CGFloat(pixels) * 0.23, y: CGFloat(pixels) * 0.23, width: CGFloat(pixels) * 0.54, height: CGFloat(pixels) * 0.54)
        context.addPath(ThinkOutLoudSymbol().path(in: markRect).cgPath)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", destination.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: iconset)
