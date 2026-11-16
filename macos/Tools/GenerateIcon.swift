import AppKit

// Draws Curio's icon with native vector paths; no external assets required.
//   swift macos/Tools/GenerateIcon.swift && iconutil -c icns macos/AppIcon.iconset -o macos/AppIcon.icns
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "macos/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

// NSShadow is measured in device pixels, so it does not follow the scale transform.
var shadowScale: CGFloat = 1

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(blur: CGFloat, y: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowBlurRadius = blur * shadowScale
  shadow.shadowOffset = NSSize(width: 0, height: y * shadowScale)
  shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
  shadow.set()
  draw()
  NSGraphicsContext.restoreGraphicsState()
}

/// A four-pointed sparkle centred on `c`.
func sparkle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
  let path = NSBezierPath()
  let w = r * 0.22
  path.move(to: NSPoint(x: c.x, y: c.y + r))
  path.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
  path.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
  path.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
  path.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
  path.close()
  return path
}

/// A photo card rotated by `degrees` about the icon's centre line.
func card(rotation degrees: CGFloat, offset: NSPoint, _ draw: (NSRect) -> Void) {
  NSGraphicsContext.saveGraphicsState()
  let t = NSAffineTransform()
  t.translateX(by: 512 + offset.x, yBy: 470 + offset.y)
  t.rotate(byDegrees: degrees)
  t.concat()
  draw(NSRect(x: -170, y: -205, width: 340, height: 410))
  NSGraphicsContext.restoreGraphicsState()
}

func drawIcon() {
  // Tile: deep violet with a warm glow from the top.
  let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
  withShadow(blur: 28, y: -12, alpha: 0.35) { rgb(0x140F2E).setFill(); tile.fill() }
  NSGradient(colors: [rgb(0x3A2477), rgb(0x1B1440), rgb(0x0C0A1F)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -90)
  NSGraphicsContext.saveGraphicsState()
  tile.addClip()
  NSGradient(starting: rgb(0xFF8A65, 0.38), ending: rgb(0xFF8A65, 0))!
    .draw(fromCenter: NSPoint(x: 330, y: 900), radius: 0, toCenter: NSPoint(x: 330, y: 900), radius: 560, options: [])
  NSGradient(starting: rgb(0x7C5CFF, 0.30), ending: rgb(0x7C5CFF, 0))!
    .draw(fromCenter: NSPoint(x: 820, y: 180), radius: 0, toCenter: NSPoint(x: 820, y: 180), radius: 480, options: [])
  NSGraphicsContext.restoreGraphicsState()
  rgb(0xFFFFFF, 0.14).setStroke()
  let rim = NSBezierPath(roundedRect: NSRect(x: 104, y: 104, width: 816, height: 816), xRadius: 181, yRadius: 181)
  rim.lineWidth = 6
  rim.stroke()

  // Two cards fanned behind: the rest of the collection.
  for (angle, dx, colors) in [
    (CGFloat(-16), CGFloat(-70), [rgb(0x5EC8F2), rgb(0x3B6FD8)]),
    (CGFloat(11), CGFloat(62), [rgb(0x8BE3B0), rgb(0x2E9C8A)]),
  ] {
    card(rotation: angle, offset: NSPoint(x: dx, y: 10)) { r in
      let frame = NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34)
      withShadow(blur: 30, y: -14, alpha: 0.45) { rgb(0xF4F1FF).setFill(); frame.fill() }
      let photo = NSBezierPath(roundedRect: r.insetBy(dx: 22, dy: 22), xRadius: 16, yRadius: 16)
      NSGradient(colors: colors)!.draw(in: photo, angle: -90)
    }
  }

  // The chosen card in front: a sunset over hills.
  card(rotation: -2, offset: NSPoint(x: 0, y: -18)) { r in
    let frame = NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34)
    withShadow(blur: 40, y: -20, alpha: 0.55) { rgb(0xFFFFFF).setFill(); frame.fill() }
    let inner = r.insetBy(dx: 22, dy: 22)
    let photo = NSBezierPath(roundedRect: inner, xRadius: 16, yRadius: 16)
    NSGraphicsContext.saveGraphicsState()
    photo.addClip()
    NSGradient(colors: [rgb(0xFFD36E), rgb(0xFF7A59), rgb(0xD63A8C), rgb(0x5B2A9E)], atLocations: [0, 0.35, 0.7, 1], colorSpace: .sRGB)!
      .draw(in: inner, angle: -90)
    let sun = NSRect(x: -62, y: -10, width: 124, height: 124)
    NSGradient(starting: rgb(0xFFF6D8), ending: rgb(0xFFC56B))!.draw(in: NSBezierPath(ovalIn: sun), angle: -90)
    let far = NSBezierPath()
    far.move(to: NSPoint(x: inner.minX, y: -40))
    far.curve(to: NSPoint(x: inner.maxX, y: -30), controlPoint1: NSPoint(x: -60, y: 40), controlPoint2: NSPoint(x: 60, y: -110))
    far.line(to: NSPoint(x: inner.maxX, y: inner.minY))
    far.line(to: NSPoint(x: inner.minX, y: inner.minY))
    far.close()
    rgb(0x4A1F7A).setFill()
    far.fill()
    let near = NSBezierPath()
    near.move(to: NSPoint(x: inner.minX, y: -110))
    near.curve(to: NSPoint(x: inner.maxX, y: -70), controlPoint1: NSPoint(x: 0, y: -170), controlPoint2: NSPoint(x: 40, y: -20))
    near.line(to: NSPoint(x: inner.maxX, y: inner.minY))
    near.line(to: NSPoint(x: inner.minX, y: inner.minY))
    near.close()
    rgb(0x24114A).setFill()
    near.fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  // Gold sparkles: the pick of the collection.
  let gold = NSGradient(starting: rgb(0xFFF3C4), ending: rgb(0xFFB938))!
  for (center, radius) in [(NSPoint(x: 760, y: 770), CGFloat(92)), (NSPoint(x: 660, y: 840), CGFloat(38))] {
    let star = sparkle(center, radius)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowBlurRadius = radius * 0.6 * shadowScale
    glow.shadowColor = rgb(0xFFC94D, 0.9)
    glow.set()
    rgb(0xFFD46A).setFill()
    star.fill()
    NSGraphicsContext.restoreGraphicsState()
    gold.draw(in: star, angle: -90)
  }
}

for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    shadowScale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)\(suffix).png"))
  }
}
