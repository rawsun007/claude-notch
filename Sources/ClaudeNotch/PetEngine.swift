import Foundation

/// Pet Mode's brain and body, kept free of AppKit/SwiftUI so it is pure,
/// deterministic, and unit-testable: given a mood and a seeded RNG it picks
/// the same activity sequence every run, and given an activity + progress it
/// produces the same pose. AppState owns the clock; NotchView owns the pixels.

// MARK: - RNG

/// SplitMix64 — tiny, fast, and (unlike SystemRandomNumberGenerator)
/// reproducible from a seed, which is what makes the behaviour golden-testable.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Mood

/// What the pet *feels*, derived entirely from what Claude is doing. Mood
/// picks the activity table and the tempo; it never picks an activity itself.
enum PetMood: String, CaseIterable, Equatable {
    case startled     // a turn just died, or you denied a command
    case sleepy       // nothing has happened for a long while
    case calm         // idle, recently used
    case curious      // a session exists but is quiet
    case working      // Claude is running a tool
    case thinking     // Claude is composing a reply
    case celebrating  // a task just finished
}

/// What the pet *does*. Every case is a self-contained little animation with a
/// duration; `.tucked` is the resting state (hidden inside the notch).
enum PetActivity: String, CaseIterable, Equatable {
    case tucked       // fully retracted; only the Row-1 icon shows it exists
    case peek         // pops straight down, looks at you
    case lookAround   // pops down and sweeps left/right
    case hangLeft     // clings to the notch's left corner, swinging
    case hangRight    // clings to the notch's right corner, swinging
    case stroll       // walks across the underside of the notch and back
    case sleep        // lies on the notch's lip, Zzz
    case celebrate    // triple hop with sparkles
    case boop         // squash-and-pop reaction to a click
    case spin         // booped several times in a row: a delighted backflip
    case rope         // dangles from a rope out of the notch, swinging
    case watch        // Claude is working: the pet stays out and keeps it company
    case flinch       // something went wrong: a startled recoil, then a wary peek
    case spiderHang   // hangs upside-down off the notch on a web, in the suit

    /// Sprite size in points. Big enough to read as a creature at arm's length
    /// from the screen, not a favicon: the mascot is the feature, and the notch
    /// is the only thing near it for scale.
    var spriteSize: Double {
        switch self {
        case .tucked:    return 26
        case .sleep:     return 38
        case .celebrate,
             .spin:      return 44
        default:         return 42
        }
    }

    /// Gap between the sprite and the notch's bottom lip. The pet must clear
    /// the lip completely — the hardware notch physically covers anything above
    /// it, so a sprite whose head pokes up there gets its head cut off.
    var lipClearance: Double {
        switch self {
        // Hanging is the exception: the paws grip the lip, so the sprite is
        // *meant* to start right at it.
        case .hangLeft, .hangRight: return 0
        default:                    return 5
        }
    }

    /// Length of the rope the pet dangles on (0 for everything else). The pet
    /// hangs this far below the notch's lip before its body starts.
    var ropeLength: Double { (self == .rope || self == .spiderHang) ? 26 : 0 }

    /// Vertical room the activity needs *above* its resting position — a hop,
    /// a flip, a bob. The pet rests this much lower so the top of its arc still
    /// clears the notch lip, and the stage grows to match.
    var headroom: Double {
        switch self {
        case .celebrate: return 17
        case .spin:      return 18
        case .peek,
             .lookAround,
             .boop:      return 6
        case .stroll:    return 5
        default:         return 2
        }
    }

    /// Where the sprite's centre rests, measured down from the card's top edge.
    /// Derived from the sprite and the activity's upward travel rather than
    /// picked by hand: a celebrating pet hops 15pt, so resting it 5pt below the
    /// lip means the hardware notch shears the top off every hop.
    func restCentreY(notchInset: Double) -> Double {
        // On a rope the pet hangs the rope's length below the lip.
        if self == .rope || self == .spiderHang { return notchInset + ropeLength + spriteSize / 2 }
        return notchInset + lipClearance + headroom + spriteSize / 2
    }

    /// Extra pixels the notch card grows *below* the physical notch to give
    /// this activity room. `tucked` adds none, which keeps the collapsed notch
    /// exactly the size of the hardware cutout.
    var stageDrop: Double {
        guard self != .tucked else { return 0 }
        // A rope hangs straight down at rest (its lowest point), so the stage
        // just has to fit the rope plus the whole sprite.
        if self == .rope || self == .spiderHang { return ropeLength + spriteSize + 6 }
        // Enough for the sprite at rest, plus the slack its motion needs, plus
        // a little breathing room above the card's bottom curve.
        return lipClearance + spriteSize + headroom + 6
    }

