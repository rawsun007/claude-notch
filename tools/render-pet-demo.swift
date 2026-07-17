// Renders a contact sheet of every Pet Mode activity, sampled across its
// timeline, to a PNG — offscreen, so the pet's motion can be reviewed without
// a screen recording (and diffed when the pose math is retuned).
//
//   swiftc -O tools/render-pet-demo.swift Sources/ClaudeNotch/PetEngine.swift Sources/ClaudeNotch/PetRig.swift -o /tmp/petdemo && /tmp/petdemo [out.png]
//
// Each row is one activity; each column is a moment in it. The black plate is
// the notch card at exactly the size that activity asks for, so a sprite that
// pokes outside its plate here is a sprite that gets clipped in the app.
import AppKit

@main
enum PetDemo {
    static let inset: Double = 32          // physical notch height
    static let baseWidth: Double = 180     // notch cutout width
    /// Override with PET_SAMPLES=0,0.02,0.05,... to zoom in on one phase of an
    /// act (the rope's fall, say, which is all over inside the first tenth).
    static let samples: [Double] = ProcessInfo.processInfo.environment["PET_SAMPLES"]
        .map { $0.split(separator: ",").compactMap { Double($0) } }
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? [0.0, 0.08, 0.2, 0.35, 0.5, 0.65, 0.8, 0.94]
    static let cellPad: Double = 14
    static let labelWidth: Double = 96

    static let activities: [PetActivity] = PetActivity.allCases.filter { $0 != .tucked }

    static func main() {
        let out = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : URL(fileURLWithPath: "pet-demo.png")

        let cellW = baseWidth + 100 + cellPad * 2      // widest stage + padding
        let cellH = inset + 80 + cellPad * 2
        let width = labelWidth + cellW * Double(samples.count)
        let height = cellH * Double(activities.count)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for (row, activity) in activities.enumerated() {
            let rowY = Double(row) * cellH
            draw(label: activity.rawValue, at: NSPoint(x: 8, y: rowY + cellH / 2 - 7))

            for (col, t) in samples.enumerated() {
                let cellX = labelWidth + Double(col) * cellW
                let stageWidth = baseWidth + activity.stageWidthPad
                let stageHeight = inset + activity.stageDrop
                let plateX = cellX + (cellW - stageWidth) / 2
                let plateY = rowY + cellPad

                // The card: black, and clipped at its bottom edge exactly like
                // the real notch shape clips.
                let plate = NSRect(x: plateX, y: plateY, width: stageWidth, height: stageHeight)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: plate, xRadius: 12, yRadius: 12).fill()
                // The notch line: everything above it is hidden by hardware.
                NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: plateX, y: plateY + inset))
                line.line(to: NSPoint(x: plateX + stageWidth, y: plateY + inset))
                line.lineWidth = 0.5
                line.stroke()

