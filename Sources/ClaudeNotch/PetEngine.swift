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

    /// Extra pixels the notch card grows *below* the physical notch to give
    /// this activity room. `tucked` adds none, which keeps the collapsed notch
    /// exactly the size of the hardware cutout.
    var stageDrop: Double {
        switch self {
        case .tucked:     return 0
        case .peek:       return 46
        case .lookAround: return 44
        case .hangLeft,
             .hangRight:  return 46
        case .stroll:     return 42
        case .sleep:      return 34
        case .celebrate:  return 58
        case .boop:       return 50
        case .spin:       return 60
        }
    }

    /// Extra pixels of card width, split evenly left/right. Only the activities
    /// that travel sideways need it; the rest stay inside the cutout so the
    /// card reads as "the notch itself," not a panel.
    var stageWidthPad: Double {
        switch self {
        case .stroll:    return 64
        case .celebrate: return 24
        case .spin:      return 20
        default:         return 0
        }
    }

    /// Sprite size in points. The peeking pet is deliberately bigger than the
    /// 15pt Row-1 icon — it's the whole point of the moment.
    var spriteSize: Double {
        switch self {
        case .tucked:    return 22
        case .sleep:     return 30
        case .celebrate,
             .spin:      return 34
        default:         return 32
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
        case .hangLeft, .hangRight: return .paws
        case .spin:                 return .centre
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
            return [(.peek, 4), (.lookAround, 3), (.hangLeft, 2), (.hangRight, 2), (.stroll, 2), (.sleep, 1)]
        case .curious:
            return [(.lookAround, 4), (.peek, 3), (.stroll, 3), (.hangRight, 2), (.hangLeft, 2)]
        case .working, .thinking:
            // Claude is busy; the pet stays out of the way. Autonomy is gated
            // upstream anyway, but keep the table honest.
            return [(.tucked, 1)]
        case .celebrating:
            return [(.celebrate, 1)]
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
        }
    }

    /// Gap before the next unprompted performance. A curious pet pesters you;
    /// a sleepy one barely stirs.
    static func nextDelay(mood: PetMood, using rng: inout some RandomNumberGenerator) -> Double {
        switch mood {
        case .curious:     return Double.random(in: 12...26, using: &rng)
        case .calm:        return Double.random(in: 22...48, using: &rng)
        case .sleepy:      return Double.random(in: 40...90, using: &rng)
        case .working,
             .thinking:    return Double.random(in: 8...14, using: &rng)   // re-check soon
        case .celebrating: return 6
        }
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
            return PetPose(x: 0, y: stage.notchInset * 0.35, opacity: 0)
        }

        // Drop envelope: springy on the way out, clean on the way back. While
        // being petted the retract never starts — the pet stays down for you.
        let enter = easeOutBack(clamp01(t / 0.16))
        let exitT = stage.petting ? 0 : clamp01((t - 0.84) / 0.16)
        let retract = easeInCubic(exitT)
        let envelope = enter * (1 - retract)

        let depth = activity.stageDrop
        // Sprite centre sits a little above the bottom of its stage so there's
        // breathing room against the card's bottom curve.
        let restY = stage.notchInset + depth * 0.42
        var pose = PetPose()
        pose.y = stage.notchInset * 0.35 + (restY - stage.notchInset * 0.35) * envelope
        pose.opacity = min(1, envelope * 2.2)

        // Vertical velocity of the envelope drives squash & stretch — the pet
        // stretches as it dives out and squashes when it lands. This is what
        // separates "sprite moving" from "creature moving."
        let vel = (envelope - envelopeValue(activity: activity, t: max(0, t - 0.02), stage: stage)) / 0.02
        let stretch = clampMag(vel * 0.010, 0.16)
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
            pose.y = stage.notchInset * 0.35 + (stage.notchInset + depth * 0.34 - stage.notchInset * 0.35) * envelope
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
            pose.x = -2
            pose.rotation = 8
            pose.scaleY = 0.90 + sin(t * 2 * .pi * 0.6) * 0.03   // breathing
            pose.scaleX = 1.06 - sin(t * 2 * .pi * 0.6) * 0.03
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
        }

        // Petting always wins on the emote, and nudges the pet toward the hand.
        if stage.petting {
            pose.emote = .heart
            pose.x += clampMag(stage.cursorX * 0.08, 4)
        }
        return pose
    }

    /// The drop envelope alone — used to finite-difference vertical velocity
    /// for squash & stretch without duplicating the easing curves.
    private static func envelopeValue(activity: PetActivity, t: Double, stage: Stage) -> Double {
        let enter = easeOutBack(clamp01(t / 0.16))
        let exitT = stage.petting ? 0 : clamp01((t - 0.84) / 0.16)
        return enter * (1 - easeInCubic(exitT))
    }

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
