import Foundation

/// Line-count and complexity heuristics.
public enum MetricsCalculator {

    private static let branchRegex = Rx.make(#"\b(?:if|elif|elsif|else\s+if|for|foreach|while|case|when|catch|except|rescue|guard|unless|until)\b|&&|\|\||\?\?|\bor\b|\band\b"#)

    public static func compute(content: String, language: Language) -> FileMetrics {
        let lines = content.components(separatedBy: "\n")
        var metrics = FileMetrics(totalLines: lines.count, codeLines: 0, commentLines: 0, blankLines: 0, complexity: 1)
        if content.isEmpty {
            metrics.totalLines = 0
            return metrics
        }
        // A trailing newline produces an empty final component; do not count it as a line.
        if lines.last?.isEmpty == true {
            metrics.totalLines = lines.count - 1
        }

        let lineComment = lineCommentPrefix(for: language)
        let supportsBlockComments = blockCommentSupport(for: language)
        var inBlockComment = false

        for line in lines.prefix(metrics.totalLines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                metrics.blankLines += 1
                continue
            }
            if inBlockComment {
                metrics.commentLines += 1
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if supportsBlockComments && trimmed.hasPrefix("/*") {
                metrics.commentLines += 1
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }
            if let prefix = lineComment, trimmed.hasPrefix(prefix) {
                metrics.commentLines += 1
                continue
            }
            metrics.codeLines += 1
        }

        if language.isCode {
            metrics.complexity = 1 + Rx.count(branchRegex, in: content)
        }
        return metrics
    }

    public static func lineCommentPrefix(for language: Language) -> String? {
        switch language {
        case .python, .ruby, .shell, .yaml, .toml, .makefile, .dockerfile, .perl, .r:
            return "#"
        case .sql, .lua:
            return "--"
        case .html, .xml, .markdown, .json, .plaintext, .other:
            return nil
        default:
            return "//"
        }
    }

    static func blockCommentSupport(for language: Language) -> Bool {
        switch language {
        case .swift, .objectiveC, .c, .cpp, .javascript, .typescript, .go, .rust, .java, .kotlin, .scala, .csharp, .php, .css, .dart, .sql:
            return true
        default:
            return false
        }
    }
}

/// Cheap token estimate used for context budgeting. Source code averages roughly
/// 3–4 characters per token on current Claude tokenizers; we use 3.2 to stay conservative.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        max(1, Int(Double(text.utf8.count) / 3.2))
    }

    public static func estimate(bytes: Int) -> Int {
        max(1, Int(Double(bytes) / 3.2))
    }
}
