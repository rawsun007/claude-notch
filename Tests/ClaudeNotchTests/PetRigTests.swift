import XCTest
@testable import ClaudeNotch

/// Golden tests for the pet's limbs.
///
/// PetEngineTests pins where the pet *is*; this pins how it *moves*. A gait is
/// even harder to review in a diff than a trajectory — swap two entries in
/// `gaitPhase` and you get a pet that paces like a camel, with no compile error
/// and no visible change to any number a human would look at.
final class PetRigTests: XCTestCase {

    private func rig(_ activity: PetActivity, t: Double = 0.5, time: Double = 0) -> PetRig {
        PetRigging.rig(for: activity, progress: t, time: time)
    }

    // MARK: - Gait

    func testWalkUsesDiagonalPairs() {
        // Legs 0 (front-left) and 3 (back-right) move together; 1 and 2 answer.
        // A pet whose left legs move together is a pet that paces, not walks.
        for i in stride(from: 0.0, to: 0.42, by: 0.03) {
            let r = rig(.stroll, time: i)
            XCTAssertEqual(r.legLift[0], r.legLift[3], accuracy: 0.0001, "at t=\(i)")
            XCTAssertEqual(r.legLift[1], r.legLift[2], accuracy: 0.0001, "at t=\(i)")
            XCTAssertEqual(r.legSwing[0], r.legSwing[3], accuracy: 0.0001, "at t=\(i)")
            XCTAssertEqual(r.legSwing[1], r.legSwing[2], accuracy: 0.0001, "at t=\(i)")
        }
    }

    func testTheTwoDiagonalPairsAreOppositeEachOther() {
        // When one pair is at the top of its step, the other is planted.
        let quarter = rig(.stroll, time: 0.42 * 0.25)
        XCTAssertGreaterThan(quarter.legLift[0], 0.5)      // stepping
        XCTAssertEqual(quarter.legLift[1], 0, accuracy: 0.0001)   // planted
        let threeQuarter = rig(.stroll, time: 0.42 * 0.75)
        XCTAssertEqual(threeQuarter.legLift[0], 0, accuracy: 0.0001)
        XCTAssertGreaterThan(threeQuarter.legLift[1], 0.5)
    }

    func testAPlantedLegIsNeverLiftedAndAStepAlwaysGoesForward() {
        for i in stride(from: 0.0, to: 1.26, by: 0.01) {
            let r = rig(.stroll, time: i)
            for leg in 0..<4 {
                XCTAssertGreaterThanOrEqual(r.legLift[leg], 0, "legs never sink into the floor")
                // The foot is forward of centre exactly while it's off the ground.
                if r.legLift[leg] > 0.01 {
                    XCTAssertGreaterThan(r.legSwing[leg], -0.56)
                }
            }
        }
    }

    func testWalkCycleRepeats() {
        let a = rig(.stroll, time: 1.0)
        let b = rig(.stroll, time: 1.0 + 0.42)
        for i in 0..<4 {
            XCTAssertEqual(a.legLift[i], b.legLift[i], accuracy: 0.0001)
            XCTAssertEqual(a.legSwing[i], b.legSwing[i], accuracy: 0.0001)
        }
    }

    func testArmsCounterSwingWhileWalking() {
        for i in stride(from: 0.0, to: 0.42, by: 0.05) {
            let r = rig(.stroll, time: i)
            XCTAssertEqual(r.armLeftAngle, -r.armRightAngle, accuracy: 0.0001)
        }
    }

    func testGaitDoesNotReverseForAFacingChange() {
        // The renderer mirrors the whole sprite when the pet faces left. If the
        // rig reversed the gait too, the two would cancel and it would moonwalk.
        // Guarded by the rig having no facing input at all — this test exists to
        // fail loudly if someone adds one back.
        let a = PetRigging.rig(for: .stroll, progress: 0.5, time: 0.2)
        let b = PetRigging.rig(for: .stroll, progress: 0.5, time: 0.2, cursorX: -200)
        XCTAssertEqual(a.legSwing, b.legSwing)
    }

    // MARK: - Blinking

    func testBlinksAreQuickAndPeriodic() {
        XCTAssertEqual(PetRigging.blink(at: 0.0), 1, accuracy: 0.0001)   // start of a blink: still open
        XCTAssertLessThan(PetRigging.blink(at: 0.07), 0.05)              // mid-blink: shut
        XCTAssertEqual(PetRigging.blink(at: 0.14), 1, accuracy: 0.0001)  // open again
        XCTAssertEqual(PetRigging.blink(at: 1.7), 1, accuracy: 0.0001)   // long since open
        XCTAssertLessThan(PetRigging.blink(at: 3.4 + 0.07), 0.05)        // next period
    }

    func testBlinkTakesUpOnlyASliverOfTheTime() {
        // Array, not the lazy Stride: on Swift 6 `.count` on a Sequence is
        // ambiguous with `count(where:)`.
        let samples = Array(stride(from: 0.0, to: 34.0, by: 0.01))
        let shut = samples.filter { PetRigging.blink(at: $0) < 0.5 }.count
        XCTAssertLessThan(Double(shut) / Double(samples.count), 0.03, "the pet is not drowsy, it blinks")
    }

