import XCTest
@testable import ClaudeNotch

/// Putting a question away without answering it.
///
/// A plan with five questions of four options each is taller than the screen,
/// and there was no way to get it out of the way and come back. Minimizing
/// keeps the request in the queue, so the session is still waiting and the card
/// can return; it only stops being what the notch draws.
///
/// The trap this guards is that the visible card is no longer the head of the
/// queue. Anything still reaching for .first answers one question with another
/// question's answers.
@MainActor
final class QuestionMinimizeTests: XCTestCase {

    private func question(_ text: String, answered: @escaping ([[String]]?) -> Void = { _ in }) -> QuestionRequest {
        QuestionRequest(
            questions: [AskQuestion(header: "", text: text, multiSelect: false,
                                    options: [AskOption(label: "A", description: "")])],
            source: "Test", cwd: "/tmp", resolver: answered)
    }

    func testTheVisibleQuestionIsTheFirstOneNotPutAway() {
        let state = AppState()
        let a = question("first")
        let b = question("second")
        state.questionQueue = [a, b]

        XCTAssertEqual(state.visibleQuestion?.id, a.id)
        state.minimizeVisibleQuestion()
        XCTAssertEqual(state.visibleQuestion?.id, b.id, "the next one should come forward")
    }

    /// The bug this exists to prevent: with one card put away, answering the
    /// visible one must resolve THAT one.
    func testAnsweringResolvesTheVisibleQuestionNotTheHead() {
        let state = AppState()
        var answeredFirst = false
        var answeredSecond = false
        let a = question("first") { _ in answeredFirst = true }
        let b = question("second") { _ in answeredSecond = true }
        state.questionQueue = [a, b]

        state.minimizeVisibleQuestion()
        state.resolveCurrentQuestion([["A"]])

        XCTAssertFalse(answeredFirst, "the minimized question must not be answered")
        XCTAssertTrue(answeredSecond)
        XCTAssertEqual(state.questionQueue.count, 1)
        XCTAssertEqual(state.questionQueue.first?.id, a.id, "the minimized one is still waiting")
    }

    func testMinimizingKeepsTheRequestQueuedSoTheSessionStillWaits() {
        let state = AppState()
        let a = question("only")
        state.questionQueue = [a]

        state.minimizeVisibleQuestion()
        XCTAssertEqual(state.questionQueue.count, 1, "minimizing is not answering")
        XCTAssertNil(state.visibleQuestion)
        XCTAssertEqual(state.minimizedQuestionCount, 1)
    }

    func testRestoringBringsItBack() {
        let state = AppState()
        let a = question("only")
        state.questionQueue = [a]

        state.minimizeVisibleQuestion()
        state.restoreMinimizedQuestions()
        XCTAssertEqual(state.visibleQuestion?.id, a.id)
        XCTAssertEqual(state.minimizedQuestionCount, 0)
    }

    /// An id left behind after its request is gone would hide an unrelated
    /// question later. recompute prunes, so every removal path is covered.
    func testAnIdCannotOutliveItsRequest() {
        let state = AppState()
        let a = question("first")
        state.questionQueue = [a]
        state.minimizeVisibleQuestion()
        XCTAssertEqual(state.collapsedQuestionIDs.count, 1)

        state.questionQueue = []
        state.recompute()
        XCTAssertTrue(state.collapsedQuestionIDs.isEmpty)
    }

    /// The count is what the notch's indicator reads. It must describe what is
    /// hidden right now, not every id ever collapsed.
    func testTheCountOnlyCountsQuestionsStillQueued() {
        let state = AppState()
        let a = question("first")
        let b = question("second")
        state.questionQueue = [a, b]
        state.minimizeVisibleQuestion()
        state.minimizeVisibleQuestion()
        XCTAssertEqual(state.minimizedQuestionCount, 2)
        XCTAssertNil(state.visibleQuestion, "everything is put away")

        state.restoreMinimizedQuestions()
        XCTAssertEqual(state.minimizedQuestionCount, 0)
    }

    func testResolvingWithNothingVisibleDoesNothing() {
        let state = AppState()
        let a = question("only")
        state.questionQueue = [a]
        state.minimizeVisibleQuestion()

        state.resolveCurrentQuestion([["A"]])
        XCTAssertEqual(state.questionQueue.count, 1, "a put-away card is not answered by accident")
    }
}
