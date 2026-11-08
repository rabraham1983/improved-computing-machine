import SwiftUI
import CodeScopeCore

struct CodeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let file = appState.selectedFile, let index = appState.index {
            CodeFileView(file: file,
                         fanIn: index.fanIn(of: file.relativePath),
                         fanOut: index.fanOut(of: file.relativePath),
                         onAddFocus: { appState.addSelectedFileToFocus(); appState.assistantTab = .optimize })
                .id(file.relativePath)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Select a file in the sidebar to read it.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CodeFileView: View {
    let file: CodeFile
    let fanIn: Int
    let fanOut: Int
    let onAddFocus: () -> Void

    @State private var lines: [String] = []
    @State private var showOutline = true
    @State private var highlightedLine: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                HSplitView {
                    codeArea
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    if showOutline {
                        outline(proxy: proxy)
                            .frame(minWidth: 180, idealWidth: 230, maxWidth: 320)
                    }
                }
            }
        }
        .onAppear { lines = file.content.components(separatedBy: "\n") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.relativePath).font(.headline).lineLimit(1).textSelection(.enabled)
                HStack(spacing: 10) {
                    Text(file.language.displayName)
                    Text("\(file.metrics.totalLines) lines")
                    Text("\(file.metrics.codeLines) code / \(file.metrics.commentLines) comments")
                    if file.language.isCode { Text("complexity \(file.metrics.complexity)") }
                    Text("imported by \(fanIn) · imports \(fanOut)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onAddFocus()
            } label: {
                Label("Focus optimizer here", systemImage: "scope")
            }
            .help("Add this file to the optimizer's focus list")
            Toggle(isOn: $showOutline) {
                Image(systemName: "list.bullet.indent")
            }
            .toggleStyle(.button)
            .help("Show symbol outline")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var codeArea: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(index + 1)")
                            .frame(width: 48, alignment: .trailing)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 12)
                        Text(lines[index].isEmpty ? " " : lines[index])
                            .foregroundStyle(lineColor(lines[index]))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlightedLine == index + 1 ? Color.accentColor.opacity(0.18) : Color.clear)
                    .id(index + 1)
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func lineColor(_ line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashComment = trimmed.hasPrefix("#") && MetricsCalculator.lineCommentPrefix(for: file.language) == "#"
        let dashComment = trimmed.hasPrefix("--") && MetricsCalculator.lineCommentPrefix(for: file.language) == "--"
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("* ") || trimmed == "*/" || hashComment || dashComment {
            return .secondary
        }
        return .primary
    }

    private func outline(proxy: ScrollViewProxy) -> some View {
        List {
            if !file.imports.isEmpty {
                Section("Imports (\(file.imports.count))") {
                    ForEach(file.imports.prefix(40), id: \.self) { module in
                        Text(module).font(.caption).lineLimit(1)
                    }
                }
            }
            Section("Symbols (\(file.symbols.count))") {
                if file.symbols.isEmpty {
                    Text("None detected").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(file.symbols) { symbol in
                    Button {
                        highlightedLine = symbol.line
                        withAnimation { proxy.scrollTo(symbol.line, anchor: .center) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(symbol.kind.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(symbol.kind.isTypeLike ? Color.purple.opacity(0.18) : Color.blue.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(symbol.name).lineLimit(1)
                            Spacer()
                            Text("\(symbol.line)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .padding(.leading, CGFloat(min(symbol.indent, 16)) / 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
    }
}