    func testEyesFollowTheCursorButOnlyALittle() {
        let right = PetRigging.rig(for: .peek, progress: 0.5, time: 1, cursorX: 200)
        let left = PetRigging.rig(for: .peek, progress: 0.5, time: 1, cursorX: -200)
        XCTAssertGreaterThan(right.eyeShift, 0)
        XCTAssertLessThan(left.eyeShift, 0)
        // The eye is one cell wide: any more than half a cell and it slides out
        // of the head.
        XCTAssertLessThanOrEqual(abs(right.eyeShift), 0.5)
    }

    // MARK: - Per-activity poses

    func testSleepingPetShutsItsEyesAndFoldsItsLegs() {
        let r = rig(.sleep)
        XCTAssertEqual(r.eyeOpen, PetRigging.sleepingEyes)
        for tuck in r.legTuck { XCTAssertGreaterThan(tuck, 1) }
    }

    /// The eyes are holes punched out of the body, so `eyeOpen = 0` doesn't
    /// draw a shut eye — it erases the face entirely, and the sleeping pet
    /// became a featureless slab. A shut eye must still be a visible sliver.
    func testASleepingPetStillHasAFace() {
        let r = rig(.sleep)
        XCTAssertGreaterThan(r.eyeOpen, 0.1, "you must be able to see it sleeping")
        XCTAssertLessThan(r.eyeOpen, 0.5, "but the lids are down")
    }

    func testSleepingPetNeverBlinksBecauseItsEyesAreAlreadyShut() {
        // `time` lands mid-blink; sleep must still win.
        XCTAssertEqual(PetRigging.rig(for: .sleep, progress: 0.5, time: 0.07).eyeOpen,
                       PetRigging.sleepingEyes)
    }

    // MARK: - Dance (task-complete card)

    func testDanceRunsAllFourBeats() {
        // Beat 1: bounce peak lifts the body, both arms pump up.
        let bounce = PetRigging.dance(progress: 0.075, time: 0)
        XCTAssertGreaterThan(bounce.offsetY, 0.1)
        XCTAssertGreaterThan(bounce.rig.armLeftAngle, 50)
        XCTAssertGreaterThan(bounce.rig.armRightAngle, 50)

        // Beat 2: shimmy peak pushes sideways and leans.
        let shimmy = PetRigging.dance(progress: 0.3625, time: 0)
        XCTAssertGreaterThan(abs(shimmy.offsetX), 0.1)
        XCTAssertNotEqual(shimmy.rotation, 0, accuracy: 0.001)

        // Beat 3: a full turn, arms tucked in.
        let spin = PetRigging.dance(progress: 0.79, time: 0)
        XCTAssertEqual(spin.rotation, 360, accuracy: 1)
        XCTAssertLessThan(spin.rig.armLeftAngle, 30)

        // Beat 4: the finish jump, arms flung wide.
        let finish = PetRigging.dance(progress: 0.9, time: 0)
        XCTAssertGreaterThan(finish.offsetY, 0.3)
        XCTAssertGreaterThan(finish.rig.armLeftAngle, 70)
    }

    func testDanceSpinOnlyTurnsForward() {
        // Within the spin beat the rotation must never rewind, or it reads as a
        // dropped frame. (The beat boundaries themselves reset — that's a new
        // move, not a rewind.)
        var previous = -1.0
        for i in 0...100 {
            let t = 0.55 + 0.249 * Double(i) / 100
            let r = PetRigging.dance(progress: t, time: 0).rotation
            XCTAssertGreaterThanOrEqual(r, previous - 0.001)
            previous = r
        }
    }

    func testDanceStartsCentredAndBlinks() {
        let start = PetRigging.dance(progress: 0, time: 0)
        XCTAssertEqual(start.offsetX, 0, accuracy: 0.001)
        // Eyes are driven by the wall clock, so a dancing pet still blinks.
        XCTAssertEqual(PetRigging.dance(progress: 0.5, time: 0.07).rig.eyeOpen,
                       PetRigging.blink(at: 0.07), accuracy: 0.0001)
    }

    func testHangingPetGripsWithBothArmsUpAndDanglesItsLegs() {
        let r = rig(.hangLeft, t: 0.3)
        XCTAssertGreaterThan(r.armLeftAngle, 30)    // positive = raised, both arms
        XCTAssertGreaterThan(r.armRightAngle, 30)
        for lift in r.legLift { XCTAssertLessThan(lift, 0) }   // stretched downward
    }

    /// A dangling leg must keep its hip inside the belly, or it detaches and
    /// floats below the body with daylight in between. Same for a swinging arm
    /// at its shoulder — that's what `armOverlap` and `legOverlap` are for.
    func testNoLimbEverLeavesTheBody() {
        for activity in PetActivity.allCases {
            for i in 0...40 {
                let r = rig(activity, t: Double(i) / 40, time: Double(i) * 0.03)
                for lift in r.legLift {
                    XCTAssertGreaterThanOrEqual(lift, -PetBody.maxDangle,
                                                "\(activity): a leg dangled its hip out of the belly")
                }
            }
        }
    }