    /// Extra pixels of card width, split evenly left/right. Every visible
    /// activity gets some: a card exactly as wide as the hardware cutout leaves
    /// the pet nowhere to stand near the edges, and reads as a sprite jammed in
    /// a slot rather than one living on the notch.
    var stageWidthPad: Double {
        switch self {
        case .tucked:    return 0
        case .stroll:    return 96
        case .celebrate,
             .spin:      return 44
        case .hangLeft,
             .hangRight: return 40
        case .rope, .spiderHang: return 60   // room for the pendulum swing
        default:         return 28
        }
    }

    /// Whether hovering the pet should hold it in place instead of letting the
    /// timeline run out. You can't pet a pet that runs away mid-scratch.
    var isPettable: Bool { self != .tucked }

    /// What the sprite turns and squashes around. Feet for anything standing
    /// (a squash should flatten it onto the surface, not shrink it in mid-air),
    /// paws for hanging, and the body's centre for the backflip — pivoting a
    /// flip at the feet swings the pet straight down through the card.
    var pivot: PetPivot {
        switch self {
        case .hangLeft, .hangRight: return .paws     // grips from the top
        // On a rope the body tilts along the line, so it turns about its centre
        // and the rope is drawn to whichever way it's swinging.
        case .spin, .rope, .spiderHang: return .centre
        default:                    return .feet
        }
    }

    /// How close the sprite's *centre* may get to the card's side wall before
    /// half of it hangs outside the black plate and gets clipped.
    func maxCentreOffset(halfWidth: Double) -> Double {
        max(0, halfWidth - spriteSize / 2 - 2)
    }
}

/// Where a pose's rotation and scale are applied from.
enum PetPivot: Equatable {
    case feet
    case paws
    case centre
}

// MARK: - Emotes

/// Little glyph drawn beside the sprite. Purely a rendering hint — the engine
/// decides *when*, NotchView decides what it looks like.
enum PetEmote: String, Equatable {
    case zzz       // asleep
    case heart     // being petted
    case sparkle   // celebrating / just booped
    case bang      // startled
    case dots      // idly thinking
}

// MARK: - Pose

/// One frame of the pet, in points, relative to the top-centre of the notch
/// card. `y` is the sprite's centre measured down from the card's top edge —
/// anything above `notchInset` is behind the physical notch, i.e. invisible,
/// which is exactly how the pet "hides."
struct PetPose: Equatable {
    var x: Double = 0
    var y: Double = 0
    var rotation: Double = 0      // degrees, clockwise
    var scaleX: Double = 1
    var scaleY: Double = 1
    var flipped: Bool = false     // sprite faces left
    var opacity: Double = 1
    var emote: PetEmote? = nil
    var emoteScale: Double = 1    // 0 while the emote pops in
    /// A web being shot right now: 0 = none, else 0...1 through the shot's life
    /// (extends, then fades). `webShotAngle` is where it fires, degrees clockwise
    /// from straight up. Only the Spider-Pet ever sets it.
    var webShot: Double = 0
    var webShotAngle: Double = 0
}

// MARK: - Engine

enum PetEngine {

    // MARK: Mood

    /// Everything the engine is allowed to know about the app. Passing a
    /// struct (instead of reaching into AppState) is what lets the mood table
    /// be tested without a running app.
    struct Context: Equatable {
        var isIdleMode: Bool = true          // the notch is showing the idle pill
        var isHovering: Bool = false
        var persistentDisplay: Bool = false
        var isWorking: Bool = false          // Claude is running a tool
        var isThinking: Bool = false
        var justFinished: Bool = false       // a task completed in the last few seconds
        var justFailed: Bool = false         // a turn died, or a command was denied
        var secondsSinceActivity: Double = 0 // since the last hook event

        /// The pet only acts when the notch is genuinely at rest. Never over an
        /// open card, a hover, or a pinned notch — that would be a flicker on
        /// top of something the user is reading.
        var allowsAutonomy: Bool {
            isIdleMode && !isHovering && !persistentDisplay
        }
    }

    /// Sleep only after a long quiet stretch — 5 minutes, long enough that the
    /// user has clearly walked away rather than paused to read.
    static let sleepAfter: Double = 300

    static func mood(for ctx: Context) -> PetMood {
        // A failure outranks a completion: if the turn died, it did not finish.
        if ctx.justFailed { return .startled }
        if ctx.justFinished { return .celebrating }
        if ctx.isWorking { return .working }
        if ctx.isThinking { return .thinking }
        if ctx.secondsSinceActivity >= sleepAfter { return .sleepy }
        if ctx.secondsSinceActivity >= 45 { return .calm }
        return .curious
    }

