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

    // Claude logo below it (monochrome — drawn black so the status bar can
    // tint it as a template image).
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    // Repo asset by default; override with CLAUDE_LOGO=/path/to/claude.svg.
    let logoPath = ProcessInfo.processInfo.environment["CLAUDE_LOGO"] ?? "assets/claude.svg"
    if let logo = NSImage(contentsOfFile: logoPath) {
        let s = px * 0.66
        let rect = CGRect(x: (px - s)/2, y: px*0.40 - s/2, width: s, height: s)
        logo.size = NSSize(width: s, height: s)
        logo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/menubar.png"
guard let data = render(36) else { FileHandle.standardError.write("render failed\n".data(using:.utf8)!); exit(1) }
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
