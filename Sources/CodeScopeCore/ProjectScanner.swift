import Foundation

public enum ScanError: LocalizedError {
    case notADirectory(String)
    case unreadable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): return "\(path) is not a directory."
        case .unreadable(let path): return "Could not read \(path)."
        case .cancelled: return "Scan cancelled."
        }
    }
}

public struct ScanProgress: Sendable {
    public let filesIndexed: Int
    public let currentPath: String
}

/// Walks a project directory, reads source files and builds a `ProjectIndex`.
public enum ProjectScanner {

    public static let manifestNames: Set<String> = [
        "package.json", "package.swift", "cargo.toml", "go.mod", "pyproject.toml", "requirements.txt",
        "setup.py", "setup.cfg", "pipfile", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "gemfile", "composer.json", "podfile", "makefile", "cmakelists.txt",
        "dockerfile", "docker-compose.yml", "docker-compose.yaml", "tsconfig.json", "webpack.config.js",
        "vite.config.ts", "vite.config.js", "next.config.js", "next.config.mjs", "mix.exs", "pubspec.yaml",
        "project.clj", "build.sbt", "deno.json", "bun.lockb", ".csproj", "readme.md", "readme", "readme.txt",
        "claude.md", "agents.md", "architecture.md", "contributing.md", "procfile", "app.json", "manifest.json",
        "info.plist", "androidmanifest.xml", "nuxt.config.ts", "svelte.config.js", "angular.json", "tox.ini",
        "environment.yml", "serverless.yml", "terraform.tf", "main.tf", "justfile", "taskfile.yml"
    ]

    public static func scan(root: URL,
                            rules customRules: IgnoreRules? = nil,
                            progress: ((ScanProgress) -> Void)? = nil,
                            isCancelled: (() -> Bool)? = nil) throws -> ProjectIndex {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let rootPath = root.standardizedFileURL.path
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.notADirectory(rootPath)
        }

        let rules = customRules ?? IgnoreRules.load(from: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .nameKey]
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: keys,
                                                      options: [],
                                                      errorHandler: { _, _ in true }) else {
            throw ScanError.unreadable(rootPath)
        }

        var files: [CodeFile] = []
        var skipped = 0
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for case let url as URL in enumerator {
            if let isCancelled, isCancelled() { throw ScanError.cancelled }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.name ?? url.lastPathComponent
            let standardized = url.standardizedFileURL.path
            var relative = standardized
            if standardized.hasPrefix(rootPrefix) {
                relative = String(standardized.dropFirst(rootPrefix.count))
            }

            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if values?.isDirectory == true {
                if rules.shouldSkipDirectory(name: name, relativePath: relative) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            let lowerName = name.lowercased()
            let isManifest = manifestNames.contains(lowerName) || lowerName.hasSuffix(".csproj") || lowerName.hasSuffix(".gemspec") || lowerName.hasSuffix(".podspec")

            if rules.shouldSkipFile(name: name, relativePath: relative, size: size) && !isManifest {
                skipped += 1
                continue
            }
            if size > rules.maxFileSize {
                skipped += 1
                continue
            }

            guard let data = fileManager.contents(atPath: standardized) else {
                skipped += 1
                continue
            }
            if looksBinary(data) {
                skipped += 1
                continue
            }
            guard let content = decode(data) else {
                skipped += 1
                continue
            }

            let language = Language.detect(fileName: name)
            if language == .other && !isManifest && !looksLikeText(name: name) {
                skipped += 1
                continue
            }

            let extraction = SymbolExtractor.extract(content: content, language: language)
            let metrics = MetricsCalculator.compute(content: content, language: language)
            let file = CodeFile(relativePath: relative,
                                absolutePath: standardized,
                                language: language,
                                byteSize: data.count,
                                content: content,
                                symbols: extraction.symbols,
                                imports: extraction.imports,
                                metrics: metrics,
                                isManifest: isManifest)
            files.append(file)
            progress?(ScanProgress(filesIndexed: files.count, currentPath: relative))
        }

        let resolution = DependencyResolver.resolve(files: files)
        let entryPoints = EntryPointDetector.detect(files: files)
        let name = root.lastPathComponent.isEmpty ? rootPath : root.lastPathComponent

        return ProjectIndex(rootPath: rootPath,
                            name: name,
                            files: files,
                            edges: resolution.edges,
                            externalDependencies: resolution.external,
                            entryPoints: entryPoints,
                            skippedFileCount: skipped)
    }

    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8000)
        var control = 0
        for byte in sample {
            if byte == 0 { return true }
            if byte < 7 || (byte > 14 && byte < 32) { control += 1 }
        }
        return sample.count > 0 && Double(control) / Double(sample.count) > 0.3
    }

    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return nil
    }

    static func looksLikeText(name: String) -> Bool {
        let lower = name.lowercased()
        if !lower.contains(".") { return true } // extensionless files such as LICENSE, Procfile
        let textLike = [".txt", ".cfg", ".ini", ".conf", ".env", ".example", ".template", ".tmpl", ".gitignore", ".editorconfig", ".dockerignore", ".npmrc", ".nvmrc", ".ruby-version", ".python-version", ".tool-versions", ".graphql", ".gql", ".proto", ".thrift", ".avsc", ".csv", ".tsv", ".sh", ".bat", ".ps1", ".cmd", ".asm", ".s", ".vb", ".fs", ".ex", ".exs", ".erl", ".hs", ".clj", ".elm", ".nim", ".zig", ".v", ".sol", ".tf", ".hcl", ".gradle", ".groovy", ".jl", ".ml", ".mli", ".pas", ".f90", ".f", ".cob", ".rst", ".adoc", ".tex", ".vue", ".svelte", ".astro", ".ejs", ".hbs", ".pug", ".jinja", ".j2", ".twig", ".liquid", ".mustache"]
        return textLike.contains { lower.hasSuffix($0) }
    }
}