    // MARK: Activity choice

    /// Relative weights per mood. Ordered (not a dictionary) so a seeded pick
    /// is stable across runs and platforms — dictionary iteration order is not.
    static func weights(for mood: PetMood) -> [(PetActivity, Double)] {
        switch mood {
        case .sleepy:
            return [(.sleep, 6), (.peek, 1), (.hangLeft, 1)]
        case .calm:
            return [(.peek, 4), (.lookAround, 3), (.hangLeft, 2), (.hangRight, 2), (.stroll, 2), (.rope, 2), (.spiderHang, 1), (.sleep, 1)]
        case .curious:
            return [(.lookAround, 4), (.peek, 3), (.stroll, 3), (.rope, 3), (.spiderHang, 1), (.hangRight, 2), (.hangLeft, 2)]
        case .working:
            // Claude is working, so the pet works: it stays out and watches the
            // job instead of hiding for the whole run. This is the point of
            // having it at all — a mascot that vanishes exactly when there is
            // something to watch is just a screensaver.
            return [(.watch, 5), (.peek, 1)]
        case .thinking:
            // Thinking is quieter than a tool run. The pet waits with you.
            return [(.watch, 3), (.peek, 2), (.lookAround, 1)]
        case .celebrating:
            return [(.celebrate, 1)]
        case .startled:
            return [(.flinch, 1)]
        }
    }