                let stage = PetEngine.Stage(notchInset: inset, halfWidth: stageWidth / 2)
                let pose = PetEngine.pose(for: activity, progress: t, stage: stage)
                guard pose.opacity > 0.01 else { continue }

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: plate, xRadius: 12, yRadius: 12).addClip()
                // The rope strand, drawn the same way the app draws it: sagging
                // while there is slack, straight once it is taut.
                if PetEngine.isHanging(activity) {
                    let sprite = activity.spriteSize
                    let bodyTheta = pose.rotation * .pi / 180
                    let theta = activity == .spiderHang ? bodyTheta - .pi : bodyTheta
                    let grip = (-PetBody.headTopFraction + 0.04) * sprite
                    let topX = pose.x - sin(theta) * grip
                    let topY = pose.y - cos(theta) * grip
                    let restLen = PetEngine.ropeRestRadius(activity) - grip
                    let span = (topX * topX + (topY - inset) * (topY - inset)).squareRoot()
                    let slack = max(0, restLen - span)
                    let anchor = NSPoint(x: plateX + stageWidth / 2, y: plateY + inset)
                    let end = NSPoint(x: anchor.x + topX, y: plateY + topY)
                    let strand = NSBezierPath()
                    strand.move(to: anchor)
                    if slack > 0.5 {
                        let mid = NSPoint(x: (anchor.x + end.x) / 2,
                                          y: (anchor.y + end.y) / 2 + slack * 1.1)
                        strand.curve(to: end, controlPoint1: mid, controlPoint2: mid)
                    } else {
                        strand.line(to: end)
                    }
                    let web = activity == .spiderHang
                    strand.lineWidth = web ? 1.5 : 2
                    NSColor(calibratedWhite: web ? 0.92 : 0.55, alpha: pose.opacity).setStroke()
                    strand.stroke()
                }
                // Sample the gait clock at the same instant the app would.
                let rig = PetRigging.rig(for: activity, progress: t, time: t * 2.4)
                draw(size: activity.spriteSize, pose: pose, rig: rig,
                     pivot: activity.pivot, spider: activity == .spiderHang,
                     centre: NSPoint(x: plateX + stageWidth / 2, y: plateY))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("encode failed\n".utf8))
            exit(1)
        }
        try? png.write(to: out)
        print("wrote \(out.path)")
    }

    /// Applies a pose the same way NotchView does: scale and rotate about the
    /// feet (or the paws, when hanging), then place the sprite's centre at
    /// (pose.x, pose.y) measured from the card's top-centre.
    /// Draws the pet's parts from the rig, mirroring PetSprite's Canvas.
    private static func drawBody(size: Double, rig: PetRig, spider: Bool = false) {
        let cell = size / PetBody.grid
        let coral = NSColor(calibratedRed: 217/255, green: 119/255, blue: 87/255, alpha: 1)
        let red = NSColor(calibratedRed: 0.80, green: 0.11, blue: 0.13, alpha: 1)
        let blue = NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.55, alpha: 1)
        let torsoColour: NSColor = spider ? red : coral
        let limbColour: NSColor = spider ? blue : coral
        torsoColour.setFill()
        func rect(_ p: PetPart, dx: Double = 0, dy: Double = 0) -> NSRect {
            NSRect(x: -size/2 + (p.x + dx) * cell, y: -size/2 + (p.y + dy) * cell,
                   width: p.width * cell, height: p.height * cell)
        }
        for (i, leg) in PetBody.legs.enumerated() {
            var part = leg
            part.height = max(0, leg.height - rig.legTuck[i])
            guard part.height > 0.01 else { continue }
            let lift = rig.legLift[i] + rig.legTuck[i]
            limbColour.setFill()
            NSBezierPath(rect: rect(part, dx: rig.legSwing[i], dy: -lift + rig.legTuck[i])).fill()
        }

        func arm(_ p: PetPart, pivotCell: PetPart, angle: Double) {
            let r = rect(p)
            let pivot = NSPoint(x: -size/2 + pivotCell.x * cell,
                                y: -size/2 + (pivotCell.y + pivotCell.height / 2) * cell)
            NSGraphicsContext.saveGraphicsState()
            let tf = NSAffineTransform()
            tf.translateX(by: pivot.x, yBy: pivot.y)
            tf.rotate(byDegrees: CGFloat(angle))
            tf.translateX(by: -pivot.x, yBy: -pivot.y)
            tf.concat()
            limbColour.setFill()
            NSBezierPath(rect: r).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        // Mirrored: a positive rig angle raises either arm.
        arm(PetBody.armLeft, pivotCell: PetBody.shoulderLeft, angle: rig.armLeftAngle)
        arm(PetBody.armRight, pivotCell: PetBody.shoulderRight, angle: -rig.armRightAngle)

        // Torso last: it covers every shoulder and hip joint.
        for slab in PetBody.torso {
            torsoColour.setFill()
            NSBezierPath(rect: rect(slab)).fill()
        }

        for (i, eye) in [PetBody.eyeLeft, PetBody.eyeRight].enumerated() {
            let open = max(0, rig.eyeOpen)
            guard open > 0.02 else { continue }
            var lens = eye
            if spider {
                lens.width = 2.2; lens.height = 2.6
                lens.x = (i == 0 ? eye.x - 1.0 : eye.x - 0.2); lens.y = eye.y - 0.3
            }
            var lid = lens
            lid.height = lens.height * open
            let dy = lens.height - lid.height
            if spider {
                var b = lid; b.x -= 0.35; b.y -= 0.35; b.width += 0.7; b.height += 0.7
                NSColor(calibratedRed: 0.16, green: 0.09, blue: 0.06, alpha: 1).setFill()
                NSBezierPath(rect: rect(b, dx: rig.eyeShift, dy: dy)).fill()
            }
            (spider ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor.black).setFill()
            NSBezierPath(rect: rect(lid, dx: rig.eyeShift, dy: dy)).fill()
        }
    }

    private static func draw(size: Double, pose: PetPose, rig: PetRig, pivot: PetPivot, spider: Bool = false, centre: NSPoint) {
        let transform = NSAffineTransform()
        transform.translateX(by: CGFloat(centre.x + pose.x), yBy: CGFloat(centre.y + pose.y))
        let anchorOffset: CGFloat = {
            switch pivot {
            case .feet:   return CGFloat(size / 2)
            case .paws:   return CGFloat(-size / 2)
            case .centre: return 0
            }
        }()
        transform.translateX(by: 0, yBy: anchorOffset)
        transform.rotate(byDegrees: CGFloat(pose.rotation))
        transform.scaleX(by: CGFloat(pose.flipped ? -pose.scaleX : pose.scaleX), yBy: CGFloat(pose.scaleY))
        transform.translateX(by: 0, yBy: -anchorOffset)

        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        drawBody(size: size, rig: rig, spider: spider)
        NSGraphicsContext.restoreGraphicsState()

        if let emote = pose.emote {
            draw(emote: emote, at: NSPoint(x: centre.x + pose.x + size * 0.52,
                                           y: centre.y + pose.y - size * 0.72),
                 scale: pose.emoteScale, opacity: pose.opacity)
        }
    }

    private static func draw(emote: PetEmote, at point: NSPoint, scale: Double, opacity: Double) {
        let glyph: String
        switch emote {
        case .zzz:     glyph = "z"
        case .heart:   glyph = "♥"
        case .sparkle: glyph = "✦"
        case .bang:    glyph = "!"
        case .dots:    glyph = "…"
        case .teardrop: glyph = ","
        }
        let colour: NSColor = emote == .heart
            ? NSColor(calibratedRed: 1, green: 0.42, blue: 0.55, alpha: CGFloat(opacity))
            : (emote == .sparkle
               ? NSColor(calibratedRed: 1, green: 0.8, blue: 0.35, alpha: CGFloat(opacity))
               : NSColor(calibratedWhite: 1, alpha: 0.55 * CGFloat(opacity)))
        (glyph as NSString).draw(
            at: point,
            withAttributes: [.font: NSFont.systemFont(ofSize: CGFloat(9 * max(0.2, scale)), weight: .semibold),
                             .foregroundColor: colour]
        )
    }

    private static func draw(label: String, at point: NSPoint) {
        (label as NSString).draw(
            at: point,
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                             .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)]
        )
    }
}
