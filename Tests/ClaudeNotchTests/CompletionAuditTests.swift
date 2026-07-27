import XCTest
@testable import ClaudeNotch

/// The verifier's whole value is that you keep reading it. One false accusation
/// on a turn that was fine and you never trust it again, so most of these tests
/// are about staying quiet rather than about catching anything.
final class CompletionAuditSilenceTests: XCTestCase {

    private func verdict(_ claim: String, files: Int = 0, lines: Int = 0,
                         ranTests: Bool = false, failed: Bool? = nil) -> CompletionAudit.Verdict {
        CompletionAudit.audit(.init(claim: claim, filesEdited: files, linesChanged: lines,
                                    testCommandRan: ranTests, testFailed: failed))
    }

    func testAnAnsweredQuestionSaysNothing() {
        XCTAssertEqual(verdict("The retry lives in EventServer.swift, around line 340."), .silent)
    }

    func testAProposalIsNotAClaim() {
        // Suggesting an edit must never read as having made one.
        XCTAssertEqual(verdict("You could update the handler to bail out early."), .silent)
        XCTAssertEqual(verdict("We should fix the ordering here."), .silent)
        XCTAssertEqual(verdict("This would fix the race."), .silent)
    }

    func testAQuestionBackIsNotAClaim() {
        XCTAssertEqual(verdict("Do you want me to update the handler as well?"), .silent)
    }

    func testAReadOnlyTurnThatChangedNothingSaysNothing() {
        XCTAssertEqual(verdict("Here is what the function does, step by step."), .silent)
    }

    /// The reason `prose` exists. Pasted command output is not the assistant
    /// telling you the tests pass.
    func testPastedOutputInAFenceIsNotAClaim() {
        let claim = """
        Here is what I saw when you ran it:

        ```
        All tests passed, 42 examples, 0 failures
        ```

        That output is from the old build, so it does not tell us much.
        """
        XCTAssertEqual(verdict(claim), .silent)
    }

    func testInlineCodeIsNotAClaim() {
        XCTAssertEqual(verdict("Run `npm test` and check that all tests pass is printed."), .silent)
    }

    /// "Check that all tests pass" holds the same words as "all tests pass" and
    /// means the opposite: it is telling you to go and look.
    func testAnInstructionToVerifyIsNotAClaimThatItPassed() {
        XCTAssertFalse(CompletionAudit.claimsTestsPass("Check that all tests pass before merging."))
        XCTAssertFalse(CompletionAudit.claimsTestsPass("Make sure the tests pass first."))
        XCTAssertFalse(CompletionAudit.claimsTestsPass("Verify that the test suite passes."))
    }

    func testAConditionalIsNotAClaim() {
        XCTAssertFalse(CompletionAudit.claimsTestsPass("If the tests pass, we can ship it."))
        XCTAssertFalse(CompletionAudit.claimsCodeChange("Once I have updated it, the race goes away."))
    }

    /// The filtering must not swallow the real thing.
    func testAPlainAssertionStillCounts() {
        XCTAssertTrue(CompletionAudit.claimsTestsPass("All tests pass now."))
        XCTAssertTrue(CompletionAudit.claimsCodeChange("I've updated the handler."))
    }

    /// An instruction in one sentence must not mute a claim in another.
    func testAClaimSurvivesAlongsideAnInstruction() {
        let claim = "I've fixed the ordering. Make sure you rebuild before testing."
        XCTAssertTrue(CompletionAudit.claimsCodeChange(claim))
    }
}

/// The cases worth interrupting for.
final class CompletionAuditVerdictTests: XCTestCase {

    private func verdict(_ claim: String, files: Int = 0, lines: Int = 0,
                         ranTests: Bool = false, failed: Bool? = nil) -> CompletionAudit.Verdict {
        CompletionAudit.audit(.init(claim: claim, filesEdited: files, linesChanged: lines,
                                    testCommandRan: ranTests, testFailed: failed))
    }

    private func isContradicted(_ v: CompletionAudit.Verdict) -> Bool {
        if case .contradicted = v { return true }
        return false
    }
    private func isUnverified(_ v: CompletionAudit.Verdict) -> Bool {
        if case .unverified = v { return true }
        return false
    }
    private func isVerified(_ v: CompletionAudit.Verdict) -> Bool {
        if case .verified = v { return true }
        return false
    }

