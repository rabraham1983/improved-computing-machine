import XCTest
@testable import CodeScopeCore

final class DiffAndEditTests: XCTestCase {

    func testDiffDetectsChanges() {
        let old = "a\nb\nc\nd\n"
        let new = "a\nB\nc\nd\ne\n"
        let lines = DiffEngine.diff(old: old, new: new, context: 1)
        let stats = DiffEngine.stats(lines)
        XCTAssertEqual(stats.added, 2)
        XCTAssertEqual(stats.removed, 1)
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text == "b" })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "B" })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text == "e" && $0.newLine == 5 })
    }

    func testDiffIdenticalIsEmpty() {
        XCTAssertTrue(DiffEngine.diff(old: "x\ny\n", new: "x\ny\n").isEmpty)
    }

    func testApplyExactHunk() throws {
        let original = "let a = 1\nlet b = 2\nlet c = 3\n"
        let result = try EditApplier.applyHunks([EditHunk(find: "let b = 2", replace: "let b = 20")], to: original, path: "x.swift")
        XCTAssertEqual(result, "let a = 1\nlet b = 20\nlet c = 3\n")
    }

    func testApplyFuzzyHunkIgnoresIndentation() throws {
        let original = "class A {\n    func f() {\n        return 1\n    }\n}\n"
        let hunk = EditHunk(find: "func f() {\n    return 1\n}", replace: "func f() {\n    return 2\n}")
        let result = try EditApplier.applyHunks([hunk], to: original, path: "x.swift")
        XCTAssertEqual(result, "class A {\n    func f() {\n        return 2\n    }\n}\n")
    }

    func testAmbiguousHunkThrows() {
        let original = "x = 1\nx = 1\n"
        XCTAssertThrowsError(try EditApplier.applyHunks([EditHunk(find: "x = 1", replace: "x = 2")], to: original, path: "a.py")) { error in
            guard case EditError.hunkAmbiguous(_, _, let count) = error else {
                return XCTFail("Expected ambiguity, got \(error)")
            }
            XCTAssertEqual(count, 2)
        }
    }

    func testMissingHunkThrows() {
        XCTAssertThrowsError(try EditApplier.applyHunks([EditHunk(find: "nope", replace: "")], to: "abc", path: "a"))
    }

    func testParseToolInput() {
        let input: JSONValue = [
            "summary": "Speed up",
            "edits": [
                ["path": "./src/a.swift", "action": "patch", "explanation": "x", "content": "", "hunks": [["find": "a", "replace": "b"]]],
                ["path": "new.swift", "action": "create", "explanation": "y", "content": "hello", "hunks": []],
                ["path": "bad.swift", "action": "unknown", "explanation": "", "content": "", "hunks": []]
            ]
        ]
        let parsed = EditApplier.parse(toolInput: input)
        XCTAssertEqual(parsed.summary, "Speed up")
        XCTAssertEqual(parsed.edits.count, 2)
        XCTAssertEqual(parsed.edits[0].path, "src/a.swift")
        XCTAssertEqual(parsed.edits[0].hunks.first?.replace, "b")
        XCTAssertEqual(parsed.edits[1].action, .create)
    }

    func testApplyAndRevertOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codescope-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("main.py")
        try "print('a')\n".write(to: file, atomically: true, encoding: .utf8)

        let edits = [
            ProposedEdit(path: "main.py", action: .patch, explanation: "", content: "", hunks: [EditHunk(find: "print('a')", replace: "print('b')")]),
            ProposedEdit(path: "lib/new.py", action: .create, explanation: "", content: "x = 1\n", hunks: [])
        ]
        let receipt = try EditApplier.apply(edits, root: root, summary: "test")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "print('b')\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/new.py").path))
        XCTAssertEqual(receipt.entries.count, 2)

        try EditApplier.revert(receipt)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "print('a')\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/new.py").path))
    }

    func testPathTraversalRejected() {
        let root = URL(fileURLWithPath: "/tmp/project")
        XCTAssertThrowsError(try EditApplier.resolve(path: "../etc/passwd", root: root))
        XCTAssertThrowsError(try EditApplier.resolve(path: "/etc/passwd/../../x", root: root))
        XCTAssertNoThrow(try EditApplier.resolve(path: "src/main.swift", root: root))
    }
}
