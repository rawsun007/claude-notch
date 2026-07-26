import SwiftUI
import AppKit

// The pet's artwork: costume, sprite, emotes, and the stage it lives on.



// MARK: - Claude brand icon

/// Bare mascot artwork (the Claude Code CLI's pixel-art crab). Bob/scale
/// animation is layered on by callers — this just draws the sprite, falling
/// back to the plain brand mark if the asset didn't ship for some reason.
/// What the pet is wearing. `.plain` is the everyday coral mascot; `.spider` is
/// the red-and-blue suit it puts on to hang upside-down off the notch on a web.
/// A costume is only colour: the rig, the physics, and the pixel layout are the
/// same pet underneath.
enum PetCostume: Equatable {
    case plain
    case spider

    static let coral = Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255)
    static let spiderRed = Color(red: 0.80, green: 0.11, blue: 0.13)
    static let spiderBlue = Color(red: 0.13, green: 0.20, blue: 0.55)
    static let darkEye = Color(red: 0.16, green: 0.09, blue: 0.06)
    static let spiderEye = Color(white: 0.96)

    /// Body colour. Spidey is red on top, blue below the shoulders — arms red,
    /// legs blue — which is the read even at 16 pixels.
    /// The suit is coloured by body PART, not by top/half. Spider-Man is a red
    /// suit with blue arms and blue legs — the earlier top/bottom split painted
    /// him red with a blue strip, which read as a little red house rather than a
    /// super-hero. Torso red, limbs blue is the silhouette everyone knows.
    enum BodyPart { case torso, arm, leg }
    func bodyColour(_ part: BodyPart) -> Color {
        switch self {
        case .plain:  return Self.coral
        case .spider: return part == .torso ? Self.spiderRed : Self.spiderBlue
        }
    }

    var eyeColour: Color {
        switch self {
        case .plain:  return Self.darkEye
        case .spider: return Self.spiderEye   // the big white mask lenses
        }
    }
}

struct PetSprite: View {
    var size: CGFloat
    /// Nil renders the pet standing at rest. Everything animated passes a rig.
    var rig: PetRig = PetRig()
    var costume: PetCostume = .plain

    static let colour = PetCostume.coral

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, canvasSize in
            let cell = min(canvasSize.width, canvasSize.height) / PetBody.grid
            func rect(_ p: PetPart, dx: Double = 0, dy: Double = 0) -> CGRect {
                CGRect(x: (p.x + dx) * cell, y: (p.y + dy) * cell,
                       width: p.width * cell, height: p.height * cell)
            }

            // Limbs first, torso last: the body then covers every joint, so a
            // swinging arm or a dangling leg stays attached to it instead of
            // opening a gap where it meets the shoulder or hip.
            let legColour = costume.bodyColour(.leg)
            for (i, leg) in PetBody.legs.enumerated() {
                let lift = rig.legLift[i] + rig.legTuck[i]
                var part = leg
                part.height = max(0, leg.height - rig.legTuck[i])
                guard part.height > 0.01 else { continue }
                ctx.fill(Path(rect(part, dx: rig.legSwing[i], dy: -lift + rig.legTuck[i])),
                         with: .color(legColour))
            }

            // Arms pivot at the shoulder — a cell inside the torso, so no angle
            // can lever their inner corner out into the open.
            func arm(_ p: PetPart, pivotCell: PetPart, angle: Double) {
                let r = rect(p)
                let pivot = CGPoint(x: pivotCell.x * cell, y: (pivotCell.y + pivotCell.height / 2) * cell)
                ctx.drawLayer { layer in
                    layer.translateBy(x: pivot.x, y: pivot.y)
                    layer.rotate(by: .degrees(angle))
                    layer.translateBy(x: -pivot.x, y: -pivot.y)
                    layer.fill(Path(r), with: .color(costume.bodyColour(.arm)))
                }
            }
            // Mirrored: a positive rig angle raises either arm, so the left one
            // turns the opposite way on screen from the right one.
            arm(PetBody.armLeft, pivotCell: PetBody.shoulderLeft, angle: rig.armLeftAngle)
            arm(PetBody.armRight, pivotCell: PetBody.shoulderRight, angle: -rig.armRightAngle)

            // Torso: head + shoulders are the top half (red), the belly is the
            // bottom (blue). The shoulder row (y == 7) is the waist of the suit.
            for slab in PetBody.torso {
                ctx.fill(Path(rect(slab)), with: .color(costume.bodyColour(.torso)))
            }