// MARK: - Dependency resolution

public enum DependencyResolver {

    public struct Resolution: Sendable {
        public let edges: [DependencyEdge]
        public let external: [String: Int]
    }

    public static func resolve(files: [CodeFile]) -> Resolution {
        var edges: [DependencyEdge] = []
        var seen = Set<DependencyEdge>()
        var external: [String: Int] = [:]

        // Lookup tables.
        var pathsWithoutExtension: [String: [String]] = [:] // "a/b/c" -> ["a/b/c.swift"]
        var directories: [String: [String]] = [:]           // "a/b" -> files in that dir
        var moduleDirectories = Set<String>()               // directory names, for Swift modules etc.

        for file in files {
            let stripped = stripExtension(file.relativePath)
            pathsWithoutExtension[stripped, default: []].append(file.relativePath)
            let dir = file.directory
            directories[dir, default: []].append(file.relativePath)
            for component in dir.split(separator: "/") {
                moduleDirectories.insert(String(component))
            }
        }

        for file in files {
            for importSpec in file.imports {
                let targets = resolveImport(importSpec,
                                            from: file,
                                            pathsWithoutExtension: pathsWithoutExtension,
                                            directories: directories,
                                            allFiles: files)
                if targets.isEmpty {
                    let isInternalModule = isInternal(importSpec, language: file.language, moduleDirectories: moduleDirectories)
                    if !isInternalModule {
                        let packageName = externalName(for: importSpec, language: file.language)
                        if !packageName.isEmpty {
                            external[packageName, default: 0] += 1
                        }
                    }
                } else {
                    for target in targets where target != file.relativePath {
                        let edge = DependencyEdge(from: file.relativePath, to: target, via: importSpec)
                        if seen.insert(edge).inserted {
                            edges.append(edge)
                        }
                    }
                }
            }
        }

        return Resolution(edges: edges, external: external)
    }