    /// Weighted pick over `weights(for:)`. Total weight is small, so a simple
    /// linear scan beats an alias table and stays obvious.
    static func pickActivity(mood: PetMood, using rng: inout some RandomNumberGenerator) -> PetActivity {
        let table = weights(for: mood)
        let total = table.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return .tucked }
        var roll = Double.random(in: 0..<total, using: &rng)
        for (activity, weight) in table {
            roll -= weight
            if roll < 0 { return activity }
        }
        return table[table.count - 1].0
    }

    /// How long one performance lasts. Sleeping is long (it's a state, not a
    /// stunt); boops are instant.
    static func duration(of activity: PetActivity, using rng: inout some RandomNumberGenerator) -> Double {
        switch activity {
        case .tucked:     return 0
        case .peek:       return Double.random(in: 2.2...3.2, using: &rng)
        case .lookAround: return Double.random(in: 3.0...4.2, using: &rng)
        case .hangLeft,
             .hangRight:  return Double.random(in: 3.4...5.0, using: &rng)
        case .stroll:     return Double.random(in: 4.5...6.0, using: &rng)
        case .sleep:      return Double.random(in: 8.0...14.0, using: &rng)
        case .celebrate:  return 2.4
        case .boop:       return 0.85
        case .spin:       return 1.5
        // Fixed, not sampled: the rope pose is a real simulation in seconds
        // (free fall, catch, swing), so its length has to be the one the physics
        // was tuned for — a random duration would rescale the whole thing and
        // change gravity with it.
        case .rope:       return ropeDuration
        case .watch:      return Double.random(in: 3.5...5.0, using: &rng)
        case .flinch:     return 2.0
        case .spiderHang: return ropeDuration
        }
    }

    /// Gap before the next unprompted performance, measured from the end of the
    /// last one. A curious pet checks in on you; a sleepy one barely stirs.
    ///
    /// These are deliberately long. The pet is ambient — something you catch out
    /// of the corner of your eye now and then, not a thing that keeps walking
    /// across the notch you're trying to work under. The first cut of this had
    /// the pet visible about a quarter of every idle minute, which is charming
    /// for ten minutes and maddening for an afternoon.
    static func nextDelay(mood: PetMood, using rng: inout some RandomNumberGenerator) -> Double {
        switch mood {
        case .curious:     return Double.random(in: 45...100, using: &rng)
        case .calm:        return Double.random(in: 90...200, using: &rng)
        case .sleepy:      return Double.random(in: 240...480, using: &rng)
        // While Claude works the pet is ON DUTY: it comes back almost at once,
        // so it is present for the run rather than flashing up once in the
        // middle of it. The duty-cycle rule below is waived for the same reason.
        case .working,
             .thinking:    return Double.random(in: 0.5...2.0, using: &rng)
        case .celebrating: return 6
        case .startled:    return 5
        }
    }

    /// The gap that actually gets used: never less than `dutyCycle` times as
    /// long as the performance that just ended. This is the guarantee the plain
    /// ranges can't give on their own — a 14-second nap must buy a proportionally
    /// long silence afterwards, or a mood whose delay range happens to be short
    /// leaves the pet on screen a third of the time.
    static let dutyCycle: Double = 11

    static func nextDelay(mood: PetMood, after activity: PetActivity,
                          lasting duration: Double,
                          using rng: inout some RandomNumberGenerator) -> Double {
        let base = nextDelay(mood: mood, using: &rng)
        // A boop is the user's doing, not the pet's, so it doesn't earn silence.
        guard activity != .boop, activity != .spin else { return base }
        // Neither does anything the pet does while Claude is busy. The duty
        // cycle exists to stop an idle pet pestering you all afternoon; during a
        // tool run the pet is meant to be there, and applying the rule would put
        // it on screen for four seconds out of every minute of a long run, which
        // is the opposite of keeping you company.
        guard mood != .working, mood != .thinking else { return base }
        return max(base, duration * dutyCycle)
    }

    // MARK: Rope physics

    /// The rope act is simulated, not keyframed. Three phases, all closed-form so
    /// the pose stays a pure function of time:
    ///
    ///   1. Free fall. The pet hops off the lip with a little sideways speed and
    ///      falls under gravity while the rope pays out slack.
    ///   2. The catch. The rope goes taut. Its velocity splits into a radial part
    ///      (along the rope — this is what the rope's elasticity absorbs) and a
    ///      tangential part (across it — this is what becomes the swing). That
    ///      split is the whole reason it looks right: the pet doesn't start
    ///      swinging because we told it to, it swings because it was still moving
    ///      sideways when the rope stopped it falling.
    ///   3. Hang. An elastic pendulum: a damped spring along the rope (fast, dies
    ///      in half a second) riding under a damped pendulum across it (slow,
    ///      period sqrt(L/g), bleeds out over the act).
    static let ropeDuration: Double = 5.0
    /// Fraction of the hang a single web-shot is visible for.
    static let webShotLife: Double = 0.16
    /// Points per second squared. Not 9.8 — the stage is 40-odd points tall, so
    /// gravity is tuned for the scale, the way it always is in a game.
    static let ropeGravity: Double = 1200
    /// Sideways speed as it leaves the notch. Zero here means a dead-straight
    /// drop and no swing at all: this number *is* the swing.
    static let ropeKickX: Double = 42
    /// The rope's own spring: stiff and well damped, so the catch reads as a
    /// snap-and-ring rather than a bungee.
    static let ropeSpringOmega: Double = 17
    static let ropeSpringZeta: Double = 0.20
    /// How far the rope can actually stretch. The catch is violent enough to ask
    /// for far more than a 26-point rope would ever give.
    static let ropeMaxStretch: Double = 6
    /// Swing damping (1/s): air, and a knot that isn't frictionless.
    static let ropeSwingDamping: Double = 0.32
    /// The pet is a body on the end of a line, not a bead on it — it trails the
    /// rope's angle by a beat instead of staying rigidly in line with it.
    static let ropeBobLag: Double = 0.06

    struct RopeState: Equatable {
        /// Sprite centre, relative to the notch anchor (+x right, y absolute).
        var x: Double = 0
        var y: Double = 0
        /// Rope angle from straight down, radians, and its rate.
        var angle: Double = 0
        var angleRate: Double = 0
        /// Anchor-to-centre distance and its rate (the rope's stretch).
        var radius: Double = 0
        var radialRate: Double = 0
        var taut: Bool = false
    }

    /// `restRadius` is anchor-to-sprite-centre with the rope hanging slack-free;
    /// `dropStart` is the centre's y while the pet is still hidden in the notch.
    static func ropeState(seconds s: Double, anchor: Double,
                          restRadius L0: Double, dropStart y0: Double) -> RopeState {
        let g = ropeGravity
        let vx = ropeKickX
        // Time to fall far enough that the rope is out of slack. Solved on the
        // vertical alone: the sideways kick moves it a few points in a third of a
        // second, far inside the rope's own stretch.
        let fall = max(0.0001, L0 - (y0 - anchor))
        let sTaut = (2 * fall / g).squareRoot()

        guard s >= sTaut else {
            var state = RopeState()
            state.x = vx * s
            state.y = y0 + 0.5 * g * s * s
            state.radius = (state.x * state.x + (state.y - anchor) * (state.y - anchor)).squareRoot()
            state.radialRate = g * s          // still in free fall: all of it is fall
            return state
        }

        // The catch. Position and velocity at the instant the rope bites.
        let xT = vx * sTaut
        let vy = g * sTaut
        let theta0 = atan2(xT, L0)
        let sinT = sin(theta0), cosT = cos(theta0)
        let vRadial = vx * sinT + vy * cosT      // along the rope: the spring eats this
        let vTangent = vx * cosT - vy * sinT     // across it: this becomes the swing
        let omega0 = vTangent / L0

        let u = s - sTaut

        // Pendulum: damped free response from (theta0, omega0).
        let wp = (g / L0).squareRoot()
        let lam = ropeSwingDamping
        let wd = max(0.1, (wp * wp - lam * lam).squareRoot())
        let a = theta0
        let b = (omega0 + lam * theta0) / wd
        let decay = exp(-lam * u)
        let cw = cos(wd * u), sw = sin(wd * u)
        let angle = decay * (a * cw + b * sw)
        let angleRate = decay * (-lam * (a * cw + b * sw) + wd * (b * cw - a * sw))

        // Rope stretch: damped spring, launched by the radial velocity, starting
        // at its rest length (the rope is inextensible until this moment).
        let wr = ropeSpringOmega
        let zr = ropeSpringZeta
        let wrd = wr * (1 - zr * zr).squareRoot()
        let amp = clampMag(vRadial / wrd, ropeMaxStretch)
        let rDecay = exp(-zr * wr * u)
        let stretch = rDecay * amp * sin(wrd * u)
        let stretchRate = rDecay * amp * (wrd * cos(wrd * u) - zr * wr * sin(wrd * u))
        let radius = L0 + stretch

        var state = RopeState()
        state.taut = true
        state.angle = angle
        state.angleRate = angleRate
        state.radius = radius
        state.radialRate = stretchRate
        state.x = sin(angle) * radius
        state.y = anchor + cos(angle) * radius
        return state
    }

    /// Anchor-to-sprite-centre distance with the rope hanging straight and slack-free.
    static func ropeRestRadius(_ activity: PetActivity) -> Double {
        activity.ropeLength + activity.spriteSize / 2
    }

    /// Whether an activity dangles on a line out of the notch (rope or web). Both
    /// share the same physics; only the costume and the flip differ.
    static func isHanging(_ activity: PetActivity) -> Bool {
        activity == .rope || activity == .spiderHang
    }

    // MARK: Pose

    /// Geometry the pose math needs from the renderer. `halfWidth` is half the
    /// *stage* width (the card), so travelling activities know where the walls
    /// are without the engine knowing what a screen is.
    struct Stage: Equatable {
        var notchInset: Double = 32
        var halfWidth: Double = 100
        /// Cursor offset from the notch centre in points, already clamped by
        /// the caller. Drives eye-contact/lean; 0 when the cursor is far away.
        var cursorX: Double = 0
        /// True while the cursor rests on the pet — freezes the retract and
        /// swaps in the heart emote.
        var petting: Bool = false
    }

    /// `progress` is 0...1 across the activity's duration. The pose is a pure
    /// function of it, so the renderer can drive it from any clock (and the
    /// tests can sample it at exact instants).
    static func pose(for activity: PetActivity, progress t: Double, stage: Stage) -> PetPose {
        let t = min(1, max(0, t))
        guard activity != .tucked else {
            // Parked behind the physical notch: still rendered (so the sprite
            // is warm and the transition has something to spring from), just
            // never visible.
            return PetPose(x: 0, y: hiddenCentreY(for: .tucked, notchInset: stage.notchInset), opacity: 0)
        }

        // Drop-out on a real spring: it dives, overshoots the ground, and
        // settles with a bounce. While being petted the retract never starts —
        // the pet stays down for you.
        let spring = springStep(t / entryWindow, omega: entryOmega, zeta: entryZeta)
        let enter = spring.value
        let exitT = stage.petting ? 0 : clamp01((t - 0.84) / 0.16)
        let retract = easeInCubic(exitT)
        let envelope = enter * (1 - retract)

        let restY = activity.restCentreY(notchInset: stage.notchInset)
        // Fully behind the hardware notch when hidden — the whole sprite, not
        // just its middle, or the pet's head shows above the lip at rest.
        let hiddenY = hiddenCentreY(for: activity, notchInset: stage.notchInset)
        var pose = PetPose()
        pose.y = hiddenY + (restY - hiddenY) * envelope
        // Solid the whole way. The pet used to fade out as it retracted, which
        // made it dissolve in mid-air instead of climbing back into the notch —
        // and the fade was never needed: the retract already carries the whole
        // sprite up behind the hardware cutout, which hides it far better than
        // any alpha ramp. A creature that goes transparent is a ghost, not a pet.
        pose.opacity = 1

        // Squash & stretch straight off the spring's analytic velocity: the pet
        // stretches thin as it dives (fast, downward) and squashes wide as the
        // spring reverses at the bottom (the impact). Real motion, exact — no
        // finite-difference approximation. Muted by the retract so it doesn't
        // twitch on the way back in.
        let dropSpan = restY - hiddenY
        let vVel = spring.velocity / entryWindow * dropSpan * (1 - retract)
        let stretch = clampMag(vVel * 0.0016, 0.18)
        pose.scaleY = 1 + stretch
        pose.scaleX = 1 - stretch * 0.7

        // Eye contact: the pet leans toward the cursor whenever it's near.
        let lean = clampMag(stage.cursorX * 0.16, 9)

        switch activity {
        case .tucked:
            break

        case .peek:
            pose.x = lean
            pose.y += sin(t * 2 * .pi * 2.4) * 1.6 * envelope
            pose.rotation = lean * 0.5
            pose.flipped = stage.cursorX < -4
            pose.emote = stage.petting ? .heart : (t > 0.45 && t < 0.7 ? .dots : nil)

        case .lookAround:
            // Two slow sweeps, head tilting into the turn.
            let sweep = sin(t * 2 * .pi * 1.6)
            pose.x = sweep * 11 * envelope + lean * 0.4
            pose.rotation = -sweep * 7
            pose.flipped = sweep < 0
            pose.y += cos(t * 2 * .pi * 3.2) * 1.2 * envelope
            pose.emote = stage.petting ? .heart : nil

        case .hangLeft, .hangRight:
            // Clings to a corner and swings like it's holding the notch's lip.
            let side: Double = activity == .hangLeft ? -1 : 1
            let swing = sin(t * 2 * .pi * 0.9) * 6
            // Clamp against the wall: the entry envelope overshoots past 1
            // (that's the springy pop), and half a sprite hangs either side of
            // its centre — unclamped, the pet slides out through the side of
            // the card and gets sliced off by the clip.
            let wall = activity.maxCentreOffset(halfWidth: stage.halfWidth)
            pose.x = clampMag(side * wall * envelope, wall)
            // Paws on the lip: the sprite hangs from the notch's bottom edge.
            pose.y = hiddenY + (stage.notchInset + activity.spriteSize * 0.42 - hiddenY) * envelope
            pose.rotation = side * 24 + swing
            pose.flipped = side < 0
            pose.scaleY = 1 + stretch * 0.5
            pose.scaleX = 1 - stretch * 0.35
            pose.emote = stage.petting ? .heart : nil

        case .stroll:
            // Out from the left wall, across, and back — with a walk bounce and
            // a beat of hesitation at the far end where it turns around.
            let travel = activity.maxCentreOffset(halfWidth: stage.halfWidth) - 4
            let path = sin(t * 2 * .pi * 0.5 - .pi / 2)   // -1 → 1 → -1
            pose.x = clampMag(path * travel * envelope, travel)
            let facingRight = cos(t * 2 * .pi * 0.5 - .pi / 2) >= 0
            pose.flipped = !facingRight
            let step = abs(sin(t * 2 * .pi * 5))
            pose.y += -step * 2.6 * envelope
            pose.rotation = (facingRight ? 4 : -4) * step
            pose.scaleY = 1 + stretch * 0.6 + step * 0.05
            pose.scaleX = 1 - stretch * 0.4 - step * 0.03
            pose.emote = stage.petting ? .heart : nil

        case .sleep:
            // A gentle lean, not a face-plant: the notch sits above eye level,
            // so the flatter the pet lies the less of its face you can see.
            pose.x = 2
            pose.rotation = -5
            pose.scaleY = 0.95 + sin(t * 2 * .pi * 0.6) * 0.03   // breathing
            pose.scaleX = 1.03 - sin(t * 2 * .pi * 0.6) * 0.03
            pose.y += sin(t * 2 * .pi * 0.6) * 0.8 * envelope
            pose.emote = stage.petting ? .heart : .zzz
            pose.emoteScale = 0.85 + sin(t * 2 * .pi * 0.6) * 0.15

        case .celebrate:
            // Three hops, each with stretch on the rise and squash on landing.
            let hopPhase = t * 3
            let hop = abs(sin(hopPhase * .pi))
            pose.y -= hop * 15 * envelope
            let rise = cos(hopPhase * .pi)   // +1 rising, -1 falling
            pose.scaleY = 1 + hop * 0.18 * (rise >= 0 ? 1 : 0.4)
            pose.scaleX = 1 - hop * 0.12
            pose.rotation = sin(hopPhase * 2 * .pi) * 6
            pose.emote = .sparkle
            pose.emoteScale = 0.6 + hop * 0.6

        case .spin:
            // Earned, not scheduled: boop the pet a few times in a row and it
            // backflips. Two full turns, launched on the first and landing
            // squashed on the last.
            let air = sin(clamp01(t) * .pi)
            pose.y -= air * 16 * envelope
            pose.rotation = -720 * easeOutCubicSpin(t)
            let land = t > 0.92 ? (t - 0.92) / 0.08 : 0
            pose.scaleY = 1 + air * 0.12 - land * 0.24
            pose.scaleX = 1 - air * 0.08 + land * 0.20
            pose.emote = .sparkle
            pose.emoteScale = 0.5 + air * 0.7

        case .boop:
            // Squash on contact, overshoot back out, settle. Short and snappy —
            // the whole point is that it answers the click immediately. A boop
            // can also arrive while the pet is tucked (the user clicked the
            // notch), so the drop-out envelope still applies underneath.
            let squash = exp(-t * 6) * cos(t * 2 * .pi * 3.2)
            pose.y += squash * 4
            pose.scaleY = 1 - squash * 0.22
            pose.scaleX = 1 + squash * 0.18
            pose.rotation = squash * 5
            pose.emote = t < 0.6 ? .sparkle : (stage.petting ? .heart : nil)
            pose.emoteScale = 1 - t * 0.4

        case .watch:
            // On duty. It paces a little, bobs, and keeps glancing at the cursor
            // — busy but not frantic, because it is watching work happen rather
            // than doing a trick. Slower than a stroll and shorter in travel, so
            // it reads as pacing on the spot rather than going somewhere.
            let pace = sin(t * 2 * .pi * 0.7)
            pose.x = pace * 7 * envelope + lean * 0.5
            pose.flipped = pace < 0
            // A small, steady bounce: the pet is up on its toes.
            let step = abs(sin(t * 2 * .pi * 2.2))
            pose.y -= step * 1.8 * envelope
            pose.rotation = pace * 4
            pose.scaleY = 1 + stretch * 0.6 + step * 0.04
            pose.scaleX = 1 - stretch * 0.4 - step * 0.03
            // Thought dots while it watches, unless you are scratching its head.
            pose.emote = stage.petting ? .heart : (t > 0.25 ? .dots : nil)
            pose.emoteScale = 0.8

        case .flinch:
            // Startled. It jumps back from whatever just happened, shakes, then
            // creeps forward again to look at it — the recoil is fast and the
            // recovery is slow, which is what makes it read as a fright rather
            // than a dance step.
            let recoil = exp(-t * 5) * cos(t * 2 * .pi * 4)
            pose.x = recoil * 6 * envelope
            pose.y -= abs(recoil) * 3 * envelope
            pose.rotation = recoil * 9
            pose.scaleY = 1 + stretch * 0.5 - abs(recoil) * 0.10
            pose.scaleX = 1 - stretch * 0.35 + abs(recoil) * 0.08
            pose.emote = stage.petting ? .heart : (t < 0.55 ? .bang : .dots)
            pose.emoteScale = 1.1 - t * 0.5

        case .rope, .spiderHang:
            // Simulated, not keyframed — see `ropeState`. The generic drop-out
            // spring is deliberately *not* used here: the drop act has its own
            // entry (a fall), and stacking a second spring on top of gravity is
            // what made the old version read as a cartoon bob rather than a
            // weight on a line. Only the retract is shared, to reel it back in.
            //
            // Spider-Man hangs the same way, on the same physics, with two
            // differences: he comes down HEAD FIRST (180° flip) and the renderer
            // draws a web instead of a rope and puts him in the suit.
            let anchor = stage.notchInset
            let rope = ropeState(seconds: t * ropeDuration, anchor: anchor,
                                 restRadius: ropeRestRadius(activity), dropStart: hiddenY)
            pose.x = rope.x * (1 - retract)
            pose.y = hiddenY + (rope.y - hiddenY) * (1 - retract)
            // The body trails the line instead of being welded to it.
            let swingRotation = (rope.angle - ropeBobLag * rope.angleRate) * 180 / .pi
            pose.rotation = activity == .spiderHang ? swingRotation + 180 : swingRotation
            pose.flipped = rope.angle < 0
            // Stretch along the line: thin while falling and while it pulls him
            // back up, fat as the line bottoms out under him.
            let ropeStretch = clampMag(rope.radialRate * 0.0012, 0.18)
            pose.scaleY = 1 + ropeStretch
            pose.scaleX = 1 - ropeStretch * 0.7
            pose.emote = stage.petting ? .heart : nil

            // THWIP. Two web-shots, fired near the extremes of the swing where a
            // real one would sling a line to change direction, each aimed out and
            // up toward the corner it is swinging away from. A shot lives for
            // `webShotLife` of the act and is a pure function of t, so a test can
            // catch it and the render never has to keep state.
            if activity == .spiderHang {
                for (fireAt, side) in [(0.34, -1.0), (0.62, 1.0)] {
                    let age = (t - fireAt) / webShotLife
                    guard age >= 0, age < 1 else { continue }
                    pose.webShot = age
                    // Up and out to the side it is heading toward, in screen space
                    // (the sprite is flipped, but the strand is drawn in the card).
                    pose.webShotAngle = side * 52
                }
            }
        }

        // Hard floor: the entry envelope deliberately overshoots (that's the
        // springy pop), and on a tall activity that overshoot is enough to push
        // the pet's feet past the bottom of the card, where they get clipped.
        pose.y = min(pose.y, stage.notchInset + activity.stageDrop - activity.spriteSize / 2)

        // Petting always wins on the emote, and nudges the pet toward the hand.
        if stage.petting {
            pose.emote = .heart
            pose.x += clampMag(stage.cursorX * 0.08, 4)
        }
        return pose
    }

    /// Where the sprite's centre sits while it's hiding: high enough that its
    /// bottom edge is still above the notch's lip.
    static func hiddenCentreY(for activity: PetActivity, notchInset: Double) -> Double {
        notchInset - activity.spriteSize / 2 - 2
    }

    /// The drop-out envelope alone (spring in, ease out). Used by the hanging
    /// pose, which rides the same entry as everything else.
    private static func envelopeValue(activity: PetActivity, t: Double, stage: Stage) -> Double {
        let enter = springStep(t / entryWindow, omega: entryOmega, zeta: entryZeta).value
        let exitT = stage.petting ? 0 : clamp01((t - 0.84) / 0.16)
        return enter * (1 - easeInCubic(exitT))
    }

    // MARK: Physics

    /// The pet moves on real springs, not scripted curves.
    ///
    /// `springStep` is the closed-form step response of an under-damped
    /// second-order system — a mass on a spring pulled to a target and let go.
    /// It overshoots and settles with a decaying bounce, which is what gives the
    /// pet weight; a hand-drawn ease can fake the overshoot but not the way a
    /// heavier thing rings longer. Being a closed form (not an integrator) keeps
    /// it a pure function of time, so the whole pose stays golden-testable.
    ///
    /// Returns the normalised position (0 at rest, →1 settled) and its exact
    /// analytic velocity, which the squash-and-stretch reads directly instead of
    /// finite-differencing — so the pet stretches on the dive and squashes on
    /// impact from the true motion, not an approximation of it.
    ///
    /// `omega` is the natural frequency (how snappy), `zeta` the damping ratio
    /// (< 1 is bouncy, 1 is a dead stop). Time is in the same units the caller
    /// samples in.
    static func springStep(_ t: Double, omega: Double, zeta: Double) -> (value: Double, velocity: Double) {
        guard t > 0 else { return (0, 0) }
        guard zeta < 1 else {
            // Critically/over-damped: no bounce, just a firm settle.
            let e = exp(-omega * t)
            return (1 - e * (1 + omega * t), omega * omega * t * e)
        }
        let wd = omega * (1 - zeta * zeta).squareRoot()   // damped frequency
        let e = exp(-zeta * omega * t)
        let value = 1 - e * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
        // d/dt of the step response collapses to this single sine term.
        let velocity = e * (omega * omega / wd) * sin(wd * t)
        return (value, velocity)
    }

    /// The entry spring shared by the drop-out envelope and its velocity read.
    /// Tuned for one clear bounce inside the entry window: snappy enough to land
    /// fast, loose enough to feel like it has mass.
    static let entryOmega: Double = 7
    static let entryZeta: Double = 0.5
    /// Fraction of the activity the drop occupies (spring time = t / this).
    static let entryWindow: Double = 0.16

    // MARK: Easing

    static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
    static func clampMag(_ v: Double, _ m: Double) -> Double { min(m, max(-m, v)) }

    static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        let p = t - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    static func easeInCubic(_ t: Double) -> Double { t * t * t }

    /// The flip decelerates into its landing rather than stopping dead —
    /// otherwise the last quarter-turn reads as a dropped frame.
    static func easeOutCubicSpin(_ t: Double) -> Double {
        let p = 1 - clamp01(t)
        return 1 - p * p * p
    }
}