            // Eyes are painted solid dark, not punched through the body. A hole
            // only reads as an eye when the pet sits on black (the notch card);
            // on the transparent panel — where the rope pet hangs over your
            // desktop — a hole shows the wallpaper instead. Solid eyes read the
            // same everywhere. A blink shrinks the eye from the top, like a lid.
            // The spider mask has big white lenses, wider than the pet's dot eyes
            // and swept toward the outer edges — the single detail that turns two
            // eyes into a mask at 16 pixels.
            let spider = costume == .spider
            for (i, eye) in [PetBody.eyeLeft, PetBody.eyeRight].enumerated() {
                let open = max(0, rig.eyeOpen)
                guard open > 0.02 else { continue }
                var lens = eye
                if spider {
                    lens.width = 2.2
                    lens.height = 2.6
                    lens.x = (i == 0 ? eye.x - 1.0 : eye.x - 0.2)   // fan outward
                    lens.y = eye.y - 0.3
                }
                var lid = lens
                lid.height = lens.height * open
                let dy = lens.height - lid.height
                // The mask lens has a black outline, like the real one. Draw a
                // slightly larger dark lens first, then the white on top of it, so
                // a thin black rim shows all the way round.
                if spider {
                    var border = lid
                    border.x -= 0.35; border.y -= 0.35
                    border.width += 0.7; border.height += 0.7
                    ctx.fill(Path(rect(border, dx: rig.eyeShift, dy: dy)),
                             with: .color(PetCostume.darkEye))
                }
                ctx.fill(Path(rect(lid, dx: rig.eyeShift, dy: dy)),
                         with: .color(costume.eyeColour))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Row 1's icon — the same mascot, breathing at whatever tempo its mood calls
/// for, so a glance at the notch tells you what Claude is up to before you've
/// read a word of the status text. `mood` is nil when Pet Mode is off, which
/// leaves a gentle default bob rather than a dead sprite.
struct ClaudeIconView: View {
    var size: CGFloat = 15
    var mood: PetMood? = nil

    /// Bob period (seconds) and amplitude (points) per mood.
    private var beat: (period: Double, amplitude: Double) {
        switch mood {
        case .working:     return (0.7, 1.6)    // busy, quick
        case .thinking:    return (1.1, 1.2)
        case .celebrating: return (0.45, 2.4)   // bouncing
        case .startled:    return (0.3, 2.0)    // jittery
        case .sleepy:      return (3.2, 0.5)    // barely breathing
        case .curious:     return (1.5, 1.0)
        case .calm, .none: return (1.8, 0.9)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
            let (period, amplitude) = beat
            let phase = tl.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            // Celebrating hops (always up, never down) instead of bobbing.
            let wave = mood == .celebrating ? -abs(sin(phase * .pi * 2)) : sin(phase * 2 * .pi)
            let clock = tl.date.timeIntervalSinceReferenceDate
            // Even at 15pt the pet blinks, and sleeps with its eyes shut.
            let rig = PetRigging.rig(for: mood == .sleepy ? .sleep : .peek,
                                     progress: 0.5, time: clock)
            PetSprite(size: size, rig: rig)
                .offset(y: wave * amplitude)
        }
    }
}

/// The little glyph beside the pet — asleep, being petted, celebrating.
struct PetEmoteView: View {
    let emote: PetEmote
    let scale: Double

    private var symbol: String {
        switch emote {
        case .zzz:     return "zzz"
        case .heart:   return "heart.fill"
        case .sparkle: return "sparkles"
        case .bang:    return "exclamationmark"
        case .dots:    return "ellipsis"
        case .teardrop: return "drop.fill"
        }
    }

    private var tint: Color {
        switch emote {
        case .heart:   return Color(red: 1.0, green: 0.42, blue: 0.55)
        case .sparkle: return Color(red: 1.0, green: 0.80, blue: 0.35)
        case .teardrop: return Color(red: 0.45, green: 0.70, blue: 1.0)
        default:       return .white.opacity(0.55)
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(tint)
            .scaleEffect(max(0.01, scale))
            .shadow(color: tint.opacity(0.5), radius: 3)
    }
}

/// The stage the pet performs on: the collapsed notch card, grown by however
/// much room the current activity needs. Every frame asks PetEngine for a pose
/// and applies it — no SwiftUI implicit animations anywhere, because the pose
/// *is* the animation and mixing the two would double-interpolate it.
struct PetStageView: View {
    @ObservedObject var state: AppState
    let stageWidth: CGFloat
    let notchInset: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { tl in
            let activity = state.petActivity
            let stage = PetEngine.Stage(
                notchInset: Double(notchInset),
                halfWidth: Double(stageWidth / 2),
                cursorX: state.petCursorX,
                petting: state.petPetting
            )
            let progress = state.petProgress(at: tl.date)
            let pose = PetEngine.pose(for: activity, progress: progress, stage: stage)
            let clock = tl.date.timeIntervalSinceReferenceDate
            let rig = PetRigging.rig(for: activity, progress: progress, time: clock,
                                     cursorX: state.petCursorX)
            let sprite = CGFloat(activity.spriteSize)
            let anchor: UnitPoint = {
                switch activity.pivot {
                case .feet:   return .bottom
                case .paws:   return .top
                case .centre: return .center
                }
            }()

            ZStack(alignment: .top) {
                Color.clear
                // The rope: drawn behind the pet, from the notch's lip down to
                // where the pet grips it. Its end follows the pet's top along the
                // swing, so the line and the creature stay joined at every angle.
                if PetEngine.isHanging(activity) {
                    // The line follows the SWING, not the body. For the rope pet
                    // those are the same, and it meets the head (paws gripping up).
                    // Spider-Man is flipped head-down, so his body rotation carries
                    // an extra 180° — using it for the web would send the strand to
                    // the wrong side and pierce him through the chest. Strip the
                    // flip back out so the web attaches to whatever is actually at
                    // the top: his feet.
                    let bodyTheta: Double = pose.rotation * .pi / 180
                    let swingTheta = activity == .spiderHang ? bodyTheta - .pi : bodyTheta
                    let grip = CGFloat(-PetBody.headTopFraction + 0.04) * sprite
                    let topX = CGFloat(pose.x) - CGFloat(sin(swingTheta)) * grip
                    let topY = CGFloat(pose.y) - CGFloat(cos(swingTheta)) * grip
                    // A web is bright and thin; a rope is dark and soft.
                    let isWeb = activity == .spiderHang
                    let lineColour = isWeb ? Color(white: 0.92) : Color(white: 0.32)
                    // A rope has a fixed length, so while the pet is still falling
                    // the spare rope has to go somewhere: it sags. Straight line
                    // only once the fall has paid the slack out and the rope is
                    // taut. Without this the rope visibly grows out of the notch
                    // like a tape measure.
                    let restLen = CGFloat(PetEngine.ropeRestRadius(activity)) - grip
                    let span = (topX * topX + (topY - CGFloat(notchInset)) * (topY - CGFloat(notchInset))).squareRoot()
                    let slack = max(0, restLen - span)
                    Canvas { ctx, canvasSize in
                        let top = CGPoint(x: canvasSize.width / 2, y: notchInset)
                        let end = CGPoint(x: canvasSize.width / 2 + topX, y: topY)
                        var path = Path()
                        path.move(to: top)
                        if slack > 0.5 {
                            // Hangs its slack below the chord, like a real line.
                            let mid = CGPoint(x: (top.x + end.x) / 2,
                                              y: (top.y + end.y) / 2 + slack * 1.1)
                            path.addQuadCurve(to: end, control: mid)
                        } else {
                            path.addLine(to: end)
                        }
                        ctx.stroke(path, with: .color(lineColour.opacity(pose.opacity)),
                                   style: StrokeStyle(lineWidth: isWeb ? 1.5 : 2, lineCap: .round))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                PetSprite(size: sprite, rig: rig,
                          costume: activity == .spiderHang ? .spider : .plain)
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                    .scaleEffect(x: pose.flipped ? -pose.scaleX : pose.scaleX, y: pose.scaleY, anchor: anchor)
                    .rotationEffect(.degrees(pose.rotation), anchor: anchor)
                    .opacity(pose.opacity)
                    .offset(x: pose.x, y: pose.y - sprite / 2)
                if let emote = pose.emote {
                    // Anchored to the pet's head, not to the top of its sprite
                    // box — the artwork leaves three empty rows up there, and
                    // measuring from the box floated the emote far above it.
                    let headTop = pose.y + sprite * CGFloat(PetBody.headTopFraction)
                    let shoulder = pose.x + sprite * CGFloat(PetBody.shoulderRightFraction)
                    PetEmoteView(emote: emote, scale: pose.emoteScale)
                        .opacity(pose.opacity)
                        .offset(x: shoulder - 2, y: headTop - 7)
                }
            }
            .frame(width: stageWidth, alignment: .top)
            .contentShape(Rectangle())
            // Hovering the pet holds it in place (it can't run off mid-scratch)
            // and tells it where your hand is; clicking it boops it.
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    state.petCursorX = Double(p.x - stageWidth / 2)
                    if activity.isPettable, !state.petPetting { state.petPetting = true }
                case .ended:
                    if state.petPetting { state.petPetting = false }
                }
            }
            .onTapGesture { state.petBoop() }
        }
    }
}
