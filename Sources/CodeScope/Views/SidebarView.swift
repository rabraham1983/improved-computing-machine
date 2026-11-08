import SwiftUI
import CodeScopeCore

struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
    let language: Language?
    let lines: Int

    static func buildTree(files: [CodeFile]) -> [FileNode] {
        final class Builder {
            var children: [String: Builder] = [:]
            var file: CodeFile?
        }
        let root = Builder()
        for file in files {
            var node = root
            let parts = file.relativePath.split(separator: "/").map(String.init)
            for part in parts {
                if let child = node.children[part] {
                    node = child
                } else {
                    let child = Builder()
                    node.children[part] = child
                    node = child
                }
            }
            node.file = file
        }

        func convert(_ builder: Builder, path: String) -> [FileNode] {
            builder.children.keys.sorted { lhs, rhs in
                let lDir = builder.children[lhs]?.file == nil
                let rDir = builder.children[rhs]?.file == nil
                if lDir != rDir { return lDir }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }.map { name in
                let child = builder.children[name]!
                let childPath = path.isEmpty ? name : path + "/" + name
                if let file = child.file {
                    return FileNode(id: file.relativePath, name: name, isDirectory: false, children: nil, language: file.language, lines: file.metrics.totalLines)
                }
                return FileNode(id: childPath, name: name, isDirectory: true, children: convert(child, path: childPath), language: nil, lines: 0)
            }
        }
        return convert(root, path: "")
    }
}

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var tree: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            if let index = appState.index {
                fileList(index)
                Divider()
                footer(index)
            } else if appState.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(appState.scanStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No project open").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Filter files")
        .navigationTitle(appState.index?.name ?? "CodeScope")
        .onAppear { rebuildTree() }
        .onChange(of: appState.index?.createdAt) { _, _ in rebuildTree() }
    }

    @ViewBuilder
    private func fileList(_ index: ProjectIndex) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty {
            List(selection: $appState.selectedFilePath) {
                OutlineGroup(tree, children: \.children) { node in
                    nodeRow(node).tag(node.id)
                }
            }
            .listStyle(.sidebar)
        } else {
            let matches = index.files.filter { $0.relativePath.lowercased().contains(trimmed) }.prefix(300)
            List(selection: $appState.selectedFilePath) {
                ForEach(Array(matches), id: \.relativePath) { file in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.fileName)
                            Text(file.directory).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: iconName(for: file.language))
                    }
                    .tag(file.relativePath)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func rebuildTree() {
        tree = FileNode.buildTree(files: appState.index?.files ?? [])
    }

    private func nodeRow(_ node: FileNode) -> some View {
        HStack {
            Label(node.name, systemImage: node.isDirectory ? "folder" : iconName(for: node.language ?? .other))
                .lineLimit(1)
            Spacer()
            if !node.isDirectory, node.lines > 0 {
                Text("\(node.lines)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func footer(_ index: ProjectIndex) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index.files.count) files · \(index.totalLines.formattedWithSeparator) lines")
                Spacer()
                if appState.isScanning {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            LanguageBar(breakdown: index.languageBreakdown)
                .frame(height: 6)
            let top = index.languageBreakdown.prefix(3).map { $0.language.displayName }.joined(separator: ", ")
            if !top.isEmpty {
                Text(top).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(10)
    }

    static let languageIcons: [Language: String] = [
        .swift: "swift", .python: "chevron.left.forwardslash.chevron.right", .javascript: "curlybraces", .typescript: "curlybraces",
        .markdown: "doc.richtext", .json: "curlybraces.square", .yaml: "list.bullet.rectangle", .xml: "chevron.left.slash.chevron.right",
        .shell: "terminal", .dockerfile: "shippingbox", .makefile: "hammer", .html: "globe", .css: "paintbrush", .sql: "cylinder"
    ]

    private func iconName(for language: Language) -> String {
        SidebarView.languageIcons[language] ?? "doc.text"
    }
}

/// Proportional colour bar of languages by line count.
struct LanguageBar: View {
    let breakdown: [(language: Language, lines: Int)]

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, breakdown.reduce(0) { $0 + $1.lines })
            HStack(spacing: 1) {
                ForEach(Array(breakdown.prefix(6).enumerated()), id: \.offset) { _, entry in
                    Rectangle()
                        .fill(LanguageBar.color(for: entry.language))
                        .frame(width: max(2, geometry.size.width * CGFloat(entry.lines) / CGFloat(total)))
                }
            }
            .clipShape(Capsule())
        }
    }

    static func color(for language: Language) -> Color {
        switch language {
        case .swift: return .orange
        case .python: return .blue
        case .javascript: return .yellow
        case .typescript: return .indigo
        case .go: return .cyan
        case .rust: return .brown
        case .java, .kotlin, .scala: return .red
        case .csharp: return .purple
        case .ruby: return .pink
        case .php: return .mint
        case .c, .cpp, .objectiveC: return .gray
        case .html: return Color(red: 0.9, green: 0.4, blue: 0.2)
        case .css: return .teal
        case .markdown: return .secondary
        default: return .green
        }
    }
}
