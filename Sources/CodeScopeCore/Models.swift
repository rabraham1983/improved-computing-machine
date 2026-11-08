import Foundation

// MARK: - Languages

public enum Language: String, CaseIterable, Codable, Sendable, Hashable {
    case swift, objectiveC, c, cpp, python, javascript, typescript, go, rust, java, kotlin, scala
    case csharp, ruby, php, shell, html, css, json, yaml, markdown, sql, toml, xml, dart, lua, perl, r
    case makefile, dockerfile, plaintext, other

    public var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .objectiveC: return "Objective-C"
        case .c: return "C"
        case .cpp: return "C++"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .go: return "Go"
        case .rust: return "Rust"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .scala: return "Scala"
        case .csharp: return "C#"
        case .ruby: return "Ruby"
        case .php: return "PHP"
        case .shell: return "Shell"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .sql: return "SQL"
        case .toml: return "TOML"
        case .xml: return "XML"
        case .dart: return "Dart"
        case .lua: return "Lua"
        case .perl: return "Perl"
        case .r: return "R"
        case .makefile: return "Makefile"
        case .dockerfile: return "Dockerfile"
        case .plaintext: return "Text"
        case .other: return "Other"
        }
    }

    /// Identifier used for fenced code blocks in prompts.
    public var fenceName: String {
        switch self {
        case .objectiveC: return "objc"
        case .cpp: return "cpp"
        case .csharp: return "csharp"
        case .shell: return "bash"
        case .plaintext, .other: return ""
        default: return rawValue
        }
    }

    /// True for languages that contain program logic (as opposed to data/markup/config).
    public var isCode: Bool {
        switch self {
        case .json, .yaml, .markdown, .toml, .xml, .plaintext, .other, .html, .css:
            return false
        default:
            return true
        }
    }

    public static func detect(fileName: String) -> Language {
        let lower = fileName.lowercased()
        switch lower {
        case "makefile", "gnumakefile": return .makefile
        case "dockerfile": return .dockerfile
        case "gemfile", "rakefile", "podfile", "fastfile", "brewfile": return .ruby
        case "cmakelists.txt": return .plaintext
        default: break
        }
        if lower.hasPrefix("dockerfile.") { return .dockerfile }
        guard let dot = lower.lastIndex(of: ".") else { return .other }
        let ext = String(lower[lower.index(after: dot)...])
        switch ext {
        case "swift": return .swift
        case "m", "mm": return .objectiveC
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx", "inl": return .cpp
        case "py", "pyi", "pyw": return .python
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "scala", "sc": return .scala
        case "cs": return .csharp
        case "rb", "rake", "gemspec": return .ruby
        case "php", "phtml": return .php
        case "sh", "bash", "zsh", "fish": return .shell
        case "html", "htm", "vue", "svelte": return .html
        case "css", "scss", "sass", "less": return .css
        case "json", "jsonc", "json5": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown", "mdx": return .markdown
        case "sql": return .sql
        case "toml": return .toml
        case "xml", "plist", "storyboard", "xib", "xcconfig", "entitlements", "pbxproj": return .xml
        case "dart": return .dart
        case "lua": return .lua
        case "pl", "pm": return .perl
        case "r": return .r
        case "txt", "cfg", "ini", "conf", "env", "properties", "gradle", "lock", "mk": return .plaintext
        default: return .other
        }
    }
}

// MARK: - Symbols

public enum SymbolKind: String, Codable, Sendable, Hashable, CaseIterable {
    case function, method, initializer
    case `class`, `struct`, `enum`, `protocol`, interface, trait, `extension`, module, namespace
    case type, variable, constant, macro

    public var displayName: String {
        switch self {
        case .initializer: return "init"
        default: return rawValue
        }
    }

    public var isTypeLike: Bool {
        switch self {
        case .class, .struct, .enum, .protocol, .interface, .trait, .extension, .module, .namespace, .type:
            return true
        default:
            return false
        }
    }
}

public struct CodeSymbol: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(line):\(kind.rawValue):\(name)" }
    public let name: String
    public let kind: SymbolKind
    /// 1-based line number.
    public let line: Int
    /// The (trimmed) source line the symbol was found on.
    public let signature: String
    /// Indentation depth in characters, useful for building outlines.
    public let indent: Int

    public init(name: String, kind: SymbolKind, line: Int, signature: String, indent: Int = 0) {
        self.name = name
        self.kind = kind
        self.line = line
        self.signature = signature
        self.indent = indent
    }
}

// MARK: - Metrics

public struct FileMetrics: Hashable, Codable, Sendable {
    public var totalLines: Int
    public var codeLines: Int
    public var commentLines: Int
    public var blankLines: Int
    /// A rough cyclomatic-complexity estimate: 1 + number of branch keywords/operators.
    public var complexity: Int