    static func stripExtension(_ path: String) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        if ext.isEmpty { return path }
        return ns.deletingPathExtension
    }

    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(component))
        }
        return parts.joined(separator: "/")
    }

    static func resolveImport(_ spec: String,
                              from file: CodeFile,
                              pathsWithoutExtension: [String: [String]],
                              directories: [String: [String]],
                              allFiles: [CodeFile]) -> [String] {
        let language = file.language
        let dir = file.directory == "." ? "" : file.directory

        func lookup(_ candidate: String) -> [String] {
            let normalized = normalize(candidate)
            if let hits = pathsWithoutExtension[normalized] { return hits }
            if let hits = pathsWithoutExtension[normalized + "/index"] { return hits }
            if let hits = pathsWithoutExtension[normalized + "/__init__"] { return hits }
            if let hits = pathsWithoutExtension[normalized + "/mod"] { return hits }
            return []
        }

        func suffixLookup(_ modulePath: String) -> [String] {
            guard !modulePath.isEmpty else { return [] }
            var hits: [String] = []
            for (stripped, paths) in pathsWithoutExtension {
                if stripped == modulePath || stripped.hasSuffix("/" + modulePath) {
                    hits.append(contentsOf: paths)
                }
            }
            // Prefer the shortest (least nested) matches to avoid ambiguity.
            hits.sort { $0.count < $1.count }
            return Array(hits.prefix(3))
        }

        switch language {
        case .javascript, .typescript, .dart, .ruby, .php, .shell, .lua, .css, .html:
            if spec.hasPrefix(".") || spec.hasPrefix("/") {
                let base = spec.hasPrefix("/") ? String(spec.dropFirst()) : (dir.isEmpty ? spec : dir + "/" + spec)
                let stripped = stripExtension(base)
                let hits = lookup(stripped)
                if !hits.isEmpty { return hits }
                return lookup(base)
            }
            if language == .ruby, spec.contains("/") {
                return suffixLookup(spec)
            }
            if (language == .javascript || language == .typescript), spec.hasPrefix("@/") || spec.hasPrefix("~/") || spec.hasPrefix("src/") {
                let trimmed = spec.hasPrefix("src/") ? spec : String(spec.dropFirst(2))
                let hits = suffixLookup(stripExtension(trimmed))
                if !hits.isEmpty { return hits }
            }
            if language == .dart, spec.hasPrefix("package:") {
                let parts = spec.dropFirst("package:".count).split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    return suffixLookup(stripExtension("lib/" + String(parts[1])))
                }
            }
            return []

        case .python:
            if spec.hasPrefix(".") {
                let dots = spec.prefix { $0 == "." }.count
                let remainder = spec.dropFirst(dots).replacingOccurrences(of: ".", with: "/")
                var baseParts = dir.isEmpty ? [] : dir.split(separator: "/").map(String.init)
                for _ in 1..<max(dots, 1) {
                    if !baseParts.isEmpty { baseParts.removeLast() }
                }
                let base = (baseParts + (remainder.isEmpty ? [] : [String(remainder)])).joined(separator: "/")
                return lookup(base)
            }
            let modulePath = spec.replacingOccurrences(of: ".", with: "/")
            let direct = lookup(modulePath)
            if !direct.isEmpty { return direct }
            return suffixLookup(modulePath)

        case .go:
            // Match the trailing path of the import against a project directory.
            let parts = spec.split(separator: "/").map(String.init)
            for start in parts.indices {
                let suffix = parts[start...].joined(separator: "/")
                for (directory, paths) in directories where directory == suffix || directory.hasSuffix("/" + suffix) {
                    return paths.filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
                }
            }
            return []

        case .rust:
            var parts = spec.split(separator: "::").map(String.init)
            guard let first = parts.first else { return [] }
            if first == "crate" {
                parts.removeFirst()
            } else if first == "self" || first == "super" {
                return []
            } else {
                return []
            }
            while !parts.isEmpty {
                let candidate = "src/" + parts.joined(separator: "/")
                let hits = lookup(candidate)
                if !hits.isEmpty { return hits }
                let anyHits = suffixLookup(parts.joined(separator: "/"))
                if !anyHits.isEmpty { return anyHits }
                parts.removeLast()
            }
            return []

        case .java, .kotlin, .scala:
            var modulePath = spec.replacingOccurrences(of: ".", with: "/")
            if modulePath.hasSuffix("/*") { modulePath.removeLast(2) }
            return suffixLookup(modulePath)

        case .csharp:
            let modulePath = spec.replacingOccurrences(of: ".", with: "/")
            return suffixLookup(modulePath)

        case .c, .cpp, .objectiveC:
            let local = dir.isEmpty ? spec : dir + "/" + spec
            let hits = lookup(stripExtension(local))
            if !hits.isEmpty { return hits.filter { $0.hasSuffix(spec) || $0 == normalize(local) } }
            let exact = pathsWithoutExtension[stripExtension(spec)]
            if let exact, !exact.isEmpty { return exact }
            return suffixLookup(stripExtension(spec)).filter { ($0 as NSString).lastPathComponent == (spec as NSString).lastPathComponent }

        case .swift:
            // Swift imports are modules, not files; resolved as internal/external elsewhere.
            return []

        default:
            return []
        }
    }

    static func isInternal(_ spec: String, language: Language, moduleDirectories: Set<String>) -> Bool {
        switch language {
        case .swift:
            return moduleDirectories.contains(spec)
        case .rust:
            let first = spec.split(separator: "::").first.map(String.init) ?? spec
            return first == "crate" || first == "self" || first == "super"
        case .javascript, .typescript:
            return spec.hasPrefix(".") || spec.hasPrefix("/") || spec.hasPrefix("@/") || spec.hasPrefix("~/")
        case .python:
            return spec.hasPrefix(".")
        case .c, .cpp, .objectiveC:
            return false
        default:
            return false
        }
    }

    /// Reduces an import specifier to the package it belongs to, for the external dependency list.
    static func externalName(for spec: String, language: Language) -> String {
        switch language {
        case .javascript, .typescript:
            if spec.hasPrefix(".") || spec.hasPrefix("/") { return "" }
            let parts = spec.split(separator: "/")
            if spec.hasPrefix("@"), parts.count >= 2 {
                return String(parts[0]) + "/" + String(parts[1])
            }
            if spec.hasPrefix("node:") { return "node (built-in)" }
            return String(parts.first ?? Substring(spec))
        case .python:
            return String(spec.split(separator: ".").first ?? Substring(spec))
        case .go:
            let parts = spec.split(separator: "/")
            if let first = parts.first, first.contains(".") {
                return parts.prefix(3).joined(separator: "/")
            }
            return "stdlib: " + spec
        case .rust:
            return String(spec.split(separator: "::").first ?? Substring(spec))
        case .java, .kotlin, .scala, .csharp:
            let parts = spec.split(separator: ".")
            return parts.prefix(min(3, parts.count)).joined(separator: ".")
        case .c, .cpp, .objectiveC:
            if spec.contains("/") {
                return String(spec.split(separator: "/").first ?? Substring(spec))
            }
            return spec
        case .ruby, .php, .dart, .lua, .shell:
            if spec.hasPrefix(".") || spec.hasPrefix("/") { return "" }
            return String(spec.split(separator: "/").first ?? Substring(spec))
        default:
            return spec
        }
    }
}

