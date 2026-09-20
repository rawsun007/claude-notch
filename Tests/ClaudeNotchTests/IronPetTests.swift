import XCTest
@testable import ClaudeNotch

/// The two Stark-universe guest appearances: the armour holding a hover, and
/// the man leaning out of the notch without it.
///
/// Both are almost entirely motion, and motion is the part of this app that
/// nothing else checks. These pin the handful of properties that make each one
/// read as what it is, because every one of them is a line of arithmetic that
/// would still compile if it were wrong.
final class IronPetTests: XCTestCase {

    private func stage() -> PetEngine.Stage {
        PetEngine.Stage(notchInset: 32, halfWidth: 200, cursorX: 0)
    }

    /// Samples the STEADY middle of the act, not the whole of it.
    ///
    /// Every activity enters by dropping out of the notch and leaves by
    /// retracting into it, and both are large vertical moves that have nothing
    /// to do with the hover. Measuring "does it hold position" across them
    /// would measure the entrance instead.
    private func poses(samples: Int = 60, from: Double = 0.3, to: Double = 0.7) -> [PetPose] {
        (0..<samples).map { i in
            let progress = from + (to - from) * Double(i) / Double(samples - 1)
            return PetEngine.pose(for: .ironHover, progress: progress, stage: stage())
        }
    }

    // MARK: - It is a guest appearance

    func testIronPetIsAGuestAppearanceWithADate() throws {
        let iron = try XCTUnwrap(PetActivity.ironHover.special)
        XCTAssertEqual(iron.name, "Iron-Pet")
        XCTAssertEqual(iron.addedOn, "2026-09-20")
        XCTAssertFalse(iron.reference.isEmpty)
    }

    // MARK: - Stark, out of the armour

    func testStarkPetIsAGuestAppearanceWithADate() throws {
        let stark = try XCTUnwrap(PetActivity.starkCameo.special)
        XCTAssertEqual(stark.name, "Stark-Pet")
        XCTAssertEqual(stark.addedOn, "2026-09-20")
        XCTAssertFalse(stark.reference.isEmpty)
    }

    func testStarkWearsTheManNotTheArmour() {
        XCTAssertEqual(PetCostume.forActivity(.starkCameo), .stark)
    }

    /// No chest light and nothing firing. Out of the armour he is a man in a
    /// jumper, and a glow in the middle of that has nothing to explain it.
    func testStarkHasNoReactorAndNoRepulsors() {
        XCTAssertFalse(PetCostume.stark.hasReactor)
        XCTAssertTrue(PetCostume.iron.hasReactor, "the armour keeps it")
        for i in 0..<20 {
            let pose = PetEngine.pose(for: .starkCameo, progress: Double(i) / 20, stage: stage())
            XCTAssertEqual(pose.thrust, 0, accuracy: 0.0001, "he is not wearing boots that do that")
        }
    }

    /// The eyes stay the pet's own dark dots. The whole reason this costume
    /// works where the helmet struggled is that the head slab is already a
    /// face; replacing the eyes with slits would throw that away.
    func testStarkKeepsOrdinaryEyes() {
        XCTAssertEqual(PetCostume.stark.eyeColour, PetCostume.darkEye)
        XCTAssertEqual(PetCostume.iron.eyeColour, PetCostume.ironGlow)
    }

    /// Feet on the lip, not hovering. If this ever became a hanging activity
    /// the renderer would draw a rope out of the notch and attach him to it.
    func testStarkIsNotHangingOrHovering() {
        XCTAssertFalse(PetEngine.isHanging(.starkCameo))
        XCTAssertEqual(PetActivity.starkCameo.ropeLength, 0)
    }

    /// The man slouches where the armour poses: the two arms must not sit at
    /// the same angle.
    func testStarkArmsHangUnevenly() {
        var sawDifference = false
        for i in 0..<30 {
            let rig = PetRigging.rig(for: .starkCameo, progress: Double(i) / 30,
                                     time: Double(i) * 0.06, cursorX: 0)
            if abs(rig.armLeftAngle - rig.armRightAngle) > 1 { sawDifference = true }
        }
        XCTAssertTrue(sawDifference)
    }

    // MARK: - Armour

    func testItWearsTheArmour() {
        XCTAssertEqual(PetCostume.forActivity(.ironHover), .iron)
        XCTAssertEqual(PetCostume.forActivity(.spiderHang), .spider)
        XCTAssertEqual(PetCostume.forActivity(.peek), .plain)
    }

