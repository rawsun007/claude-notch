import Foundation

/// The pet's skeleton.
///
/// `PetEngine` moves the pet *as a whole* — where it is on the notch, how it's
/// squashed, which way it faces. This file moves the pet's *parts*: the legs
/// take steps, the arms swing, the eyes blink and close when it sleeps. Same
/// contract as the engine: pure functions of (activity, progress, clock), so a
/// gait can be pinned in a test instead of eyeballed in a screen recording.
///
/// The artwork is a 16x16 pixel grid (assets/claude-pet.png), one colour, and
/// its parts separate cleanly:
///
///        0123456789012345
///     3   ############       head
///     5   ##.######.##       eyes are holes at col 4 and col 11
///     7  ################    arms stick out at cols 0-1 and 14-15
///     9   ############       belly
///    11    # #    # #        four legs at cols 3, 5, 10, 12
///
/// Drawing it from that grid rather than blitting the PNG is what lets the legs
/// actually walk. Coordinates below are in grid cells; the renderer scales.

/// One rectangle of the pet, in grid cells, origin top-left of the 16x16 box.
struct PetPart: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Where every moving part is right now. Offsets are in grid cells so the rig
/// is resolution-independent; rotations are degrees.
struct PetRig: Equatable {
    /// Vertical lift per leg, positive = raised off the ground.
    var legLift: [Double] = [0, 0, 0, 0]
    /// Horizontal swing per leg, positive = forward (toward +x).
    var legSwing: [Double] = [0, 0, 0, 0]
    /// How far each leg is tucked up into the body (sleeping, flipping).
    var legTuck: [Double] = [0, 0, 0, 0]
    /// Degrees, positive = raised. Mirrored: both arms raise at +45, which is
    /// what lets an activity say "arms up" without caring about left and right.
    var armLeftAngle: Double = 0
    var armRightAngle: Double = 0
    /// 1 = wide open, 0 = no eye at all. The eyes are holes in the body, so 0
    /// doesn't draw a shut eye — it erases the face. A sleeping pet uses
    /// `PetRigging.sleepingEyes`, a sliver that reads as a closed lid.
    var eyeOpen: Double = 1
    /// Eye shift, in cells — the pupils are holes, so sliding them reads as
    /// looking. Positive = toward +x.
    var eyeShift: Double = 0
}

enum PetBody {
    static let grid: Double = 16

    /// Solid body, drawn as three stacked slabs (the arms are separate so they
    /// can swing). Eyes are punched out of these afterwards.
    static let torso: [PetPart] = [
        PetPart(x: 2, y: 3, width: 12, height: 4),   // head
        PetPart(x: 2, y: 7, width: 12, height: 2),   // shoulders
        PetPart(x: 2, y: 9, width: 12, height: 2),   // belly
    ]

    /// Arms run *into* the torso rather than butting against it. Rotating a
    /// rectangle about its inner edge swings its corners away from the body and
    /// opens a wedge-shaped gap; overlapping two cells (and drawing the arms
    /// behind the torso) keeps the shoulder joint covered at every angle.
    static let armOverlap: Double = 2
    static let armLeft = PetPart(x: 0, y: 7, width: 2 + armOverlap, height: 2)
    static let armRight = PetPart(x: 14 - armOverlap, y: 7, width: 2 + armOverlap, height: 2)

    /// The shoulder each arm turns about: the torso's edge. The arm's buried
    /// half never leaves the body (it stays within `armOverlap` of the pivot,
    /// and the torso extends further than that in every direction), while the
    /// visible half swings the same two cells it always stuck out by.
    static let shoulderLeft = PetPart(x: 2, y: 7, width: 0, height: 2)
    static let shoulderRight = PetPart(x: 14, y: 7, width: 0, height: 2)

    /// Eye holes. One cell wide, two tall.
    static let eyeLeft = PetPart(x: 4, y: 5, width: 1, height: 2)
    static let eyeRight = PetPart(x: 11, y: 5, width: 1, height: 2)

    /// Four legs, left pair then right pair. Each starts a cell *above* the
    /// belly's bottom edge and is drawn behind the torso, so a leg that swings,
    /// lifts, or dangles still has its hip buried in the body instead of
    /// floating below it with daylight in between.
    static let legOverlap: Double = 1
    static let legs: [PetPart] = [
        PetPart(x: 3, y: 11 - legOverlap, width: 1, height: 2 + legOverlap),
        PetPart(x: 5, y: 11 - legOverlap, width: 1, height: 2 + legOverlap),
        PetPart(x: 10, y: 11 - legOverlap, width: 1, height: 2 + legOverlap),
        PetPart(x: 12, y: 11 - legOverlap, width: 1, height: 2 + legOverlap),
    ]

