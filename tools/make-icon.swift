import AppKit

// Renders the ClaudeNotch app icon (1024×1024) to a PNG.
// Theme: a dark "Dynamic Island" rounded square with a hanging notch pill
// and Claude's coral spark below it.
// Usage:  swift tools/make-icon.swift assets/icon-1024.png

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.clear(canvas)

    // --- Rounded-square background (Big Sur icon grid: ~824/1024 content) ---
    let inset = size * 0.085
    let bgRect = canvas.insetBy(dx: inset, dy: inset)
    let bgRadius = bgRect.width * 0.225
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    // Vertical gradient: slate → near-black.
    let colors = [
        CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: bgRect.midX, y: bgRect.maxY),
                               end: CGPoint(x: bgRect.midX, y: bgRect.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Subtle top highlight rim.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setLineWidth(size * 0.004)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.strokePath()
    ctx.restoreGState()

    // --- The notch: a black pill hanging from the top of the square ---
    let notchW = bgRect.width * 0.46
    let notchH = size * 0.085
    let notchRect = CGRect(
        x: bgRect.midX - notchW / 2,
        y: bgRect.maxY - notchH,            // flush to top edge
        width: notchW,
        height: notchH * 2                  // half clipped above → flat top look
    )
    ctx.saveGState()
    ctx.addPath(bgPath)              // clip to the square so the notch top is flat
    ctx.clip()
    let notchPath = CGPath(roundedRect: notchRect, cornerWidth: notchH * 0.9, cornerHeight: notchH * 0.9, transform: nil)
    ctx.addPath(notchPath)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // --- Claude logo (coral), centred a little below middle ---
    // Repo asset by default; override with CLAUDE_LOGO=/path/to/claude-color.svg.
    let logoPath = ProcessInfo.processInfo.environment["CLAUDE_LOGO"] ?? "assets/claude-color.svg"
    if let logo = NSImage(contentsOfFile: logoPath) {
        let logoSize = bgRect.width * 0.50
        let logoRect = CGRect(
            x: bgRect.midX - logoSize / 2,
            y: bgRect.midY - logoSize / 2 - size * 0.02,
            width: logoSize,
            height: logoSize
        )
        logo.size = NSSize(width: logoSize, height: logoSize)
        logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()
    return image
}

// A four-point "sparkle" (concave-diamond star) — evokes Claude's mark.
func drawSpark(_ ctx: CGContext, center: CGPoint, radius r: CGFloat, color: CGColor) {
    let waist = r * 0.30           // how pinched the waist is
    let path = CGMutablePath()
    // Build with 4 tips (up, right, down, left) and concave control points.
    let tips: [CGPoint] = [
        CGPoint(x: center.x, y: center.y + r),   // up
        CGPoint(x: center.x + r, y: center.y),   // right
        CGPoint(x: center.x, y: center.y - r),   // down
        CGPoint(x: center.x - r, y: center.y)    // left
    ]
    let inner: [CGPoint] = [
        CGPoint(x: center.x + waist, y: center.y + waist),
        CGPoint(x: center.x + waist, y: center.y - waist),
        CGPoint(x: center.x - waist, y: center.y - waist),
        CGPoint(x: center.x - waist, y: center.y + waist)
    ]
    path.move(to: tips[0])
    for i in 0..<4 {
        let tip = tips[i]
        let nextTip = tips[(i + 1) % 4]
        let mid = inner[i]
        path.addQuadCurve(to: mid, control: tip)
        path.addQuadCurve(to: nextTip, control: mid)
    }
    path.closeSubpath()

    ctx.saveGState()
    // Soft glow.
    ctx.setShadow(offset: .zero, blur: r * 0.18, color: color.copy(alpha: 0.55))
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

// --- main ---
let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "assets/icon-1024.png"
let img = render(size: 1024)
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
