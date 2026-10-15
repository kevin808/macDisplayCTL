import AppKit

// Original vector artwork; render every resolution directly instead of scaling a bitmap.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func fill(_ path: NSBezierPath, _ color: NSColor) { color.setFill(); path.fill() }
func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
    color.setStroke(); path.lineWidth = width; path.lineJoinStyle = .round; path.lineCapStyle = .round; path.stroke()
}
func drawIcon() {
    let tile = rounded(NSRect(x: 80, y: 80, width: 864, height: 864), 198)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow(); tileShadow.shadowColor = color(0.02, 0.15, 0.20, 0.24)
    tileShadow.shadowBlurRadius = 23; tileShadow.shadowOffset = NSSize(width: 0, height: -12); tileShadow.set()
    fill(tile, color(0.08, 0.37, 0.42))
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0.28, 0.70, 0.70), color(0.10, 0.43, 0.49), color(0.04, 0.23, 0.32)])!
        .draw(in: tile, angle: -62)
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let glow = NSBezierPath(ovalIn: NSRect(x: -140, y: 490, width: 1000, height: 760))
    NSGradient(starting: color(0.81, 1, 0.91, 0.20), ending: color(0.81, 1, 0.91, 0))!
        .draw(in: glow, relativeCenterPosition: NSPoint(x: 0, y: 0))
    NSGraphicsContext.restoreGraphicsState()
    stroke(rounded(NSRect(x: 82, y: 82, width: 860, height: 860), 196), color(1, 1, 1, 0.18), 2)

    // The external display and its stand sit behind a distinct MacBook silhouette.
    let monitor = rounded(NSRect(x: 356, y: 414, width: 438, height: 306), 32)
    NSGraphicsContext.saveGraphicsState()
    let deviceShadow = NSShadow(); deviceShadow.shadowColor = color(0.01, 0.09, 0.14, 0.4)
    deviceShadow.shadowBlurRadius = 28; deviceShadow.shadowOffset = NSSize(width: 0, height: -15); deviceShadow.set()
    fill(monitor, color(0.93, 0.98, 0.98)); NSGraphicsContext.restoreGraphicsState()
    fill(rounded(NSRect(x: 552, y: 352, width: 48, height: 71), 9), color(0.72, 0.84, 0.86))
    fill(rounded(NSRect(x: 512, y: 341, width: 128, height: 15), 7), color(0.88, 0.95, 0.95))
    let rearScreen = rounded(NSRect(x: 376, y: 446, width: 398, height: 254), 16)
    NSGradient(starting: color(0.09, 0.28, 0.38), ending: color(0.11, 0.53, 0.60))!.draw(in: rearScreen, angle: 30)
    NSGraphicsContext.saveGraphicsState(); rearScreen.addClip()
    let rearWave = NSBezierPath()
    rearWave.move(to: NSPoint(x: 355, y: 448)); rearWave.line(to: NSPoint(x: 800, y: 448))
    rearWave.line(to: NSPoint(x: 800, y: 648))
    rearWave.curve(to: NSPoint(x: 355, y: 466), controlPoint1: NSPoint(x: 607, y: 674), controlPoint2: NSPoint(x: 664, y: 461))
    rearWave.close(); fill(rearWave, color(0.49, 0.86, 0.81))
    let rearWaveLight = NSBezierPath()
    rearWaveLight.move(to: NSPoint(x: 374, y: 446)); rearWaveLight.line(to: NSPoint(x: 800, y: 446))
    rearWaveLight.line(to: NSPoint(x: 800, y: 568))
    rearWaveLight.curve(to: NSPoint(x: 374, y: 449), controlPoint1: NSPoint(x: 655, y: 622), controlPoint2: NSPoint(x: 641, y: 449))
    rearWaveLight.close(); fill(rearWaveLight, color(0.80, 0.96, 0.85))
    NSGraphicsContext.restoreGraphicsState()
    fill(NSBezierPath(ovalIn: NSRect(x: 572, y: 427, width: 7, height: 7)), color(0.41, 0.61, 0.64))

    let laptop = rounded(NSRect(x: 215, y: 302, width: 385, height: 262), 26)
    NSGraphicsContext.saveGraphicsState(); deviceShadow.set()
    fill(laptop, color(0.94, 0.98, 0.98)); NSGraphicsContext.restoreGraphicsState()
    let frontScreen = rounded(NSRect(x: 234, y: 324, width: 347, height: 222), 11)
    NSGradient(starting: color(0.04, 0.21, 0.31), ending: color(0.08, 0.44, 0.50))!.draw(in: frontScreen, angle: 40)
    NSGraphicsContext.saveGraphicsState(); frontScreen.addClip()
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: 232, y: 323)); wave.line(to: NSPoint(x: 586, y: 323)); wave.line(to: NSPoint(x: 586, y: 474))
    wave.curve(to: NSPoint(x: 232, y: 339), controlPoint1: NSPoint(x: 424, y: 528), controlPoint2: NSPoint(x: 442, y: 339))
    wave.close(); fill(wave, color(0.32, 0.74, 0.76))
    let highlight = NSBezierPath()
    highlight.move(to: NSPoint(x: 232, y: 323)); highlight.line(to: NSPoint(x: 586, y: 323)); highlight.line(to: NSPoint(x: 586, y: 391))
    highlight.curve(to: NSPoint(x: 232, y: 324), controlPoint1: NSPoint(x: 470, y: 451), controlPoint2: NSPoint(x: 440, y: 324))
    highlight.close(); fill(highlight, color(0.62, 0.88, 0.85))
    NSGraphicsContext.restoreGraphicsState()
    // A shallow silver keyboard base makes the foreground device legible at 32 px.
    let base = NSBezierPath()
    base.move(to: NSPoint(x: 185, y: 299)); base.line(to: NSPoint(x: 630, y: 299))
    base.line(to: NSPoint(x: 606, y: 276)); base.curve(to: NSPoint(x: 584, y: 267), controlPoint1: NSPoint(x: 600, y: 270), controlPoint2: NSPoint(x: 592, y: 267))
    base.line(to: NSPoint(x: 229, y: 267)); base.curve(to: NSPoint(x: 207, y: 276), controlPoint1: NSPoint(x: 220, y: 267), controlPoint2: NSPoint(x: 213, y: 270)); base.close()
    NSGradient(starting: color(0.99, 1, 1), ending: color(0.65, 0.79, 0.81))!.draw(in: base, angle: -90)
    fill(rounded(NSRect(x: 365, y: 287, width: 85, height: 12), 5), color(0.50, 0.66, 0.69))
}

var pngs: [Int: Data] = [:]
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    pngs[pixels] = bitmap.representation(using: .png, properties: [:])!
}
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                       ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try pngs[pixels]!.write(to: directory.appendingPathComponent(name + ".png"))
}
// ICNS permits PNG payloads in these standard slots. Writing the small container
// directly avoids iconutil depending on a GUI/ImageIO service during sandboxed builds.
func lengthBytes(_ count: Int) -> Data {
    var length = UInt32(count).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) }
}
var chunks = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                       ("ic08", 256), ("ic09", 512), ("ic10", 1024),
                       ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let payload = pngs[pixels]!
    chunks.append(Data(type.utf8)); chunks.append(lengthBytes(payload.count + 8)); chunks.append(payload)
}
var icon = Data("icns".utf8); icon.append(lengthBytes(chunks.count + 8)); icon.append(chunks)
let output = directory.deletingLastPathComponent().appendingPathComponent("macDisplayCtl.icns")
try icon.write(to: output)
try pngs[1024]!.write(to: directory.deletingLastPathComponent().appendingPathComponent("macDisplayCtl-icon.png"))
print("Rendered icon: \(output.path)")