    /// How far a leg may dangle below its rest before its hip clears the belly.
    static let maxDangle: Double = legOverlap

    /// The drawn creature doesn't fill its 16x16 box: three empty rows sit above
    /// its head and two empty columns beyond each arm. Anything positioned
    /// relative to the pet (an emote, say) must measure from the body, not from
    /// the box, or it floats off into the empty space above it.
    static var bodyTop: Double { torso[0].y }              // 3 cells of headroom
    static var bodyRight: Double { armRight.x + armRight.width }

    /// Offsets, as a fraction of the sprite's size, from the sprite's centre to
    /// just above the pet's head and just past its right arm.
    static var headTopFraction: Double { bodyTop / grid - 0.5 }
    static var shoulderRightFraction: Double { bodyRight / grid - 0.5 }

    /// Diagonal gait: legs 0 and 3 swing together, 1 and 2 answer them. Real
    /// four-legged walks are diagonal pairs, and using it here is the single
    /// thing that stops the walk reading as a shuffle.
    static let gaitPhase: [Double] = [0, 0.5, 0.5, 0]
}

enum PetRigging {

    /// Full stride length and lift, in cells, at a walk.
    private static let stride: Double = 0.55
    private static let lift: Double = 0.7

    /// A shut eye still has to be visible. The eye is a hole punched out of the
    /// body and drawn from the bottom up, so a thin remainder reads as a lid
    /// closed over it — while zero reads as a pet with no face.
    static let sleepingEyes: Double = 0.28

    /// Blinks are driven by the wall clock rather than the activity's progress,
    /// so the pet keeps blinking while it holds still under your cursor.
    /// Roughly one blink every 3.4s, lasting ~0.14s — a real blink is quick,
    /// and a slow one looks like the pet is falling asleep.
    static func blink(at time: Double) -> Double {
        let period = 3.4
        let phase = time.truncatingRemainder(dividingBy: period)
        let blinkFor = 0.14
        guard phase < blinkFor else { return 1 }
        // Down and back up over the blink window.
        return abs(cos(phase / blinkFor * .pi))
    }

    /// `progress` is the activity's 0...1; `time` is a monotonic clock in
    /// seconds (used for blinking and for gaits that shouldn't stretch or
    /// squash with the activity's random duration).
    ///
    /// Everything here is in the pet's own body space, facing right. The
    /// renderer mirrors the whole sprite when the pet faces left, so reversing
    /// the gait here too would cancel that out and make it moonwalk.
    static func rig(for activity: PetActivity, progress t: Double, time: Double,
                    cursorX: Double = 0) -> PetRig {
        var rig = PetRig()
        rig.eyeOpen = blink(at: time)
        // The eyes are holes; sliding them is the cheapest possible "it's
        // looking at you", and it costs nothing to always do it.
        rig.eyeShift = PetEngine.clampMag(cursorX * 0.008, 0.5)

        switch activity {
        case .tucked:
            break

        case .peek, .boop:
            // Standing. A little weight shift so it isn't a statue.
            let sway = sin(time * 1.6) * 0.06
            rig.legSwing = [sway, sway, -sway, -sway]

        case .lookAround:
            let sway = sin(time * 2.2) * 0.08
            rig.legSwing = [sway, sway, -sway, -sway]

        case .stroll:
            // One full step cycle per 0.42s of walking, independent of how long
            // this particular stroll happens to last.
            let cycle = time / 0.42
            for i in 0..<4 {
                let phase = (cycle + PetBody.gaitPhase[i]) * 2 * .pi
                // Lift only on the up half of the cycle: a leg is either
                // stepping (up, forward) or planted (down, pushing back).
                rig.legLift[i] = max(0, sin(phase)) * lift
                rig.legSwing[i] = cos(phase) * stride
            }
            // Arms counter-swing with the diagonal pairs, like shoulders do.
            let armSwing = cos(cycle * 2 * .pi) * 14
            rig.armLeftAngle = armSwing
            rig.armRightAngle = -armSwing   // one arm up while the other is down

        case .hangLeft, .hangRight:
            // Both arms up gripping the lip; legs dangle and swing with the body.
            rig.armLeftAngle = 55
            rig.armRightAngle = 55
            let dangle = sin(t * 2 * .pi * 0.9 + 0.6) * 0.35
            for i in 0..<4 {
                rig.legSwing[i] = dangle * (1 + Double(i % 2) * 0.4)
                rig.legLift[i] = -0.25   // hanging: legs stretch down
            }

        case .sleep:
            rig.eyeOpen = sleepingEyes
            // Legs folded under, arms slack.
            rig.legTuck = [1.4, 1.4, 1.4, 1.4]
            let breath = sin(time * 0.9) * 0.05
            rig.armLeftAngle = -8 + breath * 20    // arms slack, hanging low
            rig.armRightAngle = -8 + breath * 20

        case .celebrate:
            // Legs splay on the way up, gather on the way down — the shape of
            // an actual jump, not a sprite being translated.
            let hop = abs(sin(t * 3 * .pi))
            rig.legSwing = [-hop * 0.8, -hop * 0.3, hop * 0.3, hop * 0.8]
            rig.legLift = [hop * 0.5, hop * 0.35, hop * 0.35, hop * 0.5]
            rig.armLeftAngle = 70 * hop     // both arms thrown up
            rig.armRightAngle = 70 * hop
            rig.eyeOpen = 1

        case .spin:
            // Tucked into the flip, like anything that's ever done one.
            let air = sin(PetEngine.clamp01(t) * .pi)
            rig.legTuck = Array(repeating: air * 1.6, count: 4)
            rig.armLeftAngle = 40 * air     // pulled in tight
            rig.armRightAngle = 40 * air
        }
        return rig
    }