    func testFlippingPetTucksItsLimbsInAtTheApex() {
        let apex = rig(.spin, t: 0.5)
        for tuck in apex.legTuck { XCTAssertGreaterThan(tuck, 1.5) }
        // And has them back out by the landing.
        let landing = rig(.spin, t: 1.0)
        for tuck in landing.legTuck { XCTAssertLessThan(tuck, 0.01) }
    }

    func testCelebratingPetSplaysItsLegsAtTheTopOfEachHop() {
        let apex = rig(.celebrate, t: 1.0 / 6.0)   // top of the first of three hops
        XCTAssertLessThan(apex.legSwing[0], -0.5)  // outer legs kick outward
        XCTAssertGreaterThan(apex.legSwing[3], 0.5)
        XCTAssertGreaterThan(apex.armLeftAngle, 50)   // both arms thrown up
        XCTAssertGreaterThan(apex.armRightAngle, 50)
    }

    func testArmAnglesAreMirrored() {
        // "Arms up" must not mean "left arm up, right arm down". Every activity
        // that raises both arms says so with two positive angles.
        for activity in [PetActivity.hangLeft, .hangRight, .celebrate, .spin, .flinch] {
            let r = rig(activity, t: 0.5)
            XCTAssertEqual(r.armLeftAngle.sign, r.armRightAngle.sign, "\(activity)")
        }
        // A startled pet throws both arms up, and keeps them up for the whole
        // fright — not one up and one down, which is a shrug.
        for i in 0...20 {
            let r = rig(.flinch, t: Double(i) / 20)
            XCTAssertGreaterThan(r.armLeftAngle, 20)
            XCTAssertGreaterThan(r.armRightAngle, 20)
        }
    }

    func testTuckedPetIsCompletelyStill() {
        let r = rig(.tucked, time: 12.3)
        XCTAssertEqual(r.legLift, [0, 0, 0, 0])
        XCTAssertEqual(r.legSwing, [0, 0, 0, 0])
        XCTAssertEqual(r.armLeftAngle, 0)
    }

    // MARK: - Body

    /// Anything hung off the pet (the Zzz, the heart, the sparkles) is placed
    /// relative to its body. Measuring from the sprite's box instead leaves it
    /// floating in the three empty rows above the pet's head.
    func testBodyLandmarksMeasureFromTheCreatureNotItsBox() {
        XCTAssertEqual(PetBody.bodyTop, 3)
        XCTAssertEqual(PetBody.bodyRight, 16)
        // Head top is above the sprite's centre, and well inside the box's top.
        XCTAssertLessThan(PetBody.headTopFraction, 0)
        XCTAssertGreaterThan(PetBody.headTopFraction, -0.5)
        XCTAssertEqual(PetBody.headTopFraction, 3.0 / 16 - 0.5, accuracy: 0.0001)
        // The arms reach the very edge of the box.
        XCTAssertEqual(PetBody.shoulderRightFraction, 0.5, accuracy: 0.0001)
    }

    func testTheBodyMatchesTheArtwork() {
        // Sanity on the grid the sprite is reconstructed from: if these drift,
        // the drawn pet stops being the pet in assets/claude-pet.png.
        XCTAssertEqual(PetBody.grid, 16)
        XCTAssertEqual(PetBody.legs.count, 4)
        XCTAssertEqual(PetBody.gaitPhase.count, 4)
        XCTAssertEqual(PetBody.eyeLeft.width, 1)
        XCTAssertEqual(PetBody.eyeLeft.height, 2)
        XCTAssertEqual(PetBody.armLeft.y, PetBody.armRight.y)

        // Limbs run INTO the torso and are drawn behind it, so no rotation or
        // swing can open a gap at the joint. The arm reaches `armOverlap` past
        // the torso's edge; the leg starts `legOverlap` above the belly's base.
        let torsoLeft = PetBody.torso[1].x
        let torsoRight = PetBody.torso[1].x + PetBody.torso[1].width
        XCTAssertEqual(PetBody.armLeft.x + PetBody.armLeft.width, torsoLeft + PetBody.armOverlap)
        XCTAssertEqual(PetBody.armRight.x, torsoRight - PetBody.armOverlap)
        // Each arm turns about the torso's edge, so its buried half stays within
        // `armOverlap` of the pivot and the torso is always big enough to cover it.
        XCTAssertEqual(PetBody.shoulderLeft.x, torsoLeft)
        XCTAssertEqual(PetBody.shoulderRight.x, torsoRight)
        XCTAssertLessThan(PetBody.armOverlap, PetBody.torso[1].height + PetBody.torso[0].height)

        let bellyBottom = PetBody.torso[2].y + PetBody.torso[2].height
        for leg in PetBody.legs {
            XCTAssertEqual(leg.y, bellyBottom - PetBody.legOverlap)
            XCTAssertGreaterThan(leg.y + leg.height, bellyBottom)   // still has a foot
        }
    }
}
