import AppKit

// Draw the app mark using native vector paths; no external assets required.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "macos/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    let background = NSBezierPath(
      roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 210, yRadius: 210)
    NSGradient(
      starting: NSColor(calibratedRed: 0.18, green: 0.23, blue: 0.23, alpha: 1),
      ending: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.10, alpha: 1))!.draw(
        in: background, angle: -90)
    NSColor(calibratedRed: 0.72, green: 0.83, blue: 0.49, alpha: 1).setFill()
    let frame = NSBezierPath(
      roundedRect: NSRect(x: 255, y: 258, width: 514, height: 448), xRadius: 55, yRadius: 55)
    frame.lineWidth = 30
    NSColor(calibratedRed: 0.72, green: 0.83, blue: 0.49, alpha: 1).setStroke()
    frame.stroke()
    let mountain = NSBezierPath()
    mountain.move(to: NSPoint(x: 280, y: 290))
    mountain.line(to: NSPoint(x: 448, y: 518))
    mountain.line(to: NSPoint(x: 567, y: 382))
    mountain.line(to: NSPoint(x: 651, y: 482))
    mountain.line(to: NSPoint(x: 744, y: 290))
    mountain.close()
    mountain.fill()
    NSBezierPath(ovalIn: NSRect(x: 588, y: 554, width: 80, height: 80)).fill()
    let star = NSBezierPath()
    star.move(to: NSPoint(x: 770, y: 850))
    star.line(to: NSPoint(x: 795, y: 780))
    star.line(to: NSPoint(x: 865, y: 755))
    star.line(to: NSPoint(x: 795, y: 730))
    star.line(to: NSPoint(x: 770, y: 660))
    star.line(to: NSPoint(x: 745, y: 730))
    star.line(to: NSPoint(x: 675, y: 755))
    star.line(to: NSPoint(x: 745, y: 780))
    star.close()
    star.fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)\(suffix).png"))
  }
}
