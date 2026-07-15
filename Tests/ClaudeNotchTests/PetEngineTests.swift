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
                       [.stroll, .hangLeft, .hangRight, .spiderHang, .spiderHang,
                        .peek, .lookAround, .stroll, .peek, .stroll])
    }

    func testCuriousActivitySequenceIsStable() {
        XCTAssertEqual(picks(.curious, seed: 7),
                       [.peek, .peek, .spiderHang, .hangRight, .rope,
                        .hangRight, .peek, .hangLeft, .hangLeft, .lookAround])
    }

    func testSleepyMostlySleeps() {
        let seq = picks(.sleepy, seed: 99)
        XCTAssertEqual(seq, [.sleep, .peek, .sleep, .sleep, .sleep,
                             .sleep, .hangLeft, .hangLeft, .sleep, .peek])
        XCTAssertGreaterThanOrEqual(seq.filter { $0 == .sleep }.count, 5)
    }

    func testBusyMoodsKeepTheWorkCompany() {
        // This used to assert the opposite: that a busy mood always tucked the
        // pet away. That was the bug. A mascot that hides for the whole of a tool
        // run is a screensaver, so the busy moods now put it out to watch — while
        // `allowsAutonomy` still keeps it off any card the user is reading, which
        // is what "stay out of the way" actually has to mean.
        for mood in [PetMood.working, .thinking] {
            let seq = picks(mood, seed: 3)
            XCTAssertFalse(seq.contains(.tucked), "\(mood) must not hide the pet from the work")
            XCTAssertTrue(seq.contains(.watch), "\(mood) should mostly be spent watching")
        }
        XCTAssertEqual(Set(picks(.celebrating, seed: 3)), [.celebrate])
        XCTAssertEqual(Set(picks(.startled, seed: 3)), [.flinch])
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
        // Opacity is 1 at every instant now, including the frames where the pet
        // is parked behind the notch: it hides by being *behind the cutout*, not
        // by dissolving. Fading it made it ghost out in mid-air on the way home.
        assertPose(.peek, 0.0, x: 0, y: 9, rot: 0, sx: 1, sy: 1,
                   flipped: false, opacity: 1, emote: nil)
        assertPose(.peek, 0.5, x: 0, y: 65.5206, rot: 0, sx: 1, sy: 1,
                   flipped: false, opacity: 1, emote: .dots)
        assertPose(.peek, 1.0, x: 0, y: 9, rot: 0, sx: 1, sy: 1,
                   flipped: false, opacity: 1, emote: nil)
    }

    func testLookAroundSweepsBothWays() {
        assertPose(.lookAround, 0.25, x: 6.4936, y: 64.6104, rot: -4.1145,
                   sx: 1.0006, sy: 0.9991, flipped: false, opacity: 1, emote: nil)
        assertPose(.lookAround, 0.5, x: -10.4614, y: 63.0282, rot: 6.6574,
                   sx: 1, sy: 1, flipped: true, opacity: 1, emote: nil)
    }

    func testHangLeftClingsToTheLeftWall() {
        assertPose(.hangLeft, 0.5, x: -76.9986, y: 49.6392, rot: -22.1459,
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
        assertPose(.stroll, 0.25, x: -51.8422, y: 60.6224, rot: 4,
                   sx: 0.9703, sy: 1.0495, flipped: false, opacity: 1, emote: nil)
        assertPose(.stroll, 0.92, x: 61.8682, y: 54.9128, rot: 2.3511,
                   sx: 0.9824, sy: 1.0294, flipped: false, opacity: 1, emote: nil)
        // Never walks through the wall.
        for i in 0...100 {
            let p = PetEngine.pose(for: .stroll, progress: Double(i) / 100, stage: stage)
            XCTAssertLessThanOrEqual(abs(p.x), PetActivity.stroll.maxCentreOffset(halfWidth: stage.halfWidth))
        }
    }

    func testSleepBreathesAndSaysZzz() {
        assertPose(.sleep, 0.25, x: 2, y: 58.8534, rot: -5, sx: 1.0057, sy: 0.9743,
                   flipped: false, opacity: 1, emote: .zzz)
    }

    func testSleepingPetLeansGentlyEnoughToSeeItsFace() {
        // The notch sits above eye level, so the flatter the pet lies the less
        // of its face you can see. A gentle lean, not a face-plant.
        let r = PetEngine.pose(for: .sleep, progress: 0.5, stage: stage).rotation
        XCTAssertLessThan(r, 0)
        XCTAssertGreaterThan(r, -10)
    }

    // MARK: - Physics

    func testSpringOvershootsThenSettlesToRest() {
        // An under-damped spring passes its target, comes back, and rings down
        // to exactly 1 — that overshoot is what reads as weight.
        var peak = 0.0
        for i in 0...400 {
            let v = PetEngine.springStep(Double(i) / 40, omega: 7, zeta: 0.5).value
            peak = max(peak, v)
        }
        XCTAssertGreaterThan(peak, 1.05, "must overshoot the target")
        XCTAssertLessThan(peak, 1.4, "but not fly off")
        XCTAssertEqual(PetEngine.springStep(6, omega: 7, zeta: 0.5).value, 1, accuracy: 0.001)
    }

    func testSpringStartsAtRestWithZeroVelocity() {
        let s0 = PetEngine.springStep(0, omega: 7, zeta: 0.5)
        XCTAssertEqual(s0.value, 0)
        XCTAssertEqual(s0.velocity, 0)
        XCTAssertEqual(PetEngine.springStep(-1, omega: 7, zeta: 0.5).value, 0)
    }

    func testSpringVelocityMatchesTheCurve() {
        // Diving out: velocity positive early (heading down). The analytic
        // velocity the squash reads must match a finite difference of position.
        func vAt(_ t: Double) -> Double { PetEngine.springStep(t, omega: 7, zeta: 0.5).velocity }
        func numeric(_ t: Double) -> Double {
            let h = 1e-5
            return (PetEngine.springStep(t + h, omega: 7, zeta: 0.5).value
                  - PetEngine.springStep(t - h, omega: 7, zeta: 0.5).value) / (2 * h)
        }
        XCTAssertGreaterThan(vAt(0.05), 0)
        for t in stride(from: 0.02, to: 1.0, by: 0.05) {
            XCTAssertEqual(vAt(t), numeric(t), accuracy: 0.02, "at t=\(t)")
        }
    }

    func testCriticallyDampedSpringNeverOvershoots() {
        for i in 0...200 {
            let v = PetEngine.springStep(Double(i) / 40, omega: 7, zeta: 1.0).value
            XCTAssertLessThanOrEqual(v, 1.0001)
        }
    }

    func testCelebrateHopsThreeTimes() {
        assertPose(.celebrate, 0.5, x: 0, y: 60.999, rot: 0, sx: 0.88, sy: 1.072,
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
        assertPose(.boop, 0.5, x: 0, y: 63.8379, rot: -0.2014, sx: 0.9927, sy: 1.0089,
                   flipped: false, opacity: 1, emote: .sparkle)
    }

    func testSpinIsEarnedNotScheduled() {
        for mood in PetMood.allCases {
            XCTAssertFalse(PetEngine.weights(for: mood).map(\.0).contains(.spin),
                           "\(mood) must never schedule the backflip — it's a reward for booping")
        }
    }

    // MARK: - Rope

    func testRopeHangsBelowTheLipAndSwingsBothWays() {
        // The rope pet is not skipped by the lip check (it's not a corner-hang),
        // so through the hold phase its head must stay clear of the notch.
        for i in 30...75 {
            let p = PetEngine.pose(for: .rope, progress: Double(i) / 100, stage: stage)
            XCTAssertGreaterThanOrEqual(p.y - PetActivity.rope.spriteSize / 2, stage.notchInset,
                                        "the rope pet's head hit the notch at t=\(Double(i) / 100)")
        }
        // A pendulum: it passes through centre to both sides.
        let xs = (0...100).map { PetEngine.pose(for: .rope, progress: Double($0) / 100, stage: stage).x }
        XCTAssertTrue(xs.contains { $0 > 3 }, "must swing right")
        XCTAssertTrue(xs.contains { $0 < -3 }, "must swing left")
    }

    func testRopeBodyTiltsTheWayItSwings() {
        // Rotation and horizontal offset share a sign — the body leans into the
        // swing rather than staying bolt upright. Checked away from the bottom of
        // the arc: the body trails the rope (see `ropeBobLag`), so within a few
        // points of dead centre it is still tilted the way it came from, which is
        // exactly what a weight on a line does.
        for i in 20...80 {
            let p = PetEngine.pose(for: .rope, progress: Double(i) / 100, stage: stage)
            if abs(p.x) > 4 {
                XCTAssertEqual(p.x > 0, p.rotation > 0, "tilt must follow the swing at t=\(Double(i) / 100)")
            }
        }
    }

    // MARK: - Rope physics

    private var ropeRest: Double { PetEngine.ropeRestRadius(.rope) }
    private var ropeHidden: Double { PetEngine.hiddenCentreY(for: .rope, notchInset: stage.notchInset) }

    private func rope(_ seconds: Double) -> PetEngine.RopeState {
        PetEngine.ropeState(seconds: seconds, anchor: stage.notchInset,
                            restRadius: ropeRest, dropStart: ropeHidden)
    }

    func testRopeFallsFreelyUntilTheRopeIsTaut() {
        // Before the catch the pet is in free fall, so the drop must go as t²:
        // doubling the time quadruples the distance fallen.
        let a = rope(0.08), b = rope(0.16)
        XCTAssertFalse(a.taut)
        XCTAssertFalse(b.taut)
        let fallA = a.y - ropeHidden, fallB = b.y - ropeHidden
        XCTAssertEqual(fallB / fallA, 4, accuracy: 0.01)
        // And the rope is still slack: the pet has not reached the end of it.
        XCTAssertLessThan(b.radius, ropeRest)
    }

    func testRopeCatchesAndNeverOverstretches() {
        // The catch happens once, and the rope's stretch is bounded by its
        // elasticity no matter how hard the fall hits the end of it.
        var caught = false
        for i in 0...500 {
            let s = rope(Double(i) / 100)
            if s.taut { caught = true }
            XCTAssertLessThanOrEqual(s.radius, ropeRest + PetEngine.ropeMaxStretch + 0.001,
                                     "rope stretched past its limit at \(Double(i) / 100)s")
        }
        XCTAssertTrue(caught, "the rope must go taut inside the act")
        // Right after the catch it is stretched, not compressed: the weight is
        // still moving down and the rope is taking it.
        XCTAssertGreaterThan(rope(0.4).radius, ropeRest)
    }

    func testRopeSwingsAtItsPendulumPeriod() {
        // The signature of a real pendulum: the period is set by the length and
        // gravity, not by an animation curve. T = 2π sqrt(L/g).
        let expected = 2 * Double.pi * (ropeRest / PetEngine.ropeGravity).squareRoot()
        // Measure it: time between two zero-crossings of the same direction.
        var crossings: [Double] = []
        var previous = rope(0.5).angle
        for i in 51...500 {
            let s = Double(i) / 100
            let angle = rope(s).angle
            if previous < 0, angle >= 0 { crossings.append(s) }
            previous = angle
        }
        XCTAssertGreaterThanOrEqual(crossings.count, 2, "must swing back and forth more than once")
        let measured = crossings[1] - crossings[0]
        XCTAssertEqual(measured, expected, accuracy: 0.08,
                       "swing period must match sqrt(L/g), got \(measured) vs \(expected)")
    }

    func testRopeSwingIsBornOfTheFallNotOfNothing() {
        // The pet only swings because it was still moving sideways when the rope
        // stopped it falling. Kill the sideways kick and there is nothing to swing.
        XCTAssertGreaterThan(PetEngine.ropeKickX, 0)
        let peak = (0...500).map { abs(rope(Double($0) / 100).angle) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "the catch must convert the fall into a real swing")
        XCTAssertLessThan(peak, 0.6, "and not into a windmill")
    }

    func testRopeBodyTrailsTheRope() {
        // The pet is a weight on a line, not a bead threaded onto it: mid-swing,
        // where the rope is turning fastest, the body lags behind its angle.
        let fast = (100...300).map { rope(Double($0) / 100) }
            .max(by: { abs($0.angleRate) < abs($1.angleRate) })!
        let lagged = fast.angle - PetEngine.ropeBobLag * fast.angleRate
        XCTAssertNotEqual(lagged, fast.angle, accuracy: 0.01)
        XCTAssertLessThan(abs(lagged), abs(fast.angle) + 0.2)
    }

    func testRopeSwingLosesAmplitudeOverTime() {
        // A real pendulum bleeds energy: the late swing is gentler than the early.
        func maxAngle(_ lo: Double, _ hi: Double) -> Double {
            stride(from: lo, to: hi, by: 0.005)
                .map { abs(PetEngine.pose(for: .rope, progress: $0, stage: stage).rotation) }
                .max() ?? 0
        }
        XCTAssertGreaterThan(maxAngle(0.15, 0.45), maxAngle(0.65, 0.95))
    }

    func testSpinTurnsTwiceInOneDirectionAndLandsSquashed() {
        var previous = 0.0
        for i in 0...200 {
            let r = PetEngine.pose(for: .spin, progress: Double(i) / 200, stage: stage).rotation
            XCTAssertLessThanOrEqual(r, previous + 1e-9, "the flip must never rewind")
            previous = r
        }
        XCTAssertEqual(previous, -720, accuracy: 0.0001)   // exactly two turns
        assertPose(.spin, 0.5, x: 0, y: 60.999, rot: -630, sx: 0.92, sy: 1.12,
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
        // "On its way back in" is now a fact about where the pet IS, not about
        // how transparent it is: it climbs back up behind the notch rather than
        // fading out. So the retreat is measured in y, which is also the only
        // thing that was ever really being asserted here.
        let hidden = PetEngine.hiddenCentreY(for: .peek, notchInset: stage.notchInset)
        XCTAssertLessThan(free.y, held.y)                 // free pet is heading home
        XCTAssertLessThan(free.y - hidden, (held.y - hidden) / 2,
                          "the free pet should be most of the way back into the notch")
        XCTAssertGreaterThan(held.y, stage.notchInset)    // held pet is still out
        XCTAssertEqual(held.opacity, 1, accuracy: 0.0001)
        XCTAssertEqual(free.opacity, 1, accuracy: 0.0001, "the pet hides by moving, not by dissolving")
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

/// The pet and the product. A mascot that hides exactly when there is something
/// to watch is a screensaver.
final class PetWatchesClaudeTests: XCTestCase {

    private let stage = PetEngine.Stage(notchInset: 32, halfWidth: 110)

    func testWorkingClaudeGetsAWatchingPet() {
        // The pet used to tuck itself away for the whole of a tool run.
        var rng = SeededRNG(seed: 11)
        let picks = (0..<20).map { _ in PetEngine.pickActivity(mood: .working, using: &rng) }
        XCTAssertFalse(picks.contains(.tucked), "the pet must not hide while Claude works")
        XCTAssertTrue(picks.contains(.watch))
    }

    func testThePetStaysWithTheWorkRatherThanFlashingUpOnce() {
        // The duty cycle keeps an idle pet from pestering you all afternoon. It
        // must not apply while Claude is busy, or the pet is on screen for a few
        // seconds of every minute of a long run.
        var rng = SeededRNG(seed: 5)
        var onScreen = 0.0, total = 0.0
        for _ in 0..<200 {
            let activity = PetEngine.pickActivity(mood: .working, using: &rng)
            let duration = PetEngine.duration(of: activity, using: &rng)
            let gap = PetEngine.nextDelay(mood: .working, after: activity,
                                          lasting: duration, using: &rng)
            if activity != .tucked { onScreen += duration }
            total += duration + gap
        }
        XCTAssertGreaterThan(onScreen / total, 0.6,
                             "the pet should keep the work company, not visit it")
    }

    func testAnIdlePetStillEarnsItsSilence() {
        // The waiver is for busy moods only — a calm pet must still buy a long
        // quiet after every performance.
        var rng = SeededRNG(seed: 5)
        let gap = PetEngine.nextDelay(mood: .calm, after: .sleep, lasting: 12, using: &rng)
        XCTAssertGreaterThanOrEqual(gap, 12 * PetEngine.dutyCycle)
    }

    func testWatchStaysOnStage() {
        for i in 0...100 {
            let p = PetEngine.pose(for: .watch, progress: Double(i) / 100, stage: stage)
            let floor = stage.notchInset + PetActivity.watch.stageDrop - PetActivity.watch.spriteSize / 2
            XCTAssertLessThanOrEqual(p.y, floor + 0.001)
            XCTAssertLessThanOrEqual(abs(p.x), PetActivity.watch.maxCentreOffset(halfWidth: stage.halfWidth) + 0.001)
        }
    }
}

/// The pet reacts to things going wrong, not just to things going right.
final class PetFlinchTests: XCTestCase {

    private let stage = PetEngine.Stage(notchInset: 32, halfWidth: 110)

    func testAFailureOutranksACompletion() {
        // A turn that died did not finish. If both flags are somehow set, the
        // pet must not stand there celebrating a crash.
        var ctx = PetEngine.Context()
        ctx.justFinished = true
        ctx.justFailed = true
        XCTAssertEqual(PetEngine.mood(for: ctx), .startled)
    }

    func testStartledPetFlinches() {
        var rng = SeededRNG(seed: 2)
        XCTAssertEqual(PetEngine.pickActivity(mood: .startled, using: &rng), .flinch)
    }

    func testFlinchRecoilsHardThenSettles() {
        // A fright is a fast recoil and a slow recovery. The early motion must be
        // much bigger than the late motion, or it reads as a dance step.
        func peak(_ lo: Double, _ hi: Double) -> Double {
            Array(stride(from: lo, to: hi, by: 0.01))
                .map { abs(PetEngine.pose(for: .flinch, progress: $0, stage: stage).x) }
                .max() ?? 0
        }
        XCTAssertGreaterThan(peak(0.0, 0.3), peak(0.6, 1.0) * 2)
    }

    func testFlinchStartsAlarmedAndEndsWary() {
        let early = PetEngine.pose(for: .flinch, progress: 0.2, stage: stage)
        let late = PetEngine.pose(for: .flinch, progress: 0.9, stage: stage)
        XCTAssertEqual(early.emote, .bang)
        XCTAssertEqual(late.emote, .dots)
    }

    func testFlinchStaysOnStage() {
        // Checked across the hold phase: at the very start and end the pet is
        // still behind the notch, which is where it is supposed to be.
        for i in 20...80 {
            let p = PetEngine.pose(for: .flinch, progress: Double(i) / 100, stage: stage)
            let floor = stage.notchInset + PetActivity.flinch.stageDrop - PetActivity.flinch.spriteSize / 2
            XCTAssertLessThanOrEqual(p.y, floor + 0.001)
            XCTAssertGreaterThanOrEqual(p.y - PetActivity.flinch.spriteSize / 2, stage.notchInset - 0.001,
                                        "the recoil must not jump the pet up into the notch")
        }
    }
}

/// Spider-Pet: the same drop physics as the rope, but head-first and in the suit.
final class SpiderHangTests: XCTestCase {

    private let stage = PetEngine.Stage(notchInset: 32, halfWidth: 110)

    func testItSharesTheRopePhysics() {
        // Same anchor, same length: the swing is identical to the rope's, so the
        // horizontal path matches. Only the render (flip + costume) differs.
        for i in 0...100 {
            let t = Double(i) / 100
            let rope = PetEngine.pose(for: .rope, progress: t, stage: stage)
            let spider = PetEngine.pose(for: .spiderHang, progress: t, stage: stage)
            XCTAssertEqual(rope.x, spider.x, accuracy: 0.001, "same swing at t=\(t)")
        }
    }

    func testItHangsHeadDown() {
        // The flip is exactly 180° on top of the rope's own tilt.
        for i in 20...80 {
            let t = Double(i) / 100
            let rope = PetEngine.pose(for: .rope, progress: t, stage: stage)
            let spider = PetEngine.pose(for: .spiderHang, progress: t, stage: stage)
            XCTAssertEqual(spider.rotation - rope.rotation, 180, accuracy: 0.001)
        }
    }

    func testItStaysOnStage() {
        for i in 0...100 {
            let p = PetEngine.pose(for: .spiderHang, progress: Double(i) / 100, stage: stage)
            let floor = stage.notchInset + PetActivity.spiderHang.stageDrop - PetActivity.spiderHang.spriteSize / 2
            XCTAssertLessThanOrEqual(p.y, floor + 0.001)
            XCTAssertLessThanOrEqual(abs(p.x), PetActivity.spiderHang.maxCentreOffset(halfWidth: stage.halfWidth) + 0.001)
        }
    }

    func testBothLinesShareOnePhysicsFlag() {
        XCTAssertTrue(PetEngine.isHanging(.rope))
        XCTAssertTrue(PetEngine.isHanging(.spiderHang))
        XCTAssertFalse(PetEngine.isHanging(.stroll))
    }
}
