import XCTest
@testable import QuietVibeStatus

final class QuestionParserTests: XCTestCase {
    func testParsesAFullQuestionSet() {
        let input = HookFixtures.json([
            "questions": [
                [
                    "header": "Auth method",
                    "question": "Which auth should we use?",
                    "multiSelect": false,
                    "options": [
                        ["label": "OAuth", "description": "Delegate to the provider"],
                        ["label": "Sessions", "description": "Cookie-backed"],
                    ],
                ],
            ],
        ])

        let set = QuestionParser.parse(input)
        XCTAssertEqual(set?.items.count, 1)
        XCTAssertEqual(set?.items.first?.header, "Auth method")
        XCTAssertEqual(set?.items.first?.options.map(\.label), ["OAuth", "Sessions"])
        XCTAssertEqual(set?.items.first?.multiSelect, false)
    }

    func testMultiSelectAndMissingHeaderAreHandled() {
        let input = HookFixtures.json([
            "questions": [
                ["question": "Pick features", "multiSelect": true, "options": []],
            ],
        ])

        let set = QuestionParser.parse(input)
        XCTAssertEqual(set?.items.first?.multiSelect, true)
        XCTAssertEqual(set?.items.first?.header, "Question")
        XCTAssertEqual(set?.items.first?.options.count, 0)
    }

    /// Returning nil is what makes the adapter fall through to Claude Code's own prompt instead of
    /// showing an empty wizard the user cannot answer.
    func testUnusableInputReturnsNil() {
        XCTAssertNil(QuestionParser.parse(.null))
        XCTAssertNil(QuestionParser.parse(HookFixtures.json(["questions": []])))
        XCTAssertNil(QuestionParser.parse(HookFixtures.json(["questions": [["header": "No text"]]])))
    }

    func testOptionsMissingALabelAreDropped() {
        let input = HookFixtures.json([
            "questions": [
                [
                    "question": "Pick one",
                    "options": [
                        ["description": "no label here"],
                        ["label": "Real", "description": "keeps its place"],
                    ],
                ],
            ],
        ])

        XCTAssertEqual(QuestionParser.parse(input)?.items.first?.options.map(\.label), ["Real"])
    }
}
