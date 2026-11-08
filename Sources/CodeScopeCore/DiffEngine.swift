import Foundation

public enum DiffLineKind: Sendable {
    case context, added, removed
}

public struct DiffLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let kind: DiffLineKind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
}

public struct DiffStats: Sendable, Equatable {
    public var added: Int
    public var removed: Int
}

/// Line-based diff: trims the common prefix/suffix, then runs an LCS on the middle. For very
/// large differing regions it degrades to a whole-block replacement rather than exhausting memory.
public enum DiffEngine {

    public static func diff(old: String, new: String, context: Int = 3) -> [DiffLine] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        return diff(oldLines: oldLines, newLines: newLines, context: context)
    }

    public static func stats(_ lines: [DiffLine]) -> DiffStats {
        var stats = DiffStats(added: 0, removed: 0)
        for line in lines {
            switch line.kind {
            case .added: stats.added += 1
            case .removed: stats.removed += 1
            case .context: break
            }
        }
        return stats
    }

    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    enum Op { case equal, insert, delete }

    static func diff(oldLines: [String], newLines: [String], context: Int) -> [DiffLine] {
        // Common prefix / suffix.
        var prefix = 0
        while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (oldLines.count - prefix) && suffix < (newLines.count - prefix)
                && oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMiddle = Array(newLines[prefix..<(newLines.count - suffix)])

        var ops: [Op] = Array(repeating: .equal, count: prefix)
        ops.append(contentsOf: middleOps(oldMiddle, newMiddle))
        ops.append(contentsOf: Array(repeating: .equal, count: suffix))

        // Walk the ops, producing lines; then keep only changed lines plus `context` lines around them.
        var all: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        var id = 0
        for op in ops {
            switch op {
            case .equal:
                all.append(DiffLine(id: id, kind: .context, text: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            case .delete:
                all.append(DiffLine(id: id, kind: .removed, text: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: nil))
                oldIndex += 1
            case .insert:
                all.append(DiffLine(id: id, kind: .added, text: newLines[newIndex], oldLine: nil, newLine: newIndex + 1))
                newIndex += 1
            }
            id += 1
        }

        if context < 0 { return all }
        var keep = Array(repeating: false, count: all.count)
        for (index, line) in all.enumerated() where line.kind != .context {
            let lower = max(0, index - context)
            let upper = min(all.count - 1, index + context)
            if lower <= upper {
                for k in lower...upper { keep[k] = true }
            }
        }
        return all.enumerated().filter { keep[$0.offset] }.map { $0.element }
    }

    private static let maxLCSCells = 8_000_000

    static func middleOps(_ a: [String], _ b: [String]) -> [Op] {
        if a.isEmpty { return Array(repeating: .insert, count: b.count) }
        if b.isEmpty { return Array(repeating: .delete, count: a.count) }
        if a.count * b.count > maxLCSCells {
            return Array(repeating: .delete, count: a.count) + Array(repeating: .insert, count: b.count)
        }
        let n = a.count
        let m = b.count
        // table[i][j] = LCS length of a[i...] and b[j...]
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        var i = n - 1
        while i >= 0 {
            var j = m - 1
            while j >= 0 {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
                j -= 1
            }
            i -= 1
        }
        var ops: [Op] = []
        var x = 0
        var y = 0
        while x < n && y < m {
            if a[x] == b[y] {
                ops.append(.equal)
                x += 1
                y += 1
            } else if table[x + 1][y] >= table[x][y + 1] {
                ops.append(.delete)
                x += 1
            } else {
                ops.append(.insert)
                y += 1
            }
        }
        while x < n {
            ops.append(.delete)
            x += 1
        }
        while y < m {
            ops.append(.insert)
            y += 1
        }
        return ops
    }
}
