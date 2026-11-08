import Foundation

/// Regex helpers shared by the indexing code.
enum Rx {
    static func make(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regular expression \(pattern): \(error)")
        }
    }

    static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    static func allMatches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range)
    }

    static func count(_ regex: NSRegularExpression, in text: String) -> Int {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }
}

/// A single line-anchored extraction rule.
struct LineRule {
    enum KindSource {
        /// Always this kind.
        case fixed(SymbolKind)
        /// Kind derived from the keyword captured in a group.
        case keyword(group: Int)
    }

    let regex: NSRegularExpression
    let nameGroup: Int
    let kind: KindSource
    /// When true, a match on an indented line becomes `.method` instead of `.function`.
    let methodWhenIndented: Bool
    /// When true, the rule only fires for lines with no leading whitespace.
    let topLevelOnly: Bool

    init(_ pattern: String,
         kind: SymbolKind,
         nameGroup: Int = 1,
         methodWhenIndented: Bool = false,
         topLevelOnly: Bool = false) {
        self.regex = Rx.make(pattern)
        self.nameGroup = nameGroup
        self.kind = .fixed(kind)
        self.methodWhenIndented = methodWhenIndented
        self.topLevelOnly = topLevelOnly
    }

    init(_ pattern: String, keywordGroup: Int, nameGroup: Int) {
        self.regex = Rx.make(pattern)
        self.nameGroup = nameGroup
        self.kind = .keyword(group: keywordGroup)
        self.methodWhenIndented = false
        self.topLevelOnly = false
    }

    static func kind(forKeyword keyword: String) -> SymbolKind {
        switch keyword.lowercased() {
        case "class", "actor", "@interface", "@implementation", "object", "record": return .class
        case "struct", "union": return .struct
        case "enum": return .enum
        case "protocol", "@protocol": return .protocol
        case "interface", "@interface_": return .interface
        case "trait": return .trait
        case "extension", "impl": return .extension
        case "module", "mod": return .module
        case "namespace": return .namespace
        default: return .type
        }
    }
}

/// Lightweight, regex-based symbol & import extraction for the languages CodeScope understands.
/// It is deliberately approximate: the goal is a navigable outline and a useful "repo map" for
/// Claude, not a compiler-grade AST.
public enum SymbolExtractor {

    public struct Extraction: Sendable {
        public var symbols: [CodeSymbol]
        public var imports: [String]
    }

    public static func extract(content: String, language: Language) -> Extraction {
        let lines = content.components(separatedBy: "\n")
        let rules = symbolRules(for: language)
        let importRules = importPatterns(for: language)

        var symbols: [CodeSymbol] = []
        var imports: [String] = []
        var seenImports = Set<String>()
        var inGoImportBlock = false

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = rawLine.count - rawLine.drop(while: { $0 == " " || $0 == "\t" }).count

            // Go import blocks: import ( "a" \n alias "b" \n )
            if language == .go {
                if goImportBlockStart.firstMatchExists(in: rawLine) {
                    inGoImportBlock = true
                    continue
                }
                if inGoImportBlock {
                    if trimmed.hasPrefix(")") {
                        inGoImportBlock = false
                    } else if let match = Rx.firstMatch(goImportBlockEntry, in: rawLine),
                              let module = Rx.group(1, of: match, in: rawLine) {
                        if seenImports.insert(module).inserted { imports.append(module) }
                    }
                    continue
                }
            }

            for importRegex in importRules {
                for match in Rx.allMatches(importRegex, in: rawLine) {
                    if let module = Rx.group(1, of: match, in: rawLine), !module.isEmpty {
                        if seenImports.insert(module).inserted { imports.append(module) }
                    }
                }
            }

            for rule in rules {
                if rule.topLevelOnly && indent > 0 { continue }
                guard let match = Rx.firstMatch(rule.regex, in: rawLine),
                      let name = Rx.group(rule.nameGroup, of: match, in: rawLine),
                      !name.isEmpty else { continue }

                var kind: SymbolKind
                switch rule.kind {
                case .fixed(let fixed):
                    kind = fixed
                case .keyword(let group):
                    kind = LineRule.kind(forKeyword: Rx.group(group, of: match, in: rawLine) ?? "")
                }
                if rule.methodWhenIndented && indent > 0 && kind == .function {
                    kind = .method
                }
                let signature = String(trimmed.prefix(160))
                symbols.append(CodeSymbol(name: name, kind: kind, line: lineNumber, signature: signature, indent: indent))
                break
            }
        }

