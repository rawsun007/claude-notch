import AppKit

// Renders a monochrome menu-bar template glyph: a small notch pill with a
// spark beneath it. Pure black + alpha so macOS tints it for light/dark.
// Output: a PNG at 2x (36×36) — the status bar downsamples as needed.
// Usage: swift tools/make-menubar.swift assets/menubar.png

func render(_ px: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    // Notch pill across the top (flat top, rounded bottom).
    let pillW = px * 0.62, pillH = px * 0.20
    let pill = CGRect(x: (px - pillW)/2, y: px - pillH, width: pillW, height: pillH * 2)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pillH*0.8, cornerHeight: pillH*0.8, transform: nil))
    ctx.setFillColor(black)
    ctx.fillPath()

    // Spark below it.
    let c = CGPoint(x: px/2, y: px*0.40)
    let r = px*0.34, waist = r*0.30
    let tips = [CGPoint(x: c.x, y: c.y+r), CGPoint(x: c.x+r, y: c.y),
                CGPoint(x: c.x, y: c.y-r), CGPoint(x: c.x-r, y: c.y)]
    let inner = [CGPoint(x: c.x+waist, y: c.y+waist), CGPoint(x: c.x+waist, y: c.y-waist),
                 CGPoint(x: c.x-waist, y: c.y-waist), CGPoint(x: c.x-waist, y: c.y+waist)]
    let p = CGMutablePath()
    p.move(to: tips[0])
    for i in 0..<4 {
        p.addQuadCurve(to: inner[i], control: tips[i])
        p.addQuadCurve(to: tips[(i+1)%4], control: inner[i])
    }
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(black)
    ctx.fillPath()

    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/menubar.png"
guard let data = render(36) else { FileHandle.standardError.write("render failed\n".data(using:.utf8)!); exit(1) }
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