    /// The reactor is the detail that makes red and gold read as the suit, so
    /// only this costume draws one.
    func testOnlyTheArmourHasAReactor() {
        XCTAssertTrue(PetCostume.iron.hasReactor)
        XCTAssertFalse(PetCostume.spider.hasReactor)
        XCTAssertFalse(PetCostume.plain.hasReactor)
    }

    // MARK: - It hovers rather than hangs

    /// A hover is not a swing. It must not be caught by the rope physics, which
    /// would put it on a line and draw a rope out of the notch.
    func testItIsNotOnALine() {
        XCTAssertFalse(PetEngine.isHanging(.ironHover))
        XCTAssertEqual(PetActivity.ironHover.ropeLength, 0)
    }

    /// The suit holds a position: it should drift within a band, not travel.
    func testItStaysWithinASmallVerticalBand() {
        let ys = poses().map(\.y)
        let spread = (ys.max() ?? 0) - (ys.min() ?? 0)
        XCTAssertGreaterThan(spread, 2, "a hover that never moves is a hanging sprite")
        XCTAssertLessThan(spread, 40, "it is holding position, not flying somewhere")
    }

    /// Two waves of different periods, deliberately never in phase. One wave is
    /// a bob and a bob is a buoy; the give-away is that a single sine returns to
    /// the same value every period, so sampling one period apart would match.
    /// Two waves beating against each other, not one.
    ///
    /// The window matters and was measured rather than guessed. Across 0.2 to
    /// 0.8 the real motion turns three times where a single slow sine of the
    /// same amplitude turns once, so the assertion separates the two. Over the
    /// narrower steady window both turn at most once and the test proves
    /// nothing, which is how the first version of it failed.
    func testTheMotionIsNotOneCleanWave() {
        let ys = poses(samples: 120, from: 0.2, to: 0.8).map(\.y)
        var turns = 0
        for i in 1..<(ys.count - 1) {
            let rising = ys[i] > ys[i - 1]
            let thenFalling = ys[i] > ys[i + 1]
            if rising == thenFalling { turns += 1 }
        }
        XCTAssertGreaterThan(turns, 1, "one wave would give a bob; this should wobble")
    }

    // MARK: - The lights

    /// The reactor is a power source, not a status light. It must never go out,
    /// or the suit reads as broken.
    func testTheReactorNeverGoesOut() {
        for pose in poses() {
            XCTAssertGreaterThan(pose.reactorGlow, 0.3, "the chest light should breathe, not blink")
            XCTAssertLessThanOrEqual(pose.reactorGlow, 1.0)
        }
    }

    /// Thrust stays within range and actually varies: a constant flare is a
    /// glow stick, and one that clips is a rendering bug waiting to happen.
    func testThrustVariesAndStaysInRange() {
        let thrusts = poses().map(\.thrust)
        for value in thrusts {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1.0001)
        }
        XCTAssertGreaterThan((thrusts.max() ?? 0) - (thrusts.min() ?? 0), 0.2,
                             "the flare should swell and ease, not sit at one level")
    }

    /// Everything else keeps its boots dark. Thrust is drawn under the feet, so
    /// a stray value would light up a pet that is standing on the notch.
    func testNothingElseFiresRepulsors() {
        for activity in PetActivity.allCases where activity != .ironHover {
            let pose = PetEngine.pose(for: activity, progress: 0.5, stage: stage())
            XCTAssertEqual(pose.thrust, 0, accuracy: 0.0001,
                           "\(activity.rawValue) should not be firing repulsors")
        }
    }

    /// A still render, the settings preview and the menu row, has no activity
    /// driving it, so the default has to be a lit suit rather than a dead one.
    func testAStillSuitIsLit() {
        XCTAssertEqual(PetPose().reactorGlow, 1)
        XCTAssertEqual(PetRig().reactorGlow, 1)
        XCTAssertEqual(PetRig().thrust, 0, "but not firing: it is standing still")
    }

    // MARK: - The flight pose

    /// Arms down and out, and NOT symmetrical: a hover is held by correcting,
    /// and two arms locked at the same angle read as a pose rather than as
    /// balance.
    func testTheArmsBalanceIndependently() {
        var sawDifference = false
        for i in 0..<40 {
            let rig = PetRigging.rig(for: .ironHover, progress: Double(i) / 40,
                                     time: Double(i) * 0.05, cursorX: 0)
            XCTAssertLessThan(rig.armLeftAngle, 0, "arms hang down and out in flight")
            XCTAssertLessThan(rig.armRightAngle, 0)
            if abs(rig.armLeftAngle - rig.armRightAngle) > 0.5 { sawDifference = true }
        }
        XCTAssertTrue(sawDifference, "the two arms should not move in lockstep")
    }
}