        return Extraction(symbols: symbols, imports: imports)
    }

    // MARK: - Go import block helpers

    private static let goImportBlockStart = Rx.make(#"^\s*import\s*\($"#)
    private static let goImportBlockEntry = Rx.make(#"^\s*(?:[\w.]+\s+)?"([^"]+)""#)

    // MARK: - Rules per language

    private static let identifier = #"([A-Za-z_][A-Za-z0-9_]*)"#
    private static let jsIdentifier = #"([A-Za-z_$][A-Za-z0-9_$]*)"#
    private static let controlKeywords = #"(?!(?:if|else|for|while|switch|catch|return|do|try|new|typeof|await|throw|sizeof|case|with|yield|defer|select|match|loop)\b)"#

    static func symbolRules(for language: Language) -> [LineRule] {
        switch language {
        case .swift:
            return swiftRules
        case .python:
            return pythonRules
        case .javascript, .typescript:
            return javascriptRules
        case .go:
            return goRules
        case .rust:
            return rustRules
        case .java, .scala:
            return javaRules
        case .kotlin:
            return kotlinRules
        case .csharp:
            return csharpRules
        case .c, .cpp, .objectiveC:
            return cFamilyRules
        case .ruby:
            return rubyRules
        case .php:
            return phpRules
        case .shell:
            return shellRules
        case .dart:
            return dartRules
        case .lua:
            return luaRules
        case .sql:
            return sqlRules
        default:
            return []
        }
    }

    private static let modifiers = #"(?:[A-Za-z_@][A-Za-z0-9_@]*(?:\([^)]*\))?\s+)*"#

    private static let swiftRules: [LineRule] = [
        LineRule(#"^\s*"# + modifiers + #"func\s+"# + identifier, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*"# + modifiers + #"(init)\s*[?!]?\s*(?:<[^>]*>)?\s*\("#, kind: .initializer),
        LineRule(#"^\s*"# + modifiers + #"(class|struct|enum|protocol|extension|actor)\s+(?!func\b|var\b|let\b)"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*"# + modifiers + #"typealias\s+"# + identifier, kind: .type),
        LineRule(#"^"# + modifiers + #"(?:var|let)\s+"# + identifier, kind: .variable, topLevelOnly: true),
        LineRule(#"^\s*"# + modifiers + #"(?:var|let)\s+"# + identifier + #"\s*:[^=]*\{\s*$"#, kind: .variable),
    ]

    private static let pythonRules: [LineRule] = [
        LineRule(#"^\s*(?:async\s+)?def\s+"# + identifier, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*class\s+"# + identifier, kind: .class),
        LineRule(#"^([A-Z][A-Z0-9_]{2,})\s*(?::[^=]+)?=\s*"#, kind: .constant, topLevelOnly: true),
        LineRule(#"^"# + identifier + #"\s*(?::[^=]+)?=\s*(?!lambda)"#, kind: .variable, topLevelOnly: true),
    ]

    private static let javascriptRules: [LineRule] = [
        LineRule(#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*"# + jsIdentifier, kind: .function),
        LineRule(#"^\s*(?:export\s+)?(?:const|let|var)\s+"# + jsIdentifier + #"\s*(?::[^=]+)?=\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|[A-Za-z_$][\w$]*\s*=>)"#, kind: .function),
        LineRule(#"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+"# + jsIdentifier, kind: .class),
        LineRule(#"^\s*(?:export\s+)?(?:declare\s+)?interface\s+"# + jsIdentifier, kind: .interface),
        LineRule(#"^\s*(?:export\s+)?(?:declare\s+)?type\s+"# + jsIdentifier + #"\s*(?:<[^>]*>)?\s*="#, kind: .type),
        LineRule(#"^\s*(?:export\s+)?(?:declare\s+)?(?:const\s+)?enum\s+"# + jsIdentifier, kind: .enum),
        LineRule(#"^\s*(?:export\s+)?(?:declare\s+)?namespace\s+"# + jsIdentifier, kind: .namespace),
        LineRule(#"^\s+(?:(?:public|private|protected|static|async|readonly|override|abstract|get|set)\s+)*\*?\s*"# + controlKeywords + jsIdentifier + #"\s*(?:<[^>]*>)?\s*\([^)]*\)\s*(?::\s*[^{;=]+)?\{\s*\}?\s*$"#, kind: .method),
        LineRule(#"^(?:export\s+)?(?:const|let|var)\s+"# + jsIdentifier, kind: .variable, topLevelOnly: true),
    ]

    private static let goRules: [LineRule] = [
        LineRule(#"^func\s+\([^)]*\)\s+"# + identifier, kind: .method),
        LineRule(#"^func\s+"# + identifier, kind: .function),
        LineRule(#"^type\s+"# + identifier + #"\s+(struct|interface)\b"#, kind: .struct),
        LineRule(#"^type\s+"# + identifier + #"\s+"#, kind: .type),
        LineRule(#"^(?:var|const)\s+"# + identifier, kind: .variable, topLevelOnly: true),
        LineRule(#"^\s+"# + identifier + #"\s+(?:struct|interface)\s*\{"#, kind: .struct),
    ]

    private static let rustVisibility = #"(?:pub(?:\([^)]*\))?\s+)?"#

    private static let rustRules: [LineRule] = [
        LineRule(#"^\s*"# + rustVisibility + #"(?:const\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+"[^"]*"\s+)?fn\s+"# + identifier, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*"# + rustVisibility + #"(struct|enum|trait|union)\s+"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*(?:unsafe\s+)?impl(?:<[^>]*>)?\s+(?:[\w:<>, ]+\s+for\s+)?([\w:]+)"#, kind: .extension),
        LineRule(#"^\s*"# + rustVisibility + #"mod\s+"# + identifier, kind: .module),
        LineRule(#"^\s*"# + rustVisibility + #"type\s+"# + identifier, kind: .type),
        LineRule(#"^\s*"# + rustVisibility + #"(?:static|const)\s+(?:mut\s+)?"# + identifier, kind: .constant),
        LineRule(#"^\s*macro_rules!\s+"# + identifier, kind: .macro),
    ]

    private static let javaModifiers = #"(?:(?:public|private|protected|static|final|abstract|sealed|non-sealed|synchronized|native|default|strictfp|transient|volatile|override|open|case|implicit|lazy)\s+)*"#

    private static let javaRules: [LineRule] = [
        LineRule(#"^\s*"# + javaModifiers + #"(class|interface|enum|record|@interface|object|trait)\s+"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*"# + javaModifiers + #"def\s+"# + identifier, kind: .method),
        LineRule(#"^\s+"# + javaModifiers + #"(?:<[^>]+>\s+)?(?:[\w.<>\[\],?]+\s+)+"# + controlKeywords + identifier + #"\s*\([^;]*$"#, kind: .method),
    ]

    private static let kotlinModifiers = #"(?:(?:public|private|protected|internal|open|override|abstract|final|suspend|inline|operator|infix|external|tailrec|actual|expect|data|sealed|annotation|inner|enum|value|companion|const|lateinit)\s+)*"#

    private static let kotlinRules: [LineRule] = [
        LineRule(#"^\s*"# + kotlinModifiers + #"fun\s+(?:<[^>]+>\s+)?(?:[\w.<>?]+\.)?"# + identifier, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*"# + kotlinModifiers + #"(class|interface|object)\s+"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*"# + kotlinModifiers + #"typealias\s+"# + identifier, kind: .type),
        LineRule(#"^"# + kotlinModifiers + #"(?:val|var)\s+"# + identifier, kind: .variable, topLevelOnly: true),
    ]

    private static let csharpModifiers = #"(?:(?:public|private|protected|internal|static|readonly|sealed|abstract|partial|virtual|override|async|extern|unsafe|new|file|required)\s+)*"#

    private static let csharpRules: [LineRule] = [
        LineRule(#"^\s*"# + csharpModifiers + #"(class|interface|enum|struct|record|namespace)\s+"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s+"# + csharpModifiers + #"(?:[\w.<>\[\],?]+\s+)+"# + controlKeywords + identifier + #"\s*(?:<[^>]*>)?\s*\([^;]*$"#, kind: .method),
        LineRule(#"^\s+"# + csharpModifiers + #"(?:[\w.<>\[\],?]+\s+)+"# + identifier + #"\s*\{\s*(?:get|set|init)\b"#, kind: .variable),
    ]

    private static let cFamilyRules: [LineRule] = [
        LineRule(#"^\s*[-+]\s*\([^)]*\)\s*"# + identifier, kind: .method),
        LineRule(#"^\s*@(interface|implementation|protocol)\s+"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*(?:typedef\s+)?(class|struct|enum|union|namespace)\s+(?:class\s+)?"# + identifier + #"\s*(?::|\{|$)"#, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*#\s*define\s+"# + identifier, kind: .macro),
        LineRule(#"^\s*(?:template\s*<[^>]*>\s*)?(?:[A-Za-z_][\w:<>,*&]*\s+)+[*&]*\s*"# + controlKeywords + #"([A-Za-z_][\w:~]*)\s*\([^;{}]*\)\s*(?:const\s*)?(?:noexcept\s*)?(?:override\s*)?(?:final\s*)?\{?\s*$"#, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*using\s+"# + identifier + #"\s*="#, kind: .type),
    ]

    private static let rubyRules: [LineRule] = [
        LineRule(#"^\s*def\s+(?:self\.)?([A-Za-z_][A-Za-z0-9_]*[?!=]?)"#, kind: .method),
        LineRule(#"^\s*class\s+([A-Z][A-Za-z0-9_:]*)"#, kind: .class),
        LineRule(#"^\s*module\s+([A-Z][A-Za-z0-9_:]*)"#, kind: .module),
        LineRule(#"^\s*([A-Z][A-Z0-9_]+)\s*="#, kind: .constant),
    ]

    private static let phpRules: [LineRule] = [
        LineRule(#"^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+&?\s*"# + identifier, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*(?:(?:abstract|final|readonly)\s+)*(class|interface|trait|enum)\s+"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*namespace\s+([\w\\]+)"#, kind: .namespace),
        LineRule(#"^\s*(?:const|define\s*\(\s*['"])([A-Z_][A-Z0-9_]*)"#, kind: .constant),
    ]

    private static let shellRules: [LineRule] = [
        LineRule(#"^\s*function\s+"# + identifier, kind: .function),
        LineRule(#"^\s*"# + identifier + #"\s*\(\s*\)\s*\{?"#, kind: .function),
        LineRule(#"^(?:export\s+|readonly\s+|declare\s+-?\w*\s+)?([A-Z_][A-Z0-9_]+)="#, kind: .constant, topLevelOnly: true),
    ]

    private static let dartRules: [LineRule] = [
        LineRule(#"^\s*(?:abstract\s+)?(?:base\s+|final\s+|sealed\s+|interface\s+)?(class|mixin|enum|extension)\s+"# + identifier, keywordGroup: 1, nameGroup: 2),
        LineRule(#"^\s*(?:static\s+)?(?:[\w<>?,\s]+\s+)?"# + controlKeywords + identifier + #"\s*\([^;]*\)\s*(?:async\*?\s*|sync\*\s*)?(?:\{|=>)\s*"#, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*typedef\s+"# + identifier, kind: .type),
    ]

    private static let luaRules: [LineRule] = [
        LineRule(#"^\s*(?:local\s+)?function\s+([\w.:]+)"#, kind: .function, methodWhenIndented: true),
        LineRule(#"^\s*(?:local\s+)?([\w.]+)\s*=\s*function\b"#, kind: .function),
    ]

    private static let sqlRules: [LineRule] = [
        LineRule(#"(?i)^\s*create\s+(?:or\s+replace\s+)?(table|view|function|procedure|index|trigger|type|schema)\s+(?:if\s+not\s+exists\s+)?([\w.\"`\[\]]+)"#, keywordGroup: 1, nameGroup: 2),
    ]

    // MARK: - Import patterns

    static func importPatterns(for language: Language) -> [NSRegularExpression] {
        switch language {
        case .swift:
            return [Rx.make(#"^\s*(?:@testable\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][\w]*)"#)]
        case .python:
            return [
                Rx.make(#"^\s*import\s+([\w.]+)"#),
                Rx.make(#"^\s*from\s+([\w.]+)\s+import\b"#),
            ]
        case .javascript, .typescript:
            return [
                Rx.make(#"^\s*import\s+(?:type\s+)?(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]"#),
                Rx.make(#"^\s*export\s+(?:type\s+)?(?:\*|\{[^}]*\})\s*(?:as\s+\w+\s+)?from\s+['"]([^'"]+)['"]"#),
                Rx.make(#"\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)"#),
                Rx.make(#"\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)"#),
            ]
        case .go:
            return [Rx.make(#"^\s*import\s+(?:\w+\s+)?"([^"]+)""#)]
        case .rust:
            return [
                Rx.make(#"^\s*(?:pub(?:\([^)]*\))?\s+)?use\s+([\w:]+)"#),
                Rx.make(#"^\s*extern\s+crate\s+(\w+)"#),
            ]
        case .java, .kotlin, .scala:
            return [Rx.make(#"^\s*import\s+(?:static\s+)?([\w.]+(?:\.\*)?)"#)]
        case .csharp:
            return [Rx.make(#"^\s*(?:global\s+)?using\s+(?:static\s+)?(?!var\b)(?:\w+\s*=\s*)?([\w.]+)\s*;"#)]
        case .c, .cpp, .objectiveC:
            return [Rx.make(#"^\s*#\s*(?:include|import)\s*[<"]([^>"]+)[>"]"#)]
        case .ruby:
            return [Rx.make(#"^\s*require(?:_relative)?\s+['"]([^'"]+)['"]"#)]
        case .php:
            return [
                Rx.make(#"^\s*use\s+([\w\\]+)"#),
                Rx.make(#"\b(?:require|include)(?:_once)?\s*\(?\s*(?:__DIR__\s*\.\s*)?['"]([^'"]+)['"]"#),
            ]
        case .shell:
            return [Rx.make(#"^\s*(?:source|\.)\s+([^\s;]+)"#)]
        case .dart:
            return [Rx.make(#"^\s*(?:import|export|part)\s+['"]([^'"]+)['"]"#)]
        case .lua:
            return [Rx.make(#"\brequire\s*\(?\s*['"]([^'"]+)['"]"#)]
        default:
            return []
        }
    }
}

private extension NSRegularExpression {
    func firstMatchExists(in text: String) -> Bool {
        Rx.firstMatch(self, in: text) != nil
    }
}
