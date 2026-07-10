import XCTest
@testable import ClaudeNotch

/// Golden tests for Pet Mode.
///
/// The pet is the one part of the app whose whole value is *how it moves*, and
/// motion regressions are invisible in a diff: a sign flip or a retuned easing
/// constant compiles fine and ships a pet that twitches. So the behaviour
/// (which activity, for how long) and the body (pose at a given instant) are
/// both pinned here against recorded values.
///
/// When a change to `PetEngine` is deliberate, these numbers are *supposed* to
/// fail — re-record them, eyeball the running app, and commit both together.
final class PetEngineTests: XCTestCase {

    // MARK: - Mood

    func testMoodPrefersCelebrationOverEverything() {
        var ctx = PetEngine.Context(isWorking: true, justFinished: true)
        XCTAssertEqual(PetEngine.mood(for: ctx), .celebrating)
        ctx.justFinished = false
        XCTAssertEqual(PetEngine.mood(for: ctx), .working)
    }

    func testMoodFromQuietTime() {
        func mood(after seconds: Double) -> PetMood {
            PetEngine.mood(for: PetEngine.Context(secondsSinceActivity: seconds))
        }
        XCTAssertEqual(mood(after: 0), .curious)
        XCTAssertEqual(mood(after: 44), .curious)
        XCTAssertEqual(mood(after: 45), .calm)
        XCTAssertEqual(mood(after: PetEngine.sleepAfter - 1), .calm)
        XCTAssertEqual(mood(after: PetEngine.sleepAfter), .sleepy)
    }

    func testThinkingOnlyWhenNotWorking() {
        let both = PetEngine.Context(isWorking: true, isThinking: true)
        XCTAssertEqual(PetEngine.mood(for: both), .working)
        XCTAssertEqual(PetEngine.mood(for: PetEngine.Context(isThinking: true)), .thinking)
    }

    // MARK: - Autonomy gate

    func testAutonomyRequiresAGenuinelyRestingNotch() {
        XCTAssertTrue(PetEngine.Context().allowsAutonomy)
        XCTAssertFalse(PetEngine.Context(isIdleMode: false).allowsAutonomy)
        XCTAssertFalse(PetEngine.Context(isHovering: true).allowsAutonomy)
        XCTAssertFalse(PetEngine.Context(persistentDisplay: true).allowsAutonomy)
    }

    // MARK: - Activity choice (seeded, so exact)