    /// The headline case: said it edited something, edited nothing.
    func testClaimingAChangeWithNothingTouchedIsContradicted() {
        XCTAssertTrue(isContradicted(verdict("I've updated the handler to bail out early.")))
        XCTAssertTrue(isContradicted(verdict("I fixed the race in the phase machine.")))
        XCTAssertTrue(isContradicted(verdict("I have refactored that into a helper.")))
    }

    /// Same claim, but it really did edit. Must not be contradicted.
    func testClaimingAChangeThatHappenedIsNotContradicted() {
        XCTAssertFalse(isContradicted(verdict("I've updated the handler.", files: 1, lines: 12)))
    }

    /// A tree change with no tool edit still counts as work done.
    func testWorkingTreeChangeAloneCountsAsEvidence() {
        XCTAssertFalse(isContradicted(verdict("I've updated the handler.", files: 0, lines: 30)))
    }

    func testSayingTestsPassWithoutRunningAnyIsUnverified() {
        XCTAssertTrue(isUnverified(verdict("All tests pass now.", files: 2, lines: 20)))
    }

    /// The worst case: it watched them fail and reported success anyway.
    func testReportingSuccessAfterAFailedTestRunIsContradicted() {
        XCTAssertTrue(isContradicted(
            verdict("I've fixed it and the tests pass.", files: 1, lines: 4,
                    ranTests: true, failed: true)))
    }

    func testAFailedRunWithNoClaimStaysSilent() {
        // Claude saying "the tests still fail" is honest. Do not contradict it.
        XCTAssertEqual(verdict("The tests still fail, here is why.",
                               ranTests: true, failed: true), .silent)
    }

    func testEditedAndTestedIsVerified() {
        let v = verdict("I've fixed the ordering.", files: 2, lines: 18,
                        ranTests: true, failed: false)
        XCTAssertTrue(isVerified(v))
        XCTAssertEqual(v.message, "2 files changed, tests passed.")
    }

    func testEditedWithoutTestsIsANoteNotAnAccusation() {
        let v = verdict("I've added the helper.", files: 1, lines: 6)
        XCTAssertTrue(isUnverified(v))
        XCTAssertEqual(v.message, "1 file changed, no tests run.")
    }

    func testSilentVerdictCarriesNoMessage() {
        XCTAssertNil(CompletionAudit.Verdict.silent.message)
    }
}

/// Whether a Bash command counts as having run the tests. Getting this wrong in
/// either direction breaks the verdicts above.
final class TestCommandDetectionTests: XCTestCase {

    func testCommonRunnersAreRecognised() {
        for cmd in ["npm test", "npm run test", "yarn test", "pnpm test",
                    "swift test", "pytest", "python -m pytest tests/",
                    "cargo test", "go test ./...", "make test", "bun test",
                    "vitest run", "jest --coverage", "dotnet test", "rspec"] {
            XCTAssertTrue(CompletionAudit.isTestCommand(cmd), "should detect: \(cmd)")
        }
    }

    func testARunnerAfterACdIsStillARunner() {
        XCTAssertTrue(CompletionAudit.isTestCommand("cd packages/api && npm test"))
    }

    func testBuildingIsNotTesting() {
        for cmd in ["swift build", "npm run build", "cargo build",
                    "go build ./...", "make", "tsc --noEmit"] {
            XCTAssertFalse(CompletionAudit.isTestCommand(cmd), "should not detect: \(cmd)")
        }
    }

    func testListingTestsIsNotRunningThem() {
        XCTAssertFalse(CompletionAudit.isTestCommand("pytest --collect-only"))
        XCTAssertFalse(CompletionAudit.isTestCommand("go test --help"))
    }

    /// A file whose name contains "test" is not a test run.
    func testEditingATestFileIsNotRunningTests() {
        XCTAssertFalse(CompletionAudit.isTestCommand("cat tests/test_api.py"))
        XCTAssertFalse(CompletionAudit.isTestCommand("rm -rf test-output"))
    }
}
