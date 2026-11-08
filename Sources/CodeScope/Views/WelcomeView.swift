import SwiftUI
import CodeScopeCore

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "scope")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text("CodeScope").font(.largeTitle.bold())
                        Text("Read, understand and optimize any codebase with Claude.").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Open a project folder", "CodeScope indexes every source file locally: languages, symbols, imports, dependency graph, entry points.")
                    step(2, "Analyze", "Claude reads the indexed snapshot and any files it needs, then explains how the application works and where it can improve.")
                    step(3, "Ask and optimize", "Ask questions, or describe an optimization. Review the proposed diffs and apply them with one click — with backups and undo.")
                }
                HStack(spacing: 12) {
                    Button {
                        appState.openProjectPanel()
                    } label: {
                        Label("Open Project…", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("o")
                    if !settings.hasAPIKey {
                        Button {
                            openSettings()
                        } label: {
                            Label("Add API key", systemImage: "key")
                        }
                        .controlSize(.large)
                    }
                }
                if !settings.hasAPIKey {
                    Text("An Anthropic API key is required for analysis and optimization. Indexing and browsing work without one.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Recent").font(.headline)
                if settings.recentProjects.isEmpty {
                    Text("Projects you open will appear here.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(settings.recentProjects, id: \.self) { path in
                        Button {
                            appState.openProject(at: URL(fileURLWithPath: path, isDirectory: true))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent).font(.callout.weight(.medium))
                                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .padding(24)
            .frame(width: 300)
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
