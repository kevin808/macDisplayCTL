import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                       ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(red: 0.22, green: 0.48, blue: 0.53, alpha: 1),
               ending: NSColor(red: 0.10, green: 0.25, blue: 0.32, alpha: 1))!.draw(in: background, angle: -60)
    func screen(_ rect: NSRect, fill: NSColor, stroke: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)
        fill.setFill(); path.fill()
        stroke.setStroke(); path.lineWidth = 19; path.stroke()
    }
    screen(NSRect(x: 375, y: 412, width: 405, height: 279),
           fill: NSColor(red: 0.67, green: 0.87, blue: 0.85, alpha: 1), stroke: .white)
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 578, y: 412)); stand.line(to: NSPoint(x: 578, y: 356))
    stand.move(to: NSPoint(x: 510, y: 356)); stand.line(to: NSPoint(x: 646, y: 356))
    NSColor.white.setStroke(); stand.lineWidth = 20; stand.lineCapStyle = .round; stand.stroke()
    screen(NSRect(x: 215, y: 317, width: 346, height: 235),
           fill: NSColor(red: 0.25, green: 0.53, blue: 0.59, alpha: 1), stroke: .white)
    let base = NSBezierPath()
    base.move(to: NSPoint(x: 189, y: 278)); base.line(to: NSPoint(x: 586, y: 278))
    base.lineWidth = 24; base.lineCapStyle = .round; base.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