    public init(totalLines: Int = 0, codeLines: Int = 0, commentLines: Int = 0, blankLines: Int = 0, complexity: Int = 1) {
        self.totalLines = totalLines
        self.codeLines = codeLines
        self.commentLines = commentLines
        self.blankLines = blankLines
        self.complexity = complexity
    }
}

// MARK: - Files

public struct CodeFile: Identifiable, Hashable, Sendable {
    /// Path relative to the project root, using "/" separators.
    public let relativePath: String
    public let absolutePath: String
    public let language: Language
    public let byteSize: Int
    public let content: String
    public let symbols: [CodeSymbol]
    /// Raw import specifiers as written in the source (module names, relative paths, …).
    public let imports: [String]
    public let metrics: FileMetrics
    public let isManifest: Bool

    public var id: String { relativePath }

    public var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    public var directory: String {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "." : dir
    }

    public var lineCount: Int { metrics.totalLines }

    public init(relativePath: String,
                absolutePath: String,
                language: Language,
                byteSize: Int,
                content: String,
                symbols: [CodeSymbol],
                imports: [String],
                metrics: FileMetrics,
                isManifest: Bool) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.language = language
        self.byteSize = byteSize
        self.content = content
        self.symbols = symbols
        self.imports = imports
        self.metrics = metrics
        self.isManifest = isManifest
    }

    public static func == (lhs: CodeFile, rhs: CodeFile) -> Bool {
        lhs.relativePath == rhs.relativePath && lhs.byteSize == rhs.byteSize && lhs.content == rhs.content
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(relativePath)
    }
}

// MARK: - Dependencies

public struct DependencyEdge: Hashable, Codable, Sendable {
    public let from: String
    public let to: String
    public let via: String

    public init(from: String, to: String, via: String) {
        self.from = from
        self.to = to
        self.via = via
    }
}

public struct EntryPoint: Hashable, Codable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

// MARK: - Project index

public struct ProjectIndex: Sendable {
    public let rootPath: String
    public let name: String
    public let files: [CodeFile]
    public let edges: [DependencyEdge]
    /// External dependency name → number of importing files.
    public let externalDependencies: [String: Int]
    public let entryPoints: [EntryPoint]
    public let skippedFileCount: Int
    public let createdAt: Date

    private let filesByPath: [String: CodeFile]
    private let fanInCounts: [String: Int]
    private let fanOutCounts: [String: Int]

    public init(rootPath: String,
                name: String,
                files: [CodeFile],
                edges: [DependencyEdge],
                externalDependencies: [String: Int],
                entryPoints: [EntryPoint],
                skippedFileCount: Int,
                createdAt: Date = Date()) {
        self.rootPath = rootPath
        self.name = name
        self.files = files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        self.edges = edges
        self.externalDependencies = externalDependencies
        self.entryPoints = entryPoints
        self.skippedFileCount = skippedFileCount
        self.createdAt = createdAt

        var byPath: [String: CodeFile] = [:]
        for file in files {
            byPath[file.relativePath] = file
        }
        self.filesByPath = byPath

        var fanIn: [String: Int] = [:]
        var fanOut: [String: Int] = [:]
        for edge in edges {
            fanIn[edge.to, default: 0] += 1
            fanOut[edge.from, default: 0] += 1
        }
        self.fanInCounts = fanIn
        self.fanOutCounts = fanOut
    }

    public func file(at relativePath: String) -> CodeFile? {
        filesByPath[relativePath]
    }

    public func fanIn(of path: String) -> Int { fanInCounts[path] ?? 0 }
    public func fanOut(of path: String) -> Int { fanOutCounts[path] ?? 0 }

    public var totalLines: Int {
        files.reduce(0) { $0 + $1.metrics.totalLines }
    }

    public var codeFiles: [CodeFile] {
        files.filter { $0.language.isCode }
    }

    public var manifests: [CodeFile] {
        files.filter { $0.isManifest }
    }

    /// Lines of code per language, sorted descending.
    public var languageBreakdown: [(language: Language, lines: Int)] {
        var counts: [Language: Int] = [:]
        for file in files where file.language != .other {
            counts[file.language, default: 0] += file.metrics.totalLines
        }
        return counts.map { (language: $0.key, lines: $0.value) }.sorted { $0.lines > $1.lines }
    }

    public var totalSymbolCount: Int {
        files.reduce(0) { $0 + $1.symbols.count }
    }

    public func dependencies(of path: String) -> [DependencyEdge] {
        edges.filter { $0.from == path }
    }

    public func dependents(of path: String) -> [DependencyEdge] {
        edges.filter { $0.to == path }
    }
}
