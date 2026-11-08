import Foundation

public enum EditAction: String, Codable, Sendable, CaseIterable {
    case patch
    case replaceFile = "replace_file"
    case create
    case delete

    public var displayName: String {
        switch self {
        case .patch: return "Modify"
        case .replaceFile: return "Rewrite"
        case .create: return "Create"
        case .delete: return "Delete"
        }
    }
}

public struct EditHunk: Codable, Sendable, Hashable {
    public var find: String
    public var replace: String

    public init(find: String, replace: String) {
        self.find = find
        self.replace = replace
    }
}

public struct ProposedEdit: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var path: String
    public var action: EditAction
    public var explanation: String
    public var content: String
    public var hunks: [EditHunk]

    public init(id: UUID = UUID(), path: String, action: EditAction, explanation: String, content: String, hunks: [EditHunk]) {
        self.id = id
        self.path = path
        self.action = action
        self.explanation = explanation
        self.content = content
        self.hunks = hunks
    }
}

public struct EditPreview: Sendable {
    public var original: String?
    public var modified: String?
    public var diff: [DiffLine]
    public var stats: DiffStats
    public var error: String?

    public var isApplicable: Bool { error == nil }
}

public struct ApplyReceipt: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let path: String
        public let existedBefore: Bool
    }

    public let id: UUID
    public let date: Date
    public let rootPath: String
    public let backupPath: String
    public let entries: [Entry]
    public let summary: String
}

public enum EditError: LocalizedError {
    case unsafePath(String)
    case fileNotFound(String)
    case alreadyExists(String)
    case hunkNotFound(index: Int, path: String)
    case hunkAmbiguous(index: Int, path: String, count: Int)
    case emptyContent(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "Refusing to touch a path outside the project: \(path)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .alreadyExists(let path): return "File already exists: \(path)"
        case .hunkNotFound(let index, let path): return "Hunk \(index + 1) in \(path): the `find` text was not found in the current file."
        case .hunkAmbiguous(let index, let path, let count): return "Hunk \(index + 1) in \(path): the `find` text occurs \(count) times; it must be unique."
        case .emptyContent(let path): return "No content provided for \(path)."
        case .io(let message): return message
        }
    }
}

/// Parses `propose_edits` tool input, previews edits as diffs, applies them with backups, and reverts.
public enum EditApplier {

    public static let backupDirectoryName = ".codescope/backups"

    // MARK: Parsing

    public static func parse(toolInput: JSONValue) -> (summary: String, edits: [ProposedEdit]) {
        let summary = toolInput["summary"]?.stringValue ?? ""
        var edits: [ProposedEdit] = []
        for item in toolInput["edits"]?.arrayValue ?? [] {
            guard let path = item["path"]?.stringValue, !path.isEmpty,
                  let actionRaw = item["action"]?.stringValue,
                  let action = EditAction(rawValue: actionRaw) else { continue }
            let hunks = (item["hunks"]?.arrayValue ?? []).compactMap { hunk -> EditHunk? in
                guard let find = hunk["find"]?.stringValue, let replace = hunk["replace"]?.stringValue else { return nil }
                return EditHunk(find: find, replace: replace)
            }
            edits.append(ProposedEdit(path: CodebaseToolExecutor.normalizePath(path),
                                      action: action,
                                      explanation: item["explanation"]?.stringValue ?? "",
                                      content: item["content"]?.stringValue ?? "",
                                      hunks: hunks))
        }
        return (summary, edits)
    }

    // MARK: Paths

    public static func resolve(path: String, root: URL) throws -> URL {
        let normalized = CodebaseToolExecutor.normalizePath(path)
        if normalized.isEmpty || normalized.split(separator: "/").contains("..") {
            throw EditError.unsafePath(path)
        }
        let rootPath = root.standardizedFileURL.path
        let target = root.appendingPathComponent(normalized).standardizedFileURL
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard target.path.hasPrefix(rootPrefix) else {
            throw EditError.unsafePath(path)
        }
        return target
    }

    // MARK: Preview

    public static func preview(_ edit: ProposedEdit, root: URL) -> EditPreview {
        do {
            let url = try resolve(path: edit.path, root: root)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let original: String? = exists ? (try? String(contentsOf: url, encoding: .utf8)) : nil

            switch edit.action {
            case .create:
                if exists { throw EditError.alreadyExists(edit.path) }
                if edit.content.isEmpty { throw EditError.emptyContent(edit.path) }
                let diff = DiffEngine.diff(old: "", new: edit.content, context: -1)
                return EditPreview(original: nil, modified: edit.content, diff: diff, stats: DiffEngine.stats(diff), error: nil)

            case .delete:
                guard exists, let original else { throw EditError.fileNotFound(edit.path) }
                let diff = DiffEngine.diff(old: original, new: "", context: -1)
                return EditPreview(original: original, modified: nil, diff: diff, stats: DiffEngine.stats(diff), error: nil)

            case .replaceFile:
                guard exists, let original else { throw EditError.fileNotFound(edit.path) }
                if edit.content.isEmpty { throw EditError.emptyContent(edit.path) }
                let diff = DiffEngine.diff(old: original, new: edit.content)
                return EditPreview(original: original, modified: edit.content, diff: diff, stats: DiffEngine.stats(diff), error: nil)

            case .patch:
                guard exists, let original else { throw EditError.fileNotFound(edit.path) }
                let modified = try applyHunks(edit.hunks, to: original, path: edit.path)
                let diff = DiffEngine.diff(old: original, new: modified)
                return EditPreview(original: original, modified: modified, diff: diff, stats: DiffEngine.stats(diff), error: nil)
            }
        } catch {
            return EditPreview(original: nil, modified: nil, diff: [], stats: DiffStats(added: 0, removed: 0), error: error.localizedDescription)
        }
    }

