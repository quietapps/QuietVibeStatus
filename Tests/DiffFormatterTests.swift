import XCTest
@testable import QuietVibeStatus

final class DiffFormatterTests: XCTestCase {
    func testChangedLinesAreMarked() {
        let lines = DiffFormatter.diff(old: "one\ntwo\nthree", new: "one\nTWO\nthree")
        XCTAssertEqual(lines?.filter { $0.kind == .removed }.map(\.text), ["two"])
        XCTAssertEqual(lines?.filter { $0.kind == .added }.map(\.text), ["TWO"])
    }

    func testUnchangedNeighboursAreKeptAsContext() {
        let lines = DiffFormatter.diff(old: "one\ntwo\nthree", new: "one\nTWO\nthree")
        XCTAssertEqual(lines?.filter { $0.kind == .context }.map(\.text), ["one", "three"])
    }

    /// A hunk that changes one line in the middle of a long file must not print the whole file.
    func testLongUnchangedRunsCollapse() {
        let old = (1 ... 40).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 20", with: "line twenty")

        let lines = DiffFormatter.diff(old: old, new: new)

        XCTAssertNotNil(lines)
        XCTAssertTrue(lines!.contains { $0.kind == .elision })
        XCTAssertLessThan(lines!.count, 12)
        XCTAssertEqual(lines?.filter { $0.kind == .added }.map(\.text), ["line twenty"])
    }

    func testIdenticalTextProducesNoDiff() {
        XCTAssertEqual(DiffFormatter.diff(old: "same\ntext", new: "same\ntext")?.isEmpty, true)
    }

    func testWriteOfNewFileIsAllAdditions() {
        let lines = DiffFormatter.diff(old: "", new: "alpha\nbeta")
        XCTAssertEqual(lines?.filter { $0.kind == .added }.map(\.text), ["alpha", "beta"])
        XCTAssertTrue(lines?.contains { $0.kind == .removed } == false)
    }

    /// Aligning line by line is quadratic, so oversized payloads fall back to the summary instead.
    func testOversizedInputRefusesToDiff() {
        let huge = (1 ... 700).map(String.init).joined(separator: "\n")
        XCTAssertNil(DiffFormatter.diff(old: huge, new: huge + "\nmore"))
    }

    func testResultIsCappedAtTheLimit() {
        let old = (1 ... 200).map { "old \($0)" }.joined(separator: "\n")
        let new = (1 ... 200).map { "new \($0)" }.joined(separator: "\n")

        let lines = DiffFormatter.diff(old: old, new: new, limit: 20)

        XCTAssertEqual(lines?.count, 20)
    }

    func testSummaryDescribesACreation() {
        XCTAssertEqual(DiffFormatter.summary(old: nil, new: "a\nb\nc"), "Creates 3 lines")
        XCTAssertEqual(DiffFormatter.summary(old: "", new: "only"), "Creates 1 line")
    }

    func testSummaryDescribesAReplacement() {
        XCTAssertEqual(DiffFormatter.summary(old: "a\nb", new: "c"), "Replaces 2 lines with 1")
    }

    // MARK: - Preview construction

    func testEditPreviewReadsTheHunk() {
        let preview = EditPreview(
            tool: "Edit",
            input: HookFixtures.json([
                "file_path": "/tmp/project/main.swift",
                "old_string": "let a = 1",
                "new_string": "let a = 2",
            ])
        )

        XCTAssertEqual(preview?.path, "/tmp/project/main.swift")
        XCTAssertEqual(preview?.lines?.filter { $0.kind == .added }.map(\.text), ["let a = 2"])
        XCTAssertEqual(preview?.extraEdits, 0)
    }

    func testMultiEditPreviewCountsTheHunksItIsNotShowing() {
        let preview = EditPreview(
            tool: "MultiEdit",
            input: HookFixtures.json([
                "file_path": "/tmp/project/main.swift",
                "edits": [
                    ["old_string": "a", "new_string": "b"],
                    ["old_string": "c", "new_string": "d"],
                    ["old_string": "e", "new_string": "f"],
                ],
            ])
        )

        XCTAssertEqual(preview?.extraEdits, 2)
    }

    func testNonEditingToolsHaveNoPreview() {
        XCTAssertNil(EditPreview(tool: "Bash", input: HookFixtures.json(["command": "ls"])))
        XCTAssertNil(EditPreview(tool: "Read", input: HookFixtures.json(["file_path": "/tmp/a"])))
    }
}