// MARK: - Entry points

public enum EntryPointDetector {

    private struct Rule {
        let languages: Set<Language>
        let regex: NSRegularExpression
        let reason: String
    }

    private static let rules: [Rule] = [
        Rule(languages: [.swift], regex: Rx.make(#"^\s*@main\b"#, options: [.anchorsMatchLines]), reason: "Swift @main entry point"),
        Rule(languages: [.swift], regex: Rx.make(#"NSApplicationMain|UIApplicationMain"#), reason: "Application main"),
        Rule(languages: [.python], regex: Rx.make(#"if\s+__name__\s*==\s*['"]__main__['"]"#), reason: "Python script entry (__main__ guard)"),
        Rule(languages: [.go], regex: Rx.make(#"^func\s+main\s*\("#, options: [.anchorsMatchLines]), reason: "Go main()"),
        Rule(languages: [.rust], regex: Rx.make(#"^\s*(?:pub\s+)?(?:async\s+)?fn\s+main\s*\("#, options: [.anchorsMatchLines]), reason: "Rust main()"),
        Rule(languages: [.java, .kotlin, .scala], regex: Rx.make(#"public\s+static\s+void\s+main\s*\(|^\s*fun\s+main\s*\(|def\s+main\s*\("#, options: [.anchorsMatchLines]), reason: "JVM main()"),
        Rule(languages: [.c, .cpp, .objectiveC], regex: Rx.make(#"^\s*(?:int|void)\s+main\s*\("#, options: [.anchorsMatchLines]), reason: "C/C++ main()"),
        Rule(languages: [.csharp], regex: Rx.make(#"static\s+(?:async\s+)?(?:void|int|Task(?:<int>)?)\s+Main\s*\("#), reason: "C# Main()"),
        Rule(languages: [.javascript, .typescript], regex: Rx.make(#"\.listen\s*\(|createServer\s*\(|ReactDOM\.createRoot|ReactDOM\.render|createApp\s*\(\s*App|new\s+Vue\s*\(|bootstrapApplication|NestFactory\.create"#), reason: "Server / UI bootstrap"),
        Rule(languages: [.ruby], regex: Rx.make(#"Rails\.application|Sinatra::Base|run\s+\w+"#), reason: "Ruby application bootstrap"),
        Rule(languages: [.php], regex: Rx.make(#"\$app->run\(|\$kernel->handle\(|Application::configure|->handleRequest\("#), reason: "PHP front controller"),
        Rule(languages: [.dart], regex: Rx.make(#"^\s*void\s+main\s*\("#, options: [.anchorsMatchLines]), reason: "Dart main()"),
    ]

    private static let entryFileNames: [String: String] = [
        "main.swift": "Swift top-level entry",
        "main.py": "Conventional Python entry",
        "app.py": "Conventional Python web app entry",
        "manage.py": "Django management entry",
        "wsgi.py": "WSGI entry",
        "asgi.py": "ASGI entry",
        "index.js": "Conventional JS entry",
        "index.ts": "Conventional TS entry",
        "main.js": "Conventional JS entry",
        "main.ts": "Conventional TS entry",
        "server.js": "Server entry",
        "server.ts": "Server entry",
        "app.js": "App entry",
        "app.ts": "App entry",
        "cli.js": "CLI entry",
        "cli.ts": "CLI entry",
        "index.html": "Web page entry",
        "main.go": "Go main package",
        "main.rs": "Rust binary entry",
        "lib.rs": "Rust library root",
        "mod.rs": "Rust module root",
        "program.cs": "C# program entry",
        "main.dart": "Dart/Flutter entry",
        "config.ru": "Rack entry",
        "dockerfile": "Container entry",
        "makefile": "Build entry",
        "package.swift": "Swift package manifest",
        "package.json": "Node package manifest",
        "cargo.toml": "Rust crate manifest",
        "go.mod": "Go module manifest",
        "pyproject.toml": "Python project manifest",
    ]

    public static func detect(files: [CodeFile]) -> [EntryPoint] {
        var results: [EntryPoint] = []
        var seen = Set<String>()
        for file in files {
            let lower = file.fileName.lowercased()
            if let reason = entryFileNames[lower] {
                if seen.insert(file.relativePath).inserted {
                    results.append(EntryPoint(path: file.relativePath, reason: reason))
                }
                continue
            }
            for rule in rules where rule.languages.contains(file.language) {
                if Rx.firstMatch(rule.regex, in: file.content) != nil {
                    if seen.insert(file.relativePath).inserted {
                        results.append(EntryPoint(path: file.relativePath, reason: rule.reason))
                    }
                    break
                }
            }
        }
        return results.sorted { $0.path < $1.path }
    }
}