    /// Applies find/replace hunks. Each `find` must match exactly once; when an exact match fails,
    /// a whitespace-tolerant line match is attempted (trailing whitespace and indentation ignored).
    public static func applyHunks(_ hunks: [EditHunk], to original: String, path: String) throws -> String {
        var text = original
        for (index, hunk) in hunks.enumerated() {
            if hunk.find.isEmpty {
                throw EditError.hunkNotFound(index: index, path: path)
            }
            let occurrences = countOccurrences(of: hunk.find, in: text)
            if occurrences == 1, let range = text.range(of: hunk.find) {
                text.replaceSubrange(range, with: hunk.replace)
                continue
            }
            if occurrences > 1 {
                throw EditError.hunkAmbiguous(index: index, path: path, count: occurrences)
            }
            // Fallback: compare lines ignoring leading/trailing whitespace.
            guard let replaced = fuzzyReplace(find: hunk.find, replace: hunk.replace, in: text) else {
                throw EditError.hunkNotFound(index: index, path: path)
            }
            switch replaced {
            case .success(let newText): text = newText
            case .ambiguous(let count): throw EditError.hunkAmbiguous(index: index, path: path, count: count)
            }
        }
        return text
    }

    enum FuzzyOutcome {
        case success(String)
        case ambiguous(Int)
    }

    static func fuzzyReplace(find: String, replace: String, in text: String) -> FuzzyOutcome? {
        let textLines = text.components(separatedBy: "\n")
        var findLines = find.components(separatedBy: "\n")
        if findLines.last == "" { findLines.removeLast() }
        if findLines.first == "" { findLines.removeFirst() }
        guard !findLines.isEmpty, findLines.count <= textLines.count else { return nil }
        let normalizedFind = findLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let normalizedText = textLines.map { $0.trimmingCharacters(in: .whitespaces) }

        var matches: [Int] = []
        var start = 0
        while start + normalizedFind.count <= normalizedText.count {
            if Array(normalizedText[start..<(start + normalizedFind.count)]) == normalizedFind {
                matches.append(start)
            }
            start += 1
        }
        if matches.isEmpty { return nil }
        if matches.count > 1 { return .ambiguous(matches.count) }

        let matchStart = matches[0]
        // Preserve the indentation of the first matched line when the replacement's first line has none.
        let originalIndent = textLines[matchStart].prefix { $0 == " " || $0 == "\t" }
        var replaceLines = replace.components(separatedBy: "\n")
        if replace.hasSuffix("\n") && replaceLines.last == "" { replaceLines.removeLast() }
        if let first = replaceLines.first, !first.hasPrefix(" "), !first.hasPrefix("\t"), !originalIndent.isEmpty {
            let findIndent = findLines[0].prefix { $0 == " " || $0 == "\t" }
            if findIndent.isEmpty {
                replaceLines = replaceLines.map { $0.isEmpty ? $0 : String(originalIndent) + $0 }
            }
        }
        var result = Array(textLines[0..<matchStart])
        result.append(contentsOf: replaceLines)
        result.append(contentsOf: textLines[(matchStart + normalizedFind.count)...])
        return .success(result.joined(separator: "\n"))
    }

    static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            if count > 1 { break }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    // MARK: Apply / revert

    public static func apply(_ edits: [ProposedEdit], root: URL, summary: String) throws -> ApplyReceipt {
        let fileManager = FileManager.default
        let receiptID = UUID()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupRoot = root.appendingPathComponent(backupDirectoryName).appendingPathComponent(stamp + "-" + String(receiptID.uuidString.prefix(8)))
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        // Compute every modification before touching disk so a bad hunk aborts the whole batch.
        struct Planned {
            let edit: ProposedEdit
            let url: URL
            let newContent: String?
            let existedBefore: Bool
        }
        var planned: [Planned] = []
        for edit in edits {
            let url = try resolve(path: edit.path, root: root)
            let preview = preview(edit, root: root)
            if let error = preview.error {
                throw EditError.io(error)
            }
            let existed = fileManager.fileExists(atPath: url.path)
            planned.append(Planned(edit: edit, url: url, newContent: preview.modified, existedBefore: existed))
        }

        var entries: [ApplyReceipt.Entry] = []
        for plan in planned {
            if plan.existedBefore {
                let backupURL = backupRoot.appendingPathComponent(plan.edit.path)
                try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: plan.url, to: backupURL)
            }
            switch plan.edit.action {
            case .delete:
                try fileManager.removeItem(at: plan.url)
            default:
                guard let content = plan.newContent else { throw EditError.emptyContent(plan.edit.path) }
                try fileManager.createDirectory(at: plan.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: plan.url, atomically: true, encoding: .utf8)
            }
            entries.append(ApplyReceipt.Entry(path: plan.edit.path, existedBefore: plan.existedBefore))
        }

        let receipt = ApplyReceipt(id: receiptID,
                                   date: Date(),
                                   rootPath: root.standardizedFileURL.path,
                                   backupPath: backupRoot.path,
                                   entries: entries,
                                   summary: summary)
        let manifest = try JSONEncoder().encode(receipt)
        try manifest.write(to: backupRoot.appendingPathComponent("receipt.json"))
        return receipt
    }

    public static func revert(_ receipt: ApplyReceipt) throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: receipt.rootPath)
        let backupRoot = URL(fileURLWithPath: receipt.backupPath)
        for entry in receipt.entries {
            let target = try resolve(path: entry.path, root: root)
            if entry.existedBefore {
                let backup = backupRoot.appendingPathComponent(entry.path)
                guard fileManager.fileExists(atPath: backup.path) else {
                    throw EditError.io("Backup missing for \(entry.path)")
                }
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: backup, to: target)
            } else if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
    }
}
