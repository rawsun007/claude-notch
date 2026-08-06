import XCTest
@testable import ClaudeNotch

/// The question card's height is computed up front, and the layout stretches
/// the option list to fill it, so an over-estimate shows up as a band of dead
/// space above Cancel/Send rather than as a clipped card.
@MainActor
final class QuestionCardSizeTests: XCTestCase {

    private func request(_ q: AskQuestion) -> QuestionRequest {
        QuestionRequest(questions: [q], source: "ClaudeNotch", cwd: "/tmp", resolver: { _ in })
    }

    private func plainOptions() -> [AskOption] {
        [AskOption(label: "Claude Code", description: ""),
         AskOption(label: "Codex", description: "")]
    }

    func testUndescribedOptionsAreShorterThanDescribedOnes() {
        let plain = request(AskQuestion(header: "Open folder", text: "Which agent?",
                                        multiSelect: false, options: plainOptions()))
        let described = request(AskQuestion(
            header: "Open folder", text: "Which agent?", multiSelect: false,
            options: [AskOption(label: "Claude Code", description: "Anthropic's CLI, resumes the last session"),
                      AskOption(label: "Codex", description: "OpenAI's CLI, beta support")]))
        XCTAssertLessThan(NotchView.size(for: .question(plain)).height,
                          NotchView.size(for: .question(described)).height)
    }

    func testDroppingTheFreeTextRowShrinksTheCard() {
        let withCustom = request(AskQuestion(header: "Open folder", text: "Which agent?",
                                             multiSelect: false, options: plainOptions()))
        let withoutCustom = request(AskQuestion(header: "Open folder", text: "Which agent?",
                                                multiSelect: false, options: plainOptions(),
                                                allowsCustomAnswer: false))
        let tall = NotchView.size(for: .question(withCustom)).height
        let short = NotchView.size(for: .question(withoutCustom)).height
        XCTAssertEqual(tall - short, 44, accuracy: 0.5)
    }

    func testCustomAnswersAreAllowedByDefault() {
        let q = AskQuestion(header: "Approach", text: "Which one?", multiSelect: false,
                            options: plainOptions())
        XCTAssertTrue(q.allowsCustomAnswer)
    }
}
