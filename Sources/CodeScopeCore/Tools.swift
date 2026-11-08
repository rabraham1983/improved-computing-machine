import Foundation

/// A client-side tool definition sent to Claude.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let strict: Bool

    public init(name: String, description: String, inputSchema: JSONValue, strict: Bool = false) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema
        ]
        if strict {
            object["strict"] = .bool(true)
        }
        return .object(object)
    }
}

public struct ToolResult: Sendable {
    public var content: String
    public var isError: Bool

    public init(_ content: String, isError: Bool = false) {
        self.content = content.isEmpty ? "(no output)" : content
        self.isError = isError
    }
}

/// The tools available to Claude while it studies or edits the project. One fixed set is used for
/// every mode so the request prefix (tools → system) stays identical and prompt caching works.
public enum CodebaseToolset {

    public static let readFile = "read_file"
    public static let searchCode = "search_code"
    public static let listDirectory = "list_directory"
    public static let listSymbols = "list_symbols"
    public static let proposeEdits = "propose_edits"

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: readFile,
            description: "Read a source file from the project by its path relative to the project root. Returns the exact file text (optionally a line range). Use this for files marked OUTLINE ONLY, or to re-read a file before proposing edits so your `find` strings are verbatim.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path relative to the project root, e.g. Sources/App/Main.swift"],
                    "start_line": ["type": "integer", "description": "Optional 1-based first line to return"],
                    "end_line": ["type": "integer", "description": "Optional 1-based last line to return (inclusive)"]
                ],
                "required": ["path"],
                "additionalProperties": false
            ]
        ),
        ToolDefinition(
            name: searchCode,
            description: "Search all indexed files with a case-insensitive regular expression (or plain text). Returns matching lines as `path:line: text`, at most max_results matches. Use it to find call sites, definitions, configuration keys, or string literals.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "Regular expression (ICU syntax) or literal text to search for"],
                    "path_prefix": ["type": "string", "description": "Optional: restrict the search to paths starting with this prefix"],
                    "max_results": ["type": "integer", "description": "Maximum matches to return (default 60, max 300)"]
                ],
                "required": ["pattern"],
                "additionalProperties": false
            ]
        ),
        ToolDefinition(
            name: listDirectory,
            description: "List the files and sub-directories directly inside a project directory (use \"\" or \".\" for the root), with sizes and line counts.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Directory path relative to the project root"]
                ],
                "required": ["path"],
                "additionalProperties": false
            ]
        ),
        ToolDefinition(
            name: listSymbols,
            description: "List the functions, types and other symbols detected in a file, with line numbers, plus its imports, the files it depends on and the files that depend on it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path relative to the project root"]
                ],
                "required": ["path"],
                "additionalProperties": false
            ]
        ),
        ToolDefinition(
            name: proposeEdits,
            description: """
            Record a set of concrete code changes for the user to review and apply. Call this once per coherent change set (you may call it several times). Each edit targets one file:
            - action "patch": `hunks` is a list of {find, replace} pairs. `find` must be copied VERBATIM from the current file (whitespace included) and must occur exactly once; include enough surrounding lines to make it unique. `content` must be "".
            - action "replace_file": `content` is the complete new file text; `hunks` must be [].
            - action "create": `content` is the complete text of a new file; `hunks` must be [].
            - action "delete": removes the file; `content` is "" and `hunks` is [].
            Keep edits minimal and behaviour-preserving unless the user asked for behaviour changes. Never leave placeholders such as "...".
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "One or two sentences describing this change set"],
                    "edits": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "File path relative to the project root"],
                                "action": ["type": "string", "enum": ["patch", "replace_file", "create", "delete"]],
                                "explanation": ["type": "string", "description": "Why this change helps, in one or two sentences"],
                                "content": ["type": "string", "description": "Full file content for replace_file/create; empty string otherwise"],
                                "hunks": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "find": ["type": "string"],
                                            "replace": ["type": "string"]
                                        ],
                                        "required": ["find", "replace"],
                                        "additionalProperties": false
                                    ]
                                ]
                            ],
                            "required": ["path", "action", "explanation", "content", "hunks"],
                            "additionalProperties": false
                        ]
                    ]
                ],
                "required": ["summary", "edits"],
                "additionalProperties": false
            ],
            strict: true
        )
    ]

    public static var json: [JSONValue] { definitions.map { $0.json } }
}

/// Executes the read-only tools against an in-memory `ProjectIndex`.
public struct CodebaseToolExecutor: Sendable {
    public let index: ProjectIndex
    public static let maxOutputCharacters = 120_000

    public init(index: ProjectIndex) {
        self.index = index
    }

    public func execute(_ call: ToolUseCall) -> ToolResult {
        switch call.name {
        case CodebaseToolset.readFile:
            return readFile(call.input)
        case CodebaseToolset.searchCode:
            return searchCode(call.input)
        case CodebaseToolset.listDirectory:
            return listDirectory(call.input)
        case CodebaseToolset.listSymbols:
            return listSymbols(call.input)
        default:
            return ToolResult("Unknown tool \(call.name)", isError: true)
        }
    }

    static func normalizePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func locate(_ raw: String) -> CodeFile? {
        let path = CodebaseToolExecutor.normalizePath(raw)
        if let file = index.file(at: path) { return file }
        // Tolerate paths given relative to a sub-directory or with the project name prefixed.
        let candidates = index.files.filter { $0.relativePath.hasSuffix("/" + path) || $0.relativePath == path }
        if candidates.count == 1 { return candidates[0] }
        if path.hasPrefix(index.name + "/") {
            return index.file(at: String(path.dropFirst(index.name.count + 1)))
        }
        return nil
    }

    func readFile(_ input: JSONValue) -> ToolResult {
        guard let raw = input["path"]?.stringValue else {
            return ToolResult("Missing required parameter `path`.", isError: true)
        }
        guard let file = locate(raw) else {
            let suggestions = suggestPaths(for: raw)
            return ToolResult("File not found: \(raw)." + (suggestions.isEmpty ? "" : " Did you mean: " + suggestions.joined(separator: ", ")), isError: true)
        }
        let lines = file.content.components(separatedBy: "\n")
        let start = max(1, input["start_line"]?.intValue ?? 1)
        let end = min(lines.count, input["end_line"]?.intValue ?? lines.count)
        guard start <= end else {
            return ToolResult("Invalid range \(start)-\(end); the file has \(lines.count) lines.", isError: true)
        }
        var body = lines[(start - 1)..<end].joined(separator: "\n")
        var truncatedNote = ""
        if body.count > CodebaseToolExecutor.maxOutputCharacters {
            body = String(body.prefix(CodebaseToolExecutor.maxOutputCharacters))
            truncatedNote = "\n\n[truncated — request a narrower line range]"
        }
        let header = "// \(file.relativePath) — lines \(start)-\(end) of \(lines.count) (\(file.language.displayName))\n"
        return ToolResult(header + body + truncatedNote)
    }

    func suggestPaths(for raw: String) -> [String] {
        let needle = (CodebaseToolExecutor.normalizePath(raw) as NSString).lastPathComponent.lowercased()
        guard !needle.isEmpty else { return [] }
        return index.files
            .filter { $0.fileName.lowercased().contains(needle) }
            .prefix(5)
            .map { $0.relativePath }
    }

    func searchCode(_ input: JSONValue) -> ToolResult {
        guard let pattern = input["pattern"]?.stringValue, !pattern.isEmpty else {
            return ToolResult("Missing required parameter `pattern`.", isError: true)
        }
        let prefix = CodebaseToolExecutor.normalizePath(input["path_prefix"]?.stringValue ?? "")
        let maxResults = min(300, max(1, input["max_results"]?.intValue ?? 60))

        let regex: NSRegularExpression
        if let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            regex = compiled
        } else {
            regex = Rx.make(NSRegularExpression.escapedPattern(for: pattern), options: [.caseInsensitive])
        }

        var results: [String] = []
        var total = 0
        for file in index.files where prefix.isEmpty || file.relativePath.hasPrefix(prefix) {
            let lines = file.content.components(separatedBy: "\n")
            for (offset, line) in lines.enumerated() {
                if Rx.firstMatch(regex, in: line) != nil {
                    total += 1
                    if results.count < maxResults {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        results.append("\(file.relativePath):\(offset + 1): \(trimmed.prefix(240))")
                    }
                }
            }
        }
        if results.isEmpty {
            return ToolResult("No matches for /\(pattern)/" + (prefix.isEmpty ? "" : " under \(prefix)") + ".")
        }
        var text = results.joined(separator: "\n")
        if total > results.count {
            text += "\n… \(total - results.count) more matches not shown (narrow the pattern or path_prefix)."
        }
        return ToolResult(text)
    }

    func listDirectory(_ input: JSONValue) -> ToolResult {
        var path = CodebaseToolExecutor.normalizePath(input["path"]?.stringValue ?? "")
        if path == "." { path = "" }
        var files: [CodeFile] = []
        var subdirectories = Set<String>()
        for file in index.files {
            let dir = file.directory == "." ? "" : file.directory
            if dir == path {
                files.append(file)
            } else if path.isEmpty || dir.hasPrefix(path + "/") {
                let remainder = path.isEmpty ? dir : String(dir.dropFirst(path.count + 1))
                if let first = remainder.split(separator: "/").first {
                    subdirectories.insert(String(first))
                }
            }
        }
        if files.isEmpty && subdirectories.isEmpty {
            return ToolResult("Directory not found or empty: \(path.isEmpty ? "." : path)", isError: true)
        }
        var lines: [String] = []
        for dir in subdirectories.sorted() {
            lines.append("\(dir)/")
        }
        for file in files.sorted(by: { $0.fileName < $1.fileName }) {
            lines.append("\(file.fileName)  (\(file.language.displayName), \(file.metrics.totalLines) lines, \(file.byteSize) bytes)")
        }
        return ToolResult(lines.joined(separator: "\n"))
    }

    func listSymbols(_ input: JSONValue) -> ToolResult {
        guard let raw = input["path"]?.stringValue, let file = locate(raw) else {
            return ToolResult("File not found: \(input["path"]?.stringValue ?? "")", isError: true)
        }
        var out = "## \(file.relativePath)\n"
        out += ContextBuilder.outline(for: file)
        let deps = index.dependencies(of: file.relativePath)
        if !deps.isEmpty {
            out += "\nDepends on: " + deps.map { "\($0.to) (via \($0.via))" }.joined(separator: ", ") + "\n"
        }
        let dependents = index.dependents(of: file.relativePath)
        if !dependents.isEmpty {
            out += "Depended on by: " + dependents.map { $0.from }.joined(separator: ", ") + "\n"
        }
        return ToolResult(out)
    }
}
