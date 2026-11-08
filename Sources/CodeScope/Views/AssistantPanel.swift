import SwiftUI
import CodeScopeCore

struct AssistantPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $appState.assistantTab) {
                ForEach(AssistantTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch appState.assistantTab {
            case .ask:
                ChatView()
            case .optimize:
                OptimizeView()
            }
        }
        .disabled(appState.index == nil)
        .overlay {
            if appState.index == nil {
                Text("Open a project to chat with or optimize it.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if appState.chatMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask anything about this codebase").font(.headline)
                                Text("Claude has the indexed snapshot and can read any file. Try:").foregroundStyle(.secondary)
                                ForEach(["Where does the app handle user authentication?", "Walk me through what happens when the main window opens.", "Which functions are the most complex and why?", "Is there any dead code or duplicated logic?"], id: \.self) { suggestion in
                                    Button(suggestion) {
                                        appState.chatInput = suggestion
                                        inputFocused = true
                                    }
                                    .buttonStyle(.link)
                                    .font(.callout)
                                }
                            }
                            .padding(.top, 20)
                        }
                        ForEach(appState.chatMessages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: appState.chatMessages.last?.text.count) { _, _ in
                    if let last = appState.chatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            inputArea
        }
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ask about this codebase… (⌘↩ to send)", text: $appState.chatInput, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { appState.sendChat() }
            HStack {
                Button("Clear", role: .destructive) { appState.clearChat() }
                    .disabled(appState.chatMessages.isEmpty)
                Spacer()
                if appState.isChatting {
                    ProgressView().controlSize(.small)
                    Button("Stop") { appState.cancelCurrentTask() }
                } else {
                    Button {
                        appState.sendChat()
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isBusy)
                }
            }
        }
        .padding(10)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        case .system:
            HStack {
                Spacer()
                Text(message.text).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !message.thinking.isEmpty {
                    DisclosureGroup("Reasoning summary") {
                        Text(message.thinking).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
                if !message.activity.isEmpty {
                    ActivityLogView(entries: message.activity)
                }
                if message.isStreaming {
                    if message.text.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(message.text).textSelection(.enabled)
                    }
                } else {
                    MarkdownView(text: message.text, baseFont: .callout)
                }
                if message.proposalCount > 0 {
                    Button {
                        appState.assistantTab = .optimize
                    } label: {
                        Label("Review \(message.proposalCount) proposed edit\(message.proposalCount == 1 ? "" : "s")", systemImage: "pencil.and.list.clipboard")
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Optimize

struct OptimizeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmRevert = false
    @State private var confirmApply = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                promptSection
                if appState.optimizePhase != .idle || !appState.optimizeTranscript.isEmpty {
                    resultSection
                }
                proposalsSection
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should be optimized?").font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $appState.optimizePrompt)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if appState.optimizePrompt.isEmpty {
                    Text("e.g. “Make the file indexer faster — it re-reads every file on each change” or pick a preset below.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Prompts.optimizationPresets, id: \.title) { preset in
                        Button(preset.title) { appState.usePreset(preset.prompt) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(preset.prompt)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Focus files:").font(.caption).foregroundStyle(.secondary)
                if appState.optimizeFocusFiles.isEmpty {
                    Text("none (whole project)").font(.caption).foregroundStyle(.tertiary)
                }
                Button {
                    appState.addSelectedFileToFocus()
                } label: {
                    Label("Add current file", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(appState.selectedFile == nil)
            }
            if !appState.optimizeFocusFiles.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(appState.optimizeFocusFiles, id: \.self) { path in
                        HStack(spacing: 2) {
                            FileChip(path: path)
                            Button {
                                appState.removeFocusFile(path)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Text("\(settings.model) · \(settings.effort.displayName) effort").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if appState.optimizePhase == .running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { appState.cancelCurrentTask() }
                } else {
                    Button {
                        appState.runOptimization()
                    } label: {
                        Label("Optimize", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(appState.isBusy || appState.optimizePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var resultSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    switch appState.optimizePhase {
                    case .running:
                        Label("Working…", systemImage: "gearshape.2").font(.headline)
                    case .done:
                        Label("Done", systemImage: "checkmark.circle").font(.headline).foregroundStyle(.green)
                    case .failed:
                        Label("Failed", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.red)
                    case .idle:
                        Label("Result", systemImage: "doc.text").font(.headline)
                    }
                    Spacer()
                    if appState.optimizeUsage.outputTokens > 0 {
                        Text("in \(appState.optimizeUsage.totalInput.formattedWithSeparator) · out \(appState.optimizeUsage.outputTokens.formattedWithSeparator) tokens")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if case .failed(let message) = appState.optimizePhase {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
                if !appState.optimizeThinking.isEmpty {
                    DisclosureGroup("Reasoning summary") {
                        Text(appState.optimizeThinking).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !appState.optimizeActivity.isEmpty {
                    DisclosureGroup("Activity (\(appState.optimizeActivity.count))") {
                        ActivityLogView(entries: appState.optimizeActivity)
                    }
                }
                if !appState.optimizeTranscript.isEmpty {
                    Divider()
                    if appState.optimizePhase == .running {
                        Text(appState.optimizeTranscript).font(.callout).textSelection(.enabled)
                    } else {
                        MarkdownView(text: appState.optimizeTranscript, baseFont: .callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var proposalsSection: some View {
        if let message = appState.applyMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if appState.lastReceipt != nil {
                    Button("Revert last apply", role: .destructive) { confirmRevert = true }
                        .controlSize(.small)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        if !appState.proposals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Proposed edits (\(appState.proposals.count))").font(.headline)
                    Spacer()
                    Button("All") { appState.setAllProposals(selected: true) }.controlSize(.small)
                    Button("None") { appState.setAllProposals(selected: false) }.controlSize(.small)
                    Button("Discard", role: .destructive) { appState.clearProposals() }.controlSize(.small)
                }
                ForEach(appState.proposals) { item in
                    ProposalRow(item: item)
                }
                HStack {
                    let selected = appState.selectedApplicableProposals
                    let totalAdded = selected.reduce(0) { $0 + $1.preview.stats.added }
                    let totalRemoved = selected.reduce(0) { $0 + $1.preview.stats.removed }
                    Text("\(selected.count) selected · +\(totalAdded) −\(totalRemoved) lines")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        confirmApply = true
                    } label: {
                        Label("Apply \(selected.count) edit\(selected.count == 1 ? "" : "s")", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || appState.isBusy)
                }
            }
            .confirmationDialog("Apply the selected edits to the project files?", isPresented: $confirmApply, titleVisibility: .visible) {
                Button("Apply") { appState.applySelectedProposals() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Originals are backed up under .codescope/backups inside the project, and you can revert the batch afterwards.")
            }
        }
        EmptyView()
            .confirmationDialog("Revert the last applied batch?", isPresented: $confirmRevert, titleVisibility: .visible) {
                Button("Revert", role: .destructive) { appState.revertLastApply() }
                Button("Cancel", role: .cancel) {}
            }
    }
}

struct ProposalRow: View {
    let item: ProposalItem
    @EnvironmentObject private var appState: AppState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(get: { item.isSelected }, set: { _ in appState.toggleProposal(item.id) }))
                    .labelsHidden()
                    .disabled(!item.preview.isApplicable)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.edit.action.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(actionColor.opacity(0.2))
                            .foregroundStyle(actionColor)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(item.edit.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if item.preview.isApplicable {
                            Text("+\(item.preview.stats.added)").foregroundStyle(.green).font(.caption.monospacedDigit())
                            Text("−\(item.preview.stats.removed)").foregroundStyle(.red).font(.caption.monospacedDigit())
                        }
                    }
                    if !item.edit.explanation.isEmpty {
                        Text(item.edit.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = item.preview.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                Button {
                    appState.removeProposal(item.id)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Discard this edit")
            }
            if expanded {
                DiffView(lines: item.preview.diff)
                    .frame(maxHeight: 360)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionColor: Color {
        switch item.edit.action {
        case .patch: return .blue
        case .replaceFile: return .purple
        case .create: return .green
        case .delete: return .red
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        if lines.isEmpty {
            Text("No changes").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text(line.oldLine.map(String.init) ?? "")
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.tertiary)
                            Text(line.newLine.map(String.init) ?? "")
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.tertiary)
                            Text(marker(line.kind))
                                .frame(width: 16)
                                .foregroundStyle(markerColor(line.kind))
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == .context ? Color.primary : markerColor(line.kind))
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.kind))
                    }
                }
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        }
    }

    private func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private func markerColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }

    private func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return Color.clear
        }
    }
}
