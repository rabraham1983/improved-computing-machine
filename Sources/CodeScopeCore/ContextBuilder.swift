import Foundation

/// The "repo map" handed to Claude as a cached system block: project summary, directory tree,
/// dependency facts, and each file either in full or as a symbol outline, within a token budget.
public struct CodebaseContext: Sendable {
    public let text: String
    public let fullFiles: [String]
    public let outlinedFiles: [String]
    public let estimatedTokens: Int
    public let tokenBudget: Int

    public var coverageDescription: String {
        "\(fullFiles.count) files in full, \(outlinedFiles.count) outlined · ≈\(estimatedTokens.formattedWithSeparator) tokens of \(tokenBudget.formattedWithSeparator) budget"
    }
}

public enum ContextBuilder {

    public static let defaultTokenBudget = 300_000
    static let perFileTokenCap = 40_000
    static let maxTreeLines = 700

    public static func build(index: ProjectIndex, tokenBudget: Int = defaultTokenBudget) -> CodebaseContext {
        var out = ""
        out += "# Codebase snapshot: \(index.name)\n"
        out += "Root directory: \(index.rootPath)\n"
        out += "Indexed files: \(index.files.count) (\(index.codeFiles.count) source files, \(index.totalLines.formattedWithSeparator) lines, \(index.totalSymbolCount) symbols)."
        if index.skippedFileCount > 0 {
            out += " \(index.skippedFileCount) binary/large/ignored files were skipped."
        }
        out += "\n"
        let breakdown = index.languageBreakdown.prefix(8).map { "\($0.language.displayName) \($0.lines.formattedWithSeparator) lines" }
        if !breakdown.isEmpty {
            out += "Languages: " + breakdown.joined(separator: ", ") + "\n"
        }
        out += "\n## Directory tree\n```\n"
        out += directoryTree(paths: index.files.map { $0.relativePath })
        out += "```\n"

        if !index.entryPoints.isEmpty {
            out += "\n## Likely entry points (heuristic)\n"
            for entry in index.entryPoints.prefix(25) {
                out += "- \(entry.path) — \(entry.reason)\n"
            }
        }

        let external = index.externalDependencies.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        if !external.isEmpty {
            out += "\n## External dependencies (import count)\n"
            out += external.prefix(60).map { "\($0.key) (\($0.value))" }.joined(separator: ", ") + "\n"
        }

        let hubs = index.files
            .map { ($0.relativePath, index.fanIn(of: $0.relativePath)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(20)
        if !hubs.isEmpty {
            out += "\n## Most depended-upon files (internal fan-in)\n"
            for (path, count) in hubs {
                out += "- \(path): imported by \(count) files\n"
            }
        }

        out += "\n## Files\n"
        out += "Files marked OUTLINE ONLY are summarised by their symbols; call `read_file` to see their source.\n\n"

        let headerTokens = TokenEstimator.estimate(out)
        var remaining = tokenBudget - headerTokens
        var fullFiles: [String] = []
        var outlinedFiles: [String] = []
        var fileSections: [(order: Int, text: String)] = []

        let entrySet = Set(index.entryPoints.map { $0.path })
        let prioritized = index.files.enumerated().sorted { lhs, rhs in
            priority(lhs.element, index: index, entries: entrySet) > priority(rhs.element, index: index, entries: entrySet)
        }

        for (order, file) in prioritized {
            let header = fileHeader(file, index: index)
            let fullText = header + "```\(file.language.fenceName)\n" + file.content + (file.content.hasSuffix("\n") ? "" : "\n") + "```\n\n"
            let cost = TokenEstimator.estimate(fullText)
            if cost <= min(remaining, perFileTokenCap) {
                remaining -= cost
                fullFiles.append(file.relativePath)
                fileSections.append((order, fullText))
            } else {
                let outlineText = header.replacingOccurrences(of: "\n", with: " — OUTLINE ONLY\n") + outline(for: file) + "\n"
                remaining -= TokenEstimator.estimate(outlineText)
                outlinedFiles.append(file.relativePath)
                fileSections.append((order, outlineText))
            }
        }

        // Emit in path order so the map reads like the tree.
        for section in fileSections.sorted(by: { $0.order < $1.order }) {
            out += section.text
        }

        let estimated = TokenEstimator.estimate(out)
        return CodebaseContext(text: out,
                               fullFiles: fullFiles.sorted(),
                               outlinedFiles: outlinedFiles.sorted(),
                               estimatedTokens: estimated,
                               tokenBudget: tokenBudget)
    }

    static func priority(_ file: CodeFile, index: ProjectIndex, entries: Set<String>) -> Double {
        var score = 0.0
        if file.isManifest { score += 1000 }
        if entries.contains(file.relativePath) { score += 500 }
        score += Double(index.fanIn(of: file.relativePath)) * 25
        if file.language.isCode { score += 100 }
        if file.language == .markdown { score += 40 }
        if file.relativePath.lowercased().contains("test") { score -= 60 }
        score -= log(Double(max(file.byteSize, 1))) * 5
        return score
    }

    static func fileHeader(_ file: CodeFile, index: ProjectIndex) -> String {
        var parts = ["\(file.language.displayName)", "\(file.metrics.totalLines) lines"]
        if file.language.isCode {
            parts.append("complexity \(file.metrics.complexity)")
        }
        let fanIn = index.fanIn(of: file.relativePath)
        if fanIn > 0 { parts.append("fan-in \(fanIn)") }
        return "### \(file.relativePath) (\(parts.joined(separator: ", ")))\n"
    }

    public static func outline(for file: CodeFile) -> String {
        var out = ""
        if !file.imports.isEmpty {
            out += "imports: " + file.imports.prefix(20).joined(separator: ", ")
            if file.imports.count > 20 { out += ", … (\(file.imports.count - 20) more)" }
            out += "\n"
        }
        if file.symbols.isEmpty {
            out += "(no symbols detected)\n"
            return out
        }
        for symbol in file.symbols.prefix(80) {
            let indent = String(repeating: " ", count: min(symbol.indent / 2, 8))
            out += "L\(symbol.line) \(indent)\(symbol.kind.displayName) \(symbol.name)\n"
        }
        if file.symbols.count > 80 {
            out += "… \(file.symbols.count - 80) more symbols\n"
        }
        return out
    }

    /// Renders a compact directory tree from a list of relative paths.
    public static func directoryTree(paths: [String]) -> String {
        final class Node {
            var children: [String: Node] = [:]
            var isFile = false
        }
        let root = Node()
        for path in paths {
            var node = root
            let parts = path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                if let child = node.children[part] {
                    node = child
                } else {
                    let child = Node()
                    node.children[part] = child
                    node = child
                }
                if index == parts.count - 1 { node.isFile = true }
            }
        }

        var lines: [String] = []
        func walk(_ node: Node, depth: Int) {
            let names = node.children.keys.sorted { lhs, rhs in
                let lDir = !(node.children[lhs]?.isFile ?? false)
                let rDir = !(node.children[rhs]?.isFile ?? false)
                if lDir != rDir { return lDir }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            for name in names {
                guard let child = node.children[name] else { continue }
                if lines.count >= maxTreeLines { return }
                let indent = String(repeating: "  ", count: depth)
                lines.append(indent + name + (child.isFile ? "" : "/"))
                if !child.isFile {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        var result = lines.joined(separator: "\n") + "\n"
        if lines.count >= maxTreeLines {
            result += "… (tree truncated; \(paths.count) files total)\n"
        }
        return result
    }
}

extension Int {
    public var formattedWithSeparator: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}