    // MARK: - Dance

    /// One frame of a full dance routine, for the task-complete card. A plain
    /// hop says "done"; a routine says "nailed it". Card-only, so it carries its
    /// own whole-body move (offset + spin) rather than leaning on PetEngine's
    /// notch geometry. `offsetX/Y` are fractions of the sprite size, `rotation`
    /// in degrees; `offsetY` positive is up.
    struct DanceFrame: Equatable {
        var rig: PetRig
        var offsetX: Double = 0
        var offsetY: Double = 0
        var rotation: Double = 0
    }

    /// Four beats over one loop: bounce with arm pumps, side-to-side shimmy,
    /// a full spin flourish, then a big finish hop.
    static func dance(progress t: Double, time: Double) -> DanceFrame {
        var rig = PetRig()
        rig.eyeOpen = blink(at: time)
        var frame = DanceFrame(rig: rig)

        switch t {
        case ..<0.30:
            // Beat 1 — two bounces, both arms pumping up on each.
            let p = t / 0.30
            let bounce = abs(sin(p * 2 * .pi))
            frame.offsetY = bounce * 0.30
            frame.rig.armLeftAngle = 40 + 45 * bounce
            frame.rig.armRightAngle = 40 + 45 * bounce
            frame.rig.legSwing = [-0.2, -0.1, 0.1, 0.2]

        case ..<0.55:
            // Beat 2 — shimmy left and right, leaning in, arms alternating.
            let p = (t - 0.30) / 0.25
            let sway = sin(p * 2 * .pi)
            frame.offsetX = sway * 0.22
            frame.rotation = -sway * 12
            frame.rig.armLeftAngle = 30 + sway * 55    // reaches up on the way right
            frame.rig.armRightAngle = 30 - sway * 55
            frame.rig.legSwing = [sway * 0.4, sway * 0.2, sway * 0.2, sway * 0.4]

        case ..<0.80:
            // Beat 3 — a full spin, arms tucked in, up on the toes.
            let p = (t - 0.55) / 0.25
            frame.rotation = 360 * PetEngine.easeOutCubicSpin(p)
            frame.offsetY = sin(p * .pi) * 0.18
            let tuck = sin(p * .pi)
            frame.rig.armLeftAngle = 25 * tuck
            frame.rig.armRightAngle = 25 * tuck
            frame.rig.legTuck = Array(repeating: tuck * 0.5, count: 4)

        default:
            // Beat 4 — the finish: one big jump, arms flung wide open.
            let p = (t - 0.80) / 0.20
            let jump = sin(p * .pi)
            frame.offsetY = jump * 0.42
            frame.rig.armLeftAngle = 85 * jump
            frame.rig.armRightAngle = 85 * jump
            frame.rig.legSwing = [-jump * 0.9, -jump * 0.35, jump * 0.35, jump * 0.9]
            frame.rig.legLift = [jump * 0.4, jump * 0.3, jump * 0.3, jump * 0.4]
        }
        return frame
    }
}
