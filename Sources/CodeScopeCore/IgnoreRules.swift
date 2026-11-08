import Foundation

/// Minimal glob matcher supporting `*`, `?`, `**` and character classes. Used for .gitignore
/// style rules; it intentionally covers the common cases rather than the full specification.
public struct GlobPattern: Sendable, Hashable {
    public let pattern: String
    public let anchored: Bool
    public let directoryOnly: Bool
    public let negated: Bool

    public init?(line rawLine: String) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        }
        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        var anchored = false
        if line.hasPrefix("/") {
            anchored = true
            line.removeFirst()
        } else if line.contains("/") {
            // A slash anywhere in the pattern anchors it to the root (gitignore semantics).
            anchored = true
        }
        if line.isEmpty { return nil }
        self.pattern = line
        self.anchored = anchored
        self.directoryOnly = directoryOnly
        self.negated = negated
    }

    /// `relativePath` uses "/" separators and no leading slash.
    public func matches(relativePath: String, isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory { return false }
        if anchored {
            if GlobPattern.match(pattern: pattern, text: relativePath) { return true }
            // A pattern like "build/" should also match everything underneath "build".
            return GlobPattern.match(pattern: pattern + "/**", text: relativePath)
        }
        // Unanchored: match against any path component suffix.
        let components = relativePath.split(separator: "/").map(String.init)
        for index in components.indices {
            let suffix = components[index...].joined(separator: "/")
            if GlobPattern.match(pattern: pattern, text: suffix) { return true }
            if GlobPattern.match(pattern: pattern, text: components[index]) { return true }
        }
        return false
    }

    /// Glob match where `*` and `?` do not cross "/" and `**` does.
    public static func match(pattern: String, text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        return matchFrom(p, 0, t, 0)
    }

    private static func matchFrom(_ p: [Character], _ pi: Int, _ t: [Character], _ ti: Int) -> Bool {
        var pi = pi
        var ti = ti
        while pi < p.count {
            let c = p[pi]
            if c == "*" {
                // "**" matches across directory separators.
                if pi + 1 < p.count && p[pi + 1] == "*" {
                    var next = pi + 2
                    if next < p.count && p[next] == "/" { next += 1 }
                    if next >= p.count { return true }
                    var k = ti
                    while k <= t.count {
                        if matchFrom(p, next, t, k) { return true }
                        k += 1
                    }
                    return false
                }
                var k = ti
                while k <= t.count {
                    if matchFrom(p, pi + 1, t, k) { return true }
                    if k < t.count && t[k] == "/" { return false }
                    k += 1
                }
                return false
            }
            if ti >= t.count { return false }
            if c == "?" {
                if t[ti] == "/" { return false }
                pi += 1
                ti += 1
                continue
            }
            if c == "[" {
                guard let close = p[pi...].firstIndex(of: "]"), close > pi + 1 else {
                    if t[ti] != c { return false }
                    pi += 1
                    ti += 1
                    continue
                }
                var set = Array(p[(pi + 1)..<close])
                var negate = false
                if let first = set.first, first == "!" || first == "^" {
                    negate = true
                    set.removeFirst()
                }
                var matched = false
                var index = 0
                while index < set.count {
                    if index + 2 < set.count && set[index + 1] == "-" {
                        if set[index] <= t[ti] && t[ti] <= set[index + 2] { matched = true }
                        index += 3
                    } else {
                        if set[index] == t[ti] { matched = true }
                        index += 1
                    }
                }
                if matched == negate { return false }
                pi = close + 1
                ti += 1
                continue
            }
            if c == "\\" && pi + 1 < p.count {
                if t[ti] != p[pi + 1] { return false }
                pi += 2
                ti += 1
                continue
            }
            if t[ti] != c { return false }
            pi += 1
            ti += 1
        }
        return ti == t.count
    }
}

/// Decides which paths are excluded from indexing: built-in noise directories plus the
/// project's .gitignore (root level only).
public struct IgnoreRules: Sendable {
    public static let defaultDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "dist", "DerivedData", "Pods",
        "Carthage", "__pycache__", ".venv", "venv", "env", ".idea", ".vscode", "target", "vendor",
        ".codescope", "coverage", ".next", ".nuxt", ".cache", ".pytest_cache", ".mypy_cache", ".tox",
        "bin", "obj", ".gradle", ".swiftpm", "xcuserdata", ".dart_tool", ".terraform", "bower_components",
        ".parcel-cache", ".turbo", ".yarn", "site-packages", ".eggs", "htmlcov"
    ]

    public static let defaultFileSuffixes: [String] = [
        ".min.js", ".min.css", ".map", ".lock", ".pyc", ".pyo", ".class", ".o", ".a", ".so", ".dylib",
        ".dll", ".exe", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".pdf", ".zip",
        ".gz", ".tar", ".7z", ".jar", ".war", ".bin", ".dat", ".db", ".sqlite", ".sqlite3", ".mp3",
        ".mp4", ".mov", ".wav", ".ttf", ".otf", ".woff", ".woff2", ".svg", ".xcuserstate", ".DS_Store",
        ".pbxproj", ".xcassets", ".car", ".nib", ".strings", ".pb", ".bundle"
    ]

    public static let defaultFileNames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "bun.lockb", ".ds_store", "thumbs.db", "yarn-error.log", "npm-debug.log"
    ]

    public var patterns: [GlobPattern]
    public var directories: Set<String>
    public var fileSuffixes: [String]
    public var maxFileSize: Int

    public init(patterns: [GlobPattern] = [],
                directories: Set<String> = IgnoreRules.defaultDirectories,
                fileSuffixes: [String] = IgnoreRules.defaultFileSuffixes,
                maxFileSize: Int = 768 * 1024) {
        self.patterns = patterns
        self.directories = directories
        self.fileSuffixes = fileSuffixes
        self.maxFileSize = maxFileSize
    }

    public static func load(from root: URL) -> IgnoreRules {
        var rules = IgnoreRules()
        let gitignore = root.appendingPathComponent(".gitignore")
        if let text = try? String(contentsOf: gitignore, encoding: .utf8) {
            rules.patterns = text.components(separatedBy: .newlines).compactMap { GlobPattern(line: $0) }
        }
        return rules
    }

    public func shouldSkipDirectory(name: String, relativePath: String) -> Bool {
        if directories.contains(name) { return true }
        if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") || name.hasSuffix(".xcassets") || name.hasSuffix(".app") || name.hasSuffix(".framework") {
            return true
        }
        return isIgnored(relativePath: relativePath, isDirectory: true)
    }

    public func shouldSkipFile(name: String, relativePath: String, size: Int) -> Bool {
        if size > maxFileSize || size == 0 { return true }
        let lower = name.lowercased()
        if IgnoreRules.defaultFileNames.contains(lower) { return true }
        for suffix in fileSuffixes where lower.hasSuffix(suffix.lowercased()) {
            return true
        }
        return isIgnored(relativePath: relativePath, isDirectory: false)
    }

    private func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for pattern in patterns where pattern.matches(relativePath: relativePath, isDirectory: isDirectory) {
            ignored = !pattern.negated
        }
        return ignored
    }
}
