import SwiftUI
import CodeScopeCore

struct OverviewView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var section: ReportSection = .narrative

    enum ReportSection: String, CaseIterable, Identifiable {
        case narrative = "How it works"
        case report = "Report"
        case activity = "Activity"
        var id: String { rawValue }
    }

    var body: some View {
        if let index = appState.index {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProjectSummaryCard(index: index)
                    analysisArea
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Open a project to begin.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var analysisArea: some View {
        switch appState.analysisPhase {
        case .idle:
            startCard
        case .explaining, .reporting:
            runningCard
        case .failed(let message):
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Analysis failed", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.red)
                    Text(message).textSelection(.enabled)
                    HStack {
                        Button("Try again") { appState.analyze() }
                        if !appState.analysisActivity.isEmpty {
                            DisclosureGroup("Activity") { ActivityLogView(entries: appState.analysisActivity) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        case .done:
            resultsCard
        }
    }

    private var startCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Understand this application", systemImage: "brain").font(.headline)
                Text("CodeScope sends an indexed snapshot of the project to Claude, lets it read any file it needs, and produces a narrative explanation of how the application works plus a structured report: components, execution flow, data flow, risks and optimization opportunities.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !appState.contextSummary.isEmpty {
                    Text("Snapshot: \(appState.contextSummary)").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        appState.analyze()
                    } label: {
                        Label("Analyze with \(modelDisplayName)", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isBusy)
                    if !settings.hasAPIKey {
                        Text("Add your Anthropic API key in Settings (⌘,) first.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var modelDisplayName: String {
        ClaudeModels.available.first { $0.id == settings.model }?.displayName ?? settings.model
    }

    private var runningCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(appState.analysisPhase == .explaining ? "Reading the codebase and writing the explanation…" : "Building the structured report… (\(appState.reportProgressCharacters.formattedWithSeparator) characters)")
                        .font(.headline)
                    Spacer()
                    Button("Stop") { appState.cancelCurrentTask() }
                }
                if !appState.analysisThinking.isEmpty {
                    DisclosureGroup("Reasoning summary") {
                        Text(appState.analysisThinking).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !appState.analysisActivity.isEmpty {
                    DisclosureGroup("Activity (\(appState.analysisActivity.count))") {
                        ActivityLogView(entries: appState.analysisActivity)
                    }
                }
                if !appState.narrative.isEmpty {
                    Divider()
                    Text(appState.narrative)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Section", selection: $section) {
                    ForEach(ReportSection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
                if let date = appState.analysisDate {
                    Text("Analyzed \(date.formatted(date: .abbreviated, time: .shortened))" + (appState.analysisModel.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    appState.analyze()
                } label: {
                    Label("Re-analyze", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isBusy)
            }
            switch section {
            case .narrative:
                GroupBox {
                    MarkdownView(text: appState.narrative)
                        .padding(6)
                }
            case .report:
                if let report = appState.report {
                    ReportView(report: report)
                } else {
                    GroupBox {
                        Text("The structured report is not available for this analysis. Re-run the analysis to generate it.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
            case .activity:
                GroupBox {
                    VStack(alignment: .leading) {
                        ActivityLogView(entries: appState.analysisActivity)
                        if appState.analysisUsage.totalInput > 0 {
                            Divider()
                            Text("Tokens — input \(appState.analysisUsage.inputTokens.formattedWithSeparator), cache read \(appState.analysisUsage.cacheReadInputTokens.formattedWithSeparator), cache written \(appState.analysisUsage.cacheCreationInputTokens.formattedWithSeparator), output \(appState.analysisUsage.outputTokens.formattedWithSeparator)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct ProjectSummaryCard: View {
    let index: ProjectIndex
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(index.name).font(.title2.bold())
                    Text(index.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                HStack(spacing: 18) {
                    stat("Files", "\(index.files.count)")
                    stat("Lines", index.totalLines.formattedWithSeparator)
                    stat("Symbols", index.totalSymbolCount.formattedWithSeparator)
                    stat("Internal links", "\(index.edges.count)")
                    stat("External deps", "\(index.externalDependencies.count)")
                }
                LanguageBar(breakdown: index.languageBreakdown).frame(height: 8)
                HStack(spacing: 12) {
                    ForEach(Array(index.languageBreakdown.prefix(6).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 4) {
                            Circle().fill(LanguageBar.color(for: entry.language)).frame(width: 8, height: 8)
                            Text("\(entry.language.displayName) \(percent(entry.lines))").font(.caption)
                        }
                    }
                }
                if !index.entryPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Likely entry points").font(.subheadline.weight(.semibold))
                        ForEach(index.entryPoints.prefix(6), id: \.path) { entry in
                            HStack(spacing: 6) {
                                FileChip(path: entry.path)
                                Text(entry.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func percent(_ lines: Int) -> String {
        let total = max(1, index.totalLines)
        return "\(Int((Double(lines) / Double(total) * 100).rounded()))%"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A clickable file path that opens the file in the Code tab.
struct FileChip: View {
    let path: String
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            if appState.index?.file(at: path) != nil {
                appState.selectedFilePath = path
                appState.centerTab = .code
            }
        } label: {
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(path)
    }
}

struct ReportView: View {
    let report: ArchitectureReport
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.title).font(.title2.bold())
                    Text(report.oneLiner).font(.headline).foregroundStyle(.secondary)
                    MarkdownView(text: report.purpose)
                    Divider()
                    LabeledContent("Architecture") { Text(report.architectureStyle) }
                    if !report.languages.isEmpty {
                        LabeledContent("Languages") {
                            Text(report.languages.map { "\($0.name) — \($0.role)" }.joined(separator: "; "))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if !report.entryPoints.isEmpty {
                sectionBox("Entry points", systemImage: "play.circle") {
                    ForEach(Array(report.entryPoints.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 8) {
                            FileChip(path: entry.path)
                            Text(entry.description).font(.callout)
                        }
                    }
                }
            }

            if !report.components.isEmpty {
                sectionBox("Components", systemImage: "square.stack.3d.up") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(Array(report.components.enumerated()), id: \.offset) { _, component in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(component.name).font(.headline)
                                Text(component.responsibility).font(.callout).fixedSize(horizontal: false, vertical: true)
                                if !component.keyTypes.isEmpty {
                                    Text("Key types: " + component.keyTypes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                                if !component.interactsWith.isEmpty {
                                    Text("Talks to: " + component.interactsWith.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                                fileChips(component.files)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            if !report.executionFlow.isEmpty {
                sectionBox("Execution flow", systemImage: "arrow.triangle.turn.up.right.diamond") {
                    ForEach(Array(report.executionFlow.enumerated()), id: \.offset) { offset, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(offset + 1)")
                                .font(.caption.bold())
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.step).font(.subheadline.weight(.semibold))
                                Text(step.description).font(.callout).fixedSize(horizontal: false, vertical: true)
                                fileChips(step.files)
                            }
                        }
                    }
                }
            }

            if !report.dataFlow.isEmpty {
                sectionBox("Data flow", systemImage: "arrow.left.arrow.right") {
                    MarkdownView(text: report.dataFlow, baseFont: .callout)
                }
            }

            if !report.externalDependencies.isEmpty {
                sectionBox("External dependencies", systemImage: "shippingbox") {
                    ForEach(Array(report.externalDependencies.enumerated()), id: \.offset) { _, dependency in
                        HStack(alignment: .top) {
                            Text(dependency.name).font(.callout.weight(.medium)).frame(minWidth: 140, alignment: .leading)
                            Text(dependency.purpose).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !report.buildAndRun.isEmpty {
                sectionBox("Build, run and test", systemImage: "hammer") {
                    MarkdownView(text: report.buildAndRun, baseFont: .callout)
                }
            }

            if !report.concerns.isEmpty {
                sectionBox("Concerns", systemImage: "exclamationmark.triangle") {
                    ForEach(Array(report.concerns.enumerated()), id: \.offset) { _, concern in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                SeverityBadge(level: concern.severity)
                                Text(concern.title).font(.subheadline.weight(.semibold))
                            }
                            Text(concern.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                            fileChips(concern.files)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !report.optimizationOpportunities.isEmpty {
                sectionBox("Optimization opportunities", systemImage: "bolt") {
                    ForEach(Array(report.optimizationOpportunities.enumerated()), id: \.offset) { _, opportunity in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(opportunity.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(opportunity.category).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                                SeverityBadge(level: opportunity.impact, label: "impact")
                                SeverityBadge(level: opportunity.effort, label: "effort", inverted: true)
                            }
                            Text(opportunity.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                            fileChips(opportunity.files)
                            Button {
                                appState.useOpportunity(opportunity)
                            } label: {
                                Label("Optimize this", systemImage: "wand.and.stars")
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            if !report.glossary.isEmpty {
                sectionBox("Glossary", systemImage: "character.book.closed") {
                    ForEach(Array(report.glossary.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top) {
                            Text(entry.term).font(.callout.weight(.medium)).frame(minWidth: 140, alignment: .leading)
                            Text(entry.meaning).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func sectionBox<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private func fileChips(_ files: [String]) -> some View {
        if !files.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(files.prefix(12), id: \.self) { path in
                    FileChip(path: path)
                }
            }
        }
    }
}

struct SeverityBadge: View {
    let level: String
    var label: String? = nil
    var inverted: Bool = false

    var body: some View {
        Text(label.map { "\($0): \(level)" } ?? level)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        let normalized = level.lowercased()
        let high = inverted ? Color.green : Color.red
        let low = inverted ? Color.red : Color.green
        switch normalized {
        case "high": return inverted ? low : high
        case "medium": return .orange
        case "low": return inverted ? high : low
        default: return .secondary
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ActivityLogView: View {
    let entries: [ActivityEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entries.suffix(200)) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: entry.systemImage)
                        .foregroundStyle(entry.kind == .error ? Color.red : Color.secondary)
                        .frame(width: 14)
                    Text(entry.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(entry.kind == .error ? Color.red : Color.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