    private func picks(_ mood: PetMood, seed: UInt64, count: Int = 10) -> [PetActivity] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in PetEngine.pickActivity(mood: mood, using: &rng) }
    }

    func testCalmActivitySequenceIsStable() {
        XCTAssertEqual(picks(.calm, seed: 42),
                       [.hangRight, .lookAround, .hangLeft, .stroll, .stroll,
                        .peek, .lookAround, .hangRight, .peek, .hangRight])
    }

    func testCuriousActivitySequenceIsStable() {
        XCTAssertEqual(picks(.curious, seed: 7),
                       [.peek, .peek, .hangRight, .hangRight, .stroll,
                        .hangRight, .peek, .hangLeft, .hangLeft, .lookAround])
    }

    func testSleepyMostlySleeps() {
        let seq = picks(.sleepy, seed: 99)
        XCTAssertEqual(seq, [.sleep, .peek, .sleep, .sleep, .sleep,
                             .sleep, .hangLeft, .hangLeft, .sleep, .peek])
        XCTAssertGreaterThanOrEqual(seq.filter { $0 == .sleep }.count, 5)
    }

    func testBusyMoodsNeverPerform() {
        for mood in [PetMood.working, .thinking] {
            XCTAssertEqual(Set(picks(mood, seed: 3)), [.tucked],
                           "\(mood) must not pull the pet out over an active session")
        }
        XCTAssertEqual(Set(picks(.celebrating, seed: 3)), [.celebrate])
    }

    func testNoMoodCanPickAnActivityItHasNoWeightFor() {
        for mood in PetMood.allCases {
            let allowed = Set(PetEngine.weights(for: mood).map(\.0))
            XCTAssertEqual(Set(picks(mood, seed: 1234, count: 60)).subtracting(allowed), [])
        }
    }

    // MARK: - Timing

    func testDurationsAreInRangeAndSeeded() {
        var rng = SeededRNG(seed: 5)
        XCTAssertEqual(PetEngine.duration(of: .peek, using: &rng), 2.5868, accuracy: 0.0001)
        XCTAssertEqual(PetEngine.duration(of: .lookAround, using: &rng), 3.9028, accuracy: 0.0001)
        XCTAssertEqual(PetEngine.duration(of: .hangLeft, using: &rng), 3.7723, accuracy: 0.0001)
        XCTAssertEqual(PetEngine.duration(of: .stroll, using: &rng), 4.6490, accuracy: 0.0001)
        XCTAssertEqual(PetEngine.duration(of: .sleep, using: &rng), 9.1278, accuracy: 0.0001)

        var fixed = SeededRNG(seed: 1)
        XCTAssertEqual(PetEngine.duration(of: .tucked, using: &fixed), 0)
        XCTAssertEqual(PetEngine.duration(of: .celebrate, using: &fixed), 2.4)
        XCTAssertEqual(PetEngine.duration(of: .boop, using: &fixed), 0.85)
    }

    /// The pet is ambient. It shipped visible about a quarter of every idle
    /// minute (a 14s nap could be followed by a 40s gap), which reads as the pet
    /// constantly coming back rather than as something you catch now and then.
    /// Every activity must buy a silence proportional to its own length.
    func testAnActivityBuysASilenceProportionalToItsLength() {
        var rng = SeededRNG(seed: 8)
        for mood in [PetMood.curious, .calm, .sleepy] {
            for activity in [PetActivity.peek, .stroll, .sleep, .lookAround] {
                let duration = PetEngine.duration(of: activity, using: &rng)
                let gap = PetEngine.nextDelay(mood: mood, after: activity,
                                              lasting: duration, using: &rng)
                XCTAssertGreaterThanOrEqual(gap, duration * PetEngine.dutyCycle - 0.001,
                                            "\(activity) in \(mood) is on screen too much of the time")
            }
        }
    }

    func testTheLongestNapStillLeavesTheNotchAloneForMinutes() {
        var rng = SeededRNG(seed: 2)
        // Worst case: the longest possible nap, in the mood with the shortest
        // delay range that can pick it.
        let gap = PetEngine.nextDelay(mood: .calm, after: .sleep, lasting: 14, using: &rng)
        XCTAssertGreaterThanOrEqual(gap, 14 * PetEngine.dutyCycle - 0.001)
        XCTAssertGreaterThan(gap, 120)
    }

    func testABoopDoesNotEarnSilenceBecauseTheUserAskedForIt() {
        var rng = SeededRNG(seed: 4)
        var plain = SeededRNG(seed: 4)
        XCTAssertEqual(PetEngine.nextDelay(mood: .curious, after: .boop, lasting: 0.85, using: &rng),
                       PetEngine.nextDelay(mood: .curious, using: &plain), accuracy: 0.0001)
    }

    func testSleepyPetPestersLeastCuriousPetPestersMost() {
        // Sample the same seed per mood so the comparison is about the range,
        // not about where in the stream the draw landed.
        func delay(_ mood: PetMood) -> Double {
            var rng = SeededRNG(seed: 11)
            return PetEngine.nextDelay(mood: mood, using: &rng)
        }
        XCTAssertLessThan(delay(.curious), delay(.calm))
        XCTAssertLessThan(delay(.calm), delay(.sleepy))
    }

    // MARK: - Pose

    private let stage = PetEngine.Stage(notchInset: 32, halfWidth: 100, cursorX: 0, petting: false)

    private func assertPose(_ activity: PetActivity, _ t: Double,
                            x: Double, y: Double, rot: Double, sx: Double, sy: Double,
                            flipped: Bool, opacity: Double, emote: PetEmote?,
                            file: StaticString = #filePath, line: UInt = #line) {
        let p = PetEngine.pose(for: activity, progress: t, stage: stage)
        XCTAssertEqual(p.x, x, accuracy: 0.0001, "x", file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 0.0001, "y", file: file, line: line)
        XCTAssertEqual(p.rotation, rot, accuracy: 0.0001, "rotation", file: file, line: line)
        XCTAssertEqual(p.scaleX, sx, accuracy: 0.0001, "scaleX", file: file, line: line)
        XCTAssertEqual(p.scaleY, sy, accuracy: 0.0001, "scaleY", file: file, line: line)
        XCTAssertEqual(p.flipped, flipped, "flipped", file: file, line: line)
        XCTAssertEqual(p.opacity, opacity, accuracy: 0.0001, "opacity", file: file, line: line)
        XCTAssertEqual(p.emote, emote, "emote", file: file, line: line)
    }

    func testPeekPoseGolden() {
        assertPose(.peek, 0.0, x: 0, y: 9, rot: 0, sx: 1, sy: 1,
                   flipped: false, opacity: 0, emote: nil)
        assertPose(.peek, 0.5, x: 0, y: 65.5217, rot: 0, sx: 1, sy: 1,
                   flipped: false, opacity: 1, emote: .dots)
        assertPose(.peek, 1.0, x: 0, y: 9, rot: 0, sx: 1.1120, sy: 0.84,
                   flipped: false, opacity: 0, emote: nil)
    }

    func testLookAroundSweepsBothWays() {
        assertPose(.lookAround, 0.25, x: 6.4656, y: 64.3708, rot: -4.1145,
                   sx: 1, sy: 1, flipped: false, opacity: 1, emote: nil)
        assertPose(.lookAround, 0.5, x: -10.4616, y: 63.0292, rot: 6.6574,
                   sx: 1, sy: 1, flipped: true, opacity: 1, emote: nil)
    }

    func testHangLeftClingsToTheLeftWall() {
        assertPose(.hangLeft, 0.5, x: -77, y: 49.64, rot: -22.1459,
                   sx: 1, sy: 1, flipped: true, opacity: 1, emote: nil)
        // Mirror image on the right, minus the swing phase.
        let l = PetEngine.pose(for: .hangLeft, progress: 0.5, stage: stage)
        let r = PetEngine.pose(for: .hangRight, progress: 0.5, stage: stage)
        XCTAssertEqual(l.x, -r.x, accuracy: 0.0001)
        XCTAssertEqual(l.y, r.y, accuracy: 0.0001)
        XCTAssertTrue(l.flipped)
        XCTAssertFalse(r.flipped)
    }

    func testStrollCrossesAndComesBack() {
        assertPose(.stroll, 0.25, x: -51.6188, y: 60.4, rot: 4,
                   sx: 0.97, sy: 1.05, flipped: false, opacity: 1, emote: nil)
        assertPose(.stroll, 0.92, x: 61.8682, y: 54.9128, rot: 2.3511,
                   sx: 0.9968, sy: 1.0077, flipped: false, opacity: 1, emote: nil)
        // Never walks through the wall.
        for i in 0...100 {
            let p = PetEngine.pose(for: .stroll, progress: Double(i) / 100, stage: stage)
            XCTAssertLessThanOrEqual(abs(p.x), PetActivity.stroll.maxCentreOffset(halfWidth: stage.halfWidth))
        }
    }

    func testSleepBreathesAndSaysZzz() {
        assertPose(.sleep, 0.25, x: 2, y: 58.6472, rot: -10, sx: 1.0557, sy: 0.8043,
                   flipped: false, opacity: 1, emote: .zzz)
    }

    func testSleepingPetIsForeshortenedLikeItIsLyingDown() {
        // Flat on its back, seen from in front and above: the height you'd see
        // standing is foreshortened away, and it spreads a little wider.
        let p = PetEngine.pose(for: .sleep, progress: 0.5, stage: stage)
        XCTAssertLessThan(p.scaleY, 0.85)
        XCTAssertGreaterThan(p.scaleX, 1.0)
        XCTAssertLessThan(p.rotation, 0)        // lying at an angle to you
        XCTAssertGreaterThan(p.rotation, -20)   // not tipped onto its head
    }

    func testCelebrateHopsThreeTimes() {
        assertPose(.celebrate, 0.5, x: 0, y: 61, rot: 0, sx: 0.88, sy: 1.072,
                   flipped: false, opacity: 1, emote: .sparkle)
        // Three peaks: the sprite is at its highest three times across the run.
        let ys = (0...300).map { PetEngine.pose(for: .celebrate, progress: Double($0) / 300, stage: stage).y }
        let peaks = (1..<ys.count - 1).filter { ys[$0] < ys[$0 - 1] && ys[$0] < ys[$0 + 1] }
        XCTAssertEqual(peaks.count, 3)
    }

    func testBoopSquashesOnContactThenSettles() {
        let hit = PetEngine.pose(for: .boop, progress: 0, stage: stage)
        XCTAssertLessThan(hit.scaleY, 0.8)       // squashed flat
        XCTAssertGreaterThan(hit.scaleX, 1.15)   // and wide
        XCTAssertEqual(hit.emote, .sparkle)
        assertPose(.boop, 0.5, x: 0, y: 63.8389, rot: -0.2014, sx: 0.9927, sy: 1.0089,
                   flipped: false, opacity: 1, emote: .sparkle)
    }

    func testSpinIsEarnedNotScheduled() {
        for mood in PetMood.allCases {
            XCTAssertFalse(PetEngine.weights(for: mood).map(\.0).contains(.spin),
                           "\(mood) must never schedule the backflip — it's a reward for booping")
        }
    }

    func testSpinTurnsTwiceInOneDirectionAndLandsSquashed() {
        var previous = 0.0
        for i in 0...200 {
            let r = PetEngine.pose(for: .spin, progress: Double(i) / 200, stage: stage).rotation
            XCTAssertLessThanOrEqual(r, previous + 1e-9, "the flip must never rewind")
            previous = r
        }
        XCTAssertEqual(previous, -720, accuracy: 0.0001)   // exactly two turns
        assertPose(.spin, 0.5, x: 0, y: 61, rot: -630, sx: 0.92, sy: 1.12,
                   flipped: false, opacity: 1, emote: .sparkle)
        let landing = PetEngine.pose(for: .spin, progress: 1.0, stage: stage)
        XCTAssertLessThan(landing.scaleY, 0.8)
        XCTAssertGreaterThan(landing.scaleX, 1.15)
    }

    func testEveryActivityHasAStageBigEnoughForItsSprite() {
        for activity in PetActivity.allCases where activity != .tucked {
            XCTAssertGreaterThan(activity.stageDrop, activity.spriteSize,
                                 "\(activity) would clip its own sprite")
            XCTAssertGreaterThan(activity.stageWidthPad, 0,
                                 "\(activity) has no room either side of the cutout")
        }
        XCTAssertEqual(PetActivity.tucked.stageDrop, 0)
        XCTAssertEqual(PetActivity.tucked.stageWidthPad, 0)
    }

    /// The physical notch covers everything above the lip, so a sprite whose
    /// head pokes up there is a sprite with its head cut off. Twice now: once
    /// because the rest height was a hand-tuned fraction of the stage, and once
    /// because it ignored that a celebrating pet hops 15pt off its rest.
    ///
    /// So this checks the whole hold phase, not just the rest pose. Entry and
    /// exit are exempt: the pet is behind the lip then on purpose, that's what
    /// "coming out of the notch" means.
    func testPetStaysBelowTheNotchLipForEveryFrameItIsOut() {
        for activity in PetActivity.allCases where activity != .tucked {
            // Paws grip the lip — hanging is meant to straddle it.
            if activity == .hangLeft || activity == .hangRight { continue }
            for i in 30...75 {
                let p = PetEngine.pose(for: activity, progress: Double(i) / 100, stage: stage)
                XCTAssertGreaterThanOrEqual(p.y - activity.spriteSize / 2, stage.notchInset,
                                            "\(activity) loses its head at t=\(Double(i) / 100)")
            }
        }
        for activity in PetActivity.allCases {
            let hidden = PetEngine.hiddenCentreY(for: activity, notchInset: stage.notchInset)
            XCTAssertLessThanOrEqual(hidden + activity.spriteSize / 2, stage.notchInset,
                                     "\(activity) peeks out while it's supposed to be hidden")
        }
    }

    func testUpwardTravelIsBuiltIntoTheRestingHeight() {
        // A pet that hops 15pt must rest at least 15pt lower than one that
        // doesn't, or the hop goes behind the notch.
        XCTAssertGreaterThan(PetActivity.celebrate.restCentreY(notchInset: 32),
                             PetActivity.peek.restCentreY(notchInset: 32) + 10)
        XCTAssertGreaterThanOrEqual(PetActivity.celebrate.headroom, 15)
        XCTAssertGreaterThanOrEqual(PetActivity.spin.headroom, 16)
    }

    func testNoActivityDrawsOutsideItsStage() {
        // The card clips to its own bounds, so a pose that leaves them doesn't
        // overflow — it loses whatever hung over the edge. The pet's feet below
        // the bottom, or half its body past a side wall, both look like a bug.
        // `tools/render-pet-demo.swift` is how these two were caught.
        for activity in PetActivity.allCases where activity != .tucked {
            let bottom = stage.notchInset + activity.stageDrop
            // The card is the notch cutout plus this activity's own width pad.
            let half = stage.halfWidth + activity.stageWidthPad / 2
            let sized = PetEngine.Stage(notchInset: stage.notchInset, halfWidth: half)
            for i in 0...100 {
                let p = PetEngine.pose(for: activity, progress: Double(i) / 100, stage: sized)
                XCTAssertLessThanOrEqual(p.y + activity.spriteSize / 2, bottom + 0.001,
                                         "\(activity) clips its feet at t=\(Double(i) / 100)")
                XCTAssertLessThanOrEqual(abs(p.x) + activity.spriteSize / 2, half + 0.001,
                                         "\(activity) clips through the wall at t=\(Double(i) / 100)")
            }
        }
    }

    func testEveryActivityIsReachableFromTheDemosMenu() {
        // The Demos > Pet submenu is built from `allCases`, so a new activity
        // shows up there for free — but only if it stays in the enum rather
        // than being special-cased somewhere. Pin the one thing the menu skips.
        let demoable = PetActivity.allCases.filter { $0 != .tucked }
        XCTAssertEqual(demoable.count, PetActivity.allCases.count - 1)
        XCTAssertFalse(demoable.contains(.tucked))
    }

    func testPivotsMatchWhatTheActivityIsStandingOn() {
        XCTAssertEqual(PetActivity.hangLeft.pivot, .paws)
        XCTAssertEqual(PetActivity.hangRight.pivot, .paws)
        XCTAssertEqual(PetActivity.spin.pivot, .centre)   // a flip pivots at the belly
        XCTAssertEqual(PetActivity.peek.pivot, .feet)
        XCTAssertEqual(PetActivity.stroll.pivot, .feet)
    }

    func testTuckedIsInvisibleAndBehindTheNotch() {
        let p = PetEngine.pose(for: .tucked, progress: 0.5, stage: stage)
        XCTAssertEqual(p.opacity, 0)
        XCTAssertLessThan(p.y, stage.notchInset)
    }

    // MARK: - Interaction

    func testPettingHoldsThePetDownAndSwapsInAHeart() {
        var petted = stage
        petted.petting = true
        // t = 0.98 would normally be deep into the retract.
        let free = PetEngine.pose(for: .peek, progress: 0.98, stage: stage)
        let held = PetEngine.pose(for: .peek, progress: 0.98, stage: petted)
        XCTAssertLessThan(free.opacity, 1)          // on its way back in
        XCTAssertEqual(held.opacity, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(held.y, free.y)        // still out where the cursor is
        XCTAssertEqual(held.emote, .heart)
    }

    func testPetLeansTowardTheCursorAndTurnsToFaceIt() {
        var right = stage; right.cursorX = 60
        var left = stage; left.cursorX = -60
        let r = PetEngine.pose(for: .peek, progress: 0.5, stage: right)
        let l = PetEngine.pose(for: .peek, progress: 0.5, stage: left)
        XCTAssertGreaterThan(r.x, 0)
        XCTAssertLessThan(l.x, 0)
        XCTAssertFalse(r.flipped)
        XCTAssertTrue(l.flipped)
        // The lean is bounded — the pet leans, it doesn't lunge.
        XCTAssertLessThanOrEqual(abs(r.x), 9.001)
    }
}
