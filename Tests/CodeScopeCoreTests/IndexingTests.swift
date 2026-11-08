import XCTest
@testable import CodeScopeCore

final class IndexingTests: XCTestCase {

    func testGlobPatterns() {
        XCTAssertTrue(GlobPattern.match(pattern: "*.log", text: "debug.log"))
        XCTAssertFalse(GlobPattern.match(pattern: "*.log", text: "logs/debug.log"))
        XCTAssertTrue(GlobPattern.match(pattern: "**/*.log", text: "a/b/debug.log"))
        XCTAssertTrue(GlobPattern.match(pattern: "build/**", text: "build/x/y.o"))
        XCTAssertTrue(GlobPattern.match(pattern: "file?.txt", text: "file1.txt"))
        XCTAssertTrue(GlobPattern.match(pattern: "[abc].txt", text: "b.txt"))
        XCTAssertFalse(GlobPattern.match(pattern: "[!abc].txt", text: "b.txt"))

        let ignore = GlobPattern(line: "*.log")!
        XCTAssertTrue(ignore.matches(relativePath: "deep/dir/debug.log", isDirectory: false))
        let dirOnly = GlobPattern(line: "build/")!
        XCTAssertTrue(dirOnly.matches(relativePath: "build", isDirectory: true))
        XCTAssertFalse(dirOnly.matches(relativePath: "build", isDirectory: false))
        XCTAssertTrue(dirOnly.matches(relativePath: "build/out", isDirectory: true))
        let anchored = GlobPattern(line: "/secret.txt")!
        XCTAssertTrue(anchored.matches(relativePath: "secret.txt", isDirectory: false))
        XCTAssertFalse(anchored.matches(relativePath: "sub/secret.txt", isDirectory: false))
        XCTAssertNil(GlobPattern(line: "# comment"))
        XCTAssertNil(GlobPattern(line: "   "))
    }

    func testScanTemporaryProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codescope-scan-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src/utils"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try "import { helper } from './utils/helper';\nexport function main() { helper(); }\nmain();\n".write(to: root.appendingPathComponent("src/index.js"), atomically: true, encoding: .utf8)
        try "import lodash from 'lodash';\nexport function helper() {}\n".write(to: root.appendingPathComponent("src/utils/helper.js"), atomically: true, encoding: .utf8)
        try "module.exports = {};\n".write(to: root.appendingPathComponent("node_modules/dep/index.js"), atomically: true, encoding: .utf8)
        try "{\"name\": \"demo\"}\n".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "*.tmp\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "scratch".write(to: root.appendingPathComponent("notes.tmp"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3, 0, 0, 255]).write(to: root.appendingPathComponent("blob.bin"))

        let index = try ProjectScanner.scan(root: root)
        let paths = Set(index.files.map { $0.relativePath })
        XCTAssertEqual(paths, ["src/index.js", "src/utils/helper.js", "package.json", ".gitignore"])
        XCTAssertTrue(index.manifests.contains { $0.relativePath == "package.json" })
        XCTAssertEqual(index.edges, [DependencyEdge(from: "src/index.js", to: "src/utils/helper.js", via: "./utils/helper")])
        XCTAssertEqual(index.externalDependencies["lodash"], 1)
        XCTAssertEqual(index.fanIn(of: "src/utils/helper.js"), 1)
        XCTAssertTrue(index.entryPoints.contains { $0.path == "src/index.js" })
        XCTAssertTrue(index.entryPoints.contains { $0.path == "package.json" })
    }

    func testPythonRelativeImportResolution() {
        let a = makeFile("pkg/a.py", language: .python, imports: [".b", "pkg.c", "os"])
        let b = makeFile("pkg/b.py", language: .python, imports: [])
        let c = makeFile("pkg/c/__init__.py", language: .python, imports: [])
        let resolution = DependencyResolver.resolve(files: [a, b, c])
        let targets = Set(resolution.edges.map { $0.to })
        XCTAssertTrue(targets.contains("pkg/b.py"))
        XCTAssertTrue(targets.contains("pkg/c/__init__.py"))
        XCTAssertEqual(resolution.external["os"], 1)
    }

    func testDirectoryTreeAndContextBuilder() {
        let tree = ContextBuilder.directoryTree(paths: ["b/x.swift", "a.swift", "b/c/y.swift"])
        XCTAssertEqual(tree, "b/\n  c/\n    y.swift\n  x.swift\na.swift\n")

        let files = [
            makeFile("main.swift", language: .swift, imports: [], content: "@main struct App {}\n"),
            makeFile("big.swift", language: .swift, imports: [], content: String(repeating: "let x = 1\n", count: 4000))
        ]
        let index = ProjectIndex(rootPath: "/tmp/p", name: "p", files: files, edges: [], externalDependencies: [:], entryPoints: [EntryPoint(path: "main.swift", reason: "main")], skippedFileCount: 0)
        let context = ContextBuilder.build(index: index, tokenBudget: 4000)
        XCTAssertEqual(context.fullFiles, ["main.swift"])
        XCTAssertEqual(context.outlinedFiles, ["big.swift"])
        XCTAssertTrue(context.text.contains("OUTLINE ONLY"))
        XCTAssertTrue(context.text.contains("@main struct App {}"))
    }

    func testToolExecutor() {
        let files = [
            makeFile("src/a.swift", language: .swift, imports: ["Foundation"], content: "import Foundation\nfunc hello() {}\nfunc world() {}\n"),
            makeFile("src/b.swift", language: .swift, imports: [], content: "let value = hello()\n")
        ]
        let index = ProjectIndex(rootPath: "/tmp/p", name: "p", files: files, edges: [], externalDependencies: [:], entryPoints: [], skippedFileCount: 0)
        let executor = CodebaseToolExecutor(index: index)

        let read = executor.execute(ToolUseCall(id: "1", name: "read_file", input: ["path": "src/a.swift", "start_line": 2, "end_line": 2]))
        XCTAssertFalse(read.isError)
        XCTAssertTrue(read.content.contains("func hello() {}"))
        XCTAssertFalse(read.content.contains("func world"))

        let missing = executor.execute(ToolUseCall(id: "2", name: "read_file", input: ["path": "nope.swift"]))
        XCTAssertTrue(missing.isError)

        let search = executor.execute(ToolUseCall(id: "3", name: "search_code", input: ["pattern": "hello\\("]))
        XCTAssertTrue(search.content.contains("src/b.swift:1:"))

        let listing = executor.execute(ToolUseCall(id: "4", name: "list_directory", input: ["path": "src"]))
        XCTAssertTrue(listing.content.contains("a.swift"))

        let symbols = executor.execute(ToolUseCall(id: "5", name: "list_symbols", input: ["path": "a.swift"]))
        XCTAssertTrue(symbols.content.contains("function hello"))
    }

    // MARK: Helpers

    private func makeFile(_ path: String, language: Language, imports: [String], content: String = "") -> CodeFile {
        let extraction = SymbolExtractor.extract(content: content, language: language)
        return CodeFile(relativePath: path,
                        absolutePath: "/tmp/p/" + path,
                        language: language,
                        byteSize: content.utf8.count,
                        content: content,
                        symbols: extraction.symbols,
                        imports: imports.isEmpty ? extraction.imports : imports,
                        metrics: MetricsCalculator.compute(content: content, language: language),
                        isManifest: false)
    }
}
