import Foundation
import SwiftUI
import Combine
import AppKit
import CodeScopeCore

// MARK: - View-model types

enum CenterTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case code = "Code"
    case graph = "Graph"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "doc.text.magnifyingglass"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

enum AssistantTab: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case optimize = "Optimize"
    var id: String { rawValue }
}

enum AnalysisPhase: Equatable {
    case idle
    case explaining
    case reporting
    case done
    case failed(String)

    var isRunning: Bool { self == .explaining || self == .reporting }
}

enum OptimizePhase: Equatable {
    case idle
    case running
    case done
    case failed(String)
}

struct ActivityEntry: Identifiable, Equatable {
    enum Kind: Equatable { case status, tool, result, error, fallback }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String

    var systemImage: String {
        switch kind {
        case .status: return "info.circle"
        case .tool: return "wrench.and.screwdriver"
        case .result: return "arrow.turn.down.right"
        case .error: return "exclamationmark.triangle"
        case .fallback: return "arrow.triangle.swap"
        }
    }
}

struct ProposalItem: Identifiable, Equatable {
    var edit: ProposedEdit
    var preview: EditPreview
    var isSelected: Bool
    var changeSetSummary: String

    var id: UUID { edit.id }

    static func == (lhs: ProposalItem, rhs: ProposalItem) -> Bool {
        lhs.edit == rhs.edit && lhs.isSelected == rhs.isSelected && lhs.preview.error == rhs.preview.error
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, system }
    let id = UUID()
    let role: Role
    var text: String
    var thinking: String = ""
    var isStreaming: Bool = false
    var activity: [ActivityEntry] = []
    var proposalCount: Int = 0
}

struct SavedAnalysis: Codable {
    var narrative: String
    var report: ArchitectureReport?
    var date: Date
    var model: String?
}

/// Coalesces rapid streaming deltas into a few UI updates per second.
@MainActor
final class StreamThrottle {
    private var pending = ""
    private var scheduled = false
    private let interval: TimeInterval
    private let flush: (String) -> Void

    init(interval: TimeInterval = 0.06, flush: @escaping (String) -> Void) {
        self.interval = interval
        self.flush = flush
    }

    func append(_ text: String) {
        pending += text
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated {
                self.fire()
            }
        }
    }

    func finish() {
        fire()
    }

    private func fire() {
        scheduled = false
        let text = pending
        pending = ""
        if !text.isEmpty {
            flush(text)
        }
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    let settings: AppSettings

    // Project
    @Published var projectURL: URL?
    @Published var index: ProjectIndex?
    @Published var isScanning = false
    @Published var scanStatus = ""
    @Published var errorMessage: String?
    @Published var selectedFilePath: String?
    @Published var centerTab: CenterTab = .overview
    @Published var assistantTab: AssistantTab = .ask
    @Published var contextSummary: String = ""

    // Analysis
    @Published var analysisPhase: AnalysisPhase = .idle
    @Published var narrative = ""
    @Published var report: ArchitectureReport?
    @Published var analysisThinking = ""
    @Published var analysisActivity: [ActivityEntry] = []
    @Published var analysisUsage = TokenUsage()
    @Published var analysisDate: Date?
    @Published var analysisModel: String?
    @Published var reportProgressCharacters = 0

    // Chat
    @Published var chatMessages: [ChatMessage] = []
    @Published var chatInput = ""
    @Published var isChatting = false

    // Optimise
    @Published var optimizePrompt = ""
    @Published var optimizeFocusFiles: [String] = []
    @Published var optimizePhase: OptimizePhase = .idle
    @Published var optimizeTranscript = ""
    @Published var optimizeThinking = ""
    @Published var optimizeActivity: [ActivityEntry] = []
    @Published var optimizeUsage = TokenUsage()
    @Published var proposals: [ProposalItem] = []
    @Published var lastReceipt: ApplyReceipt?
    @Published var applyMessage: String?

    private var session: CodebaseSession?
    private var sessionConfiguration: ClaudeConfiguration?
    private var sessionBudget: Int?
    private var sessionIndexDate: Date?
    private var chatEngine: ChatEngine?
    private var currentTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private lazy var narrativeThrottle = StreamThrottle { [weak self] text in self?.narrative += text }
    private lazy var analysisThinkingThrottle = StreamThrottle { [weak self] text in self?.analysisThinking += text }
    private lazy var optimizeThrottle = StreamThrottle { [weak self] text in self?.optimizeTranscript += text }
    private lazy var optimizeThinkingThrottle = StreamThrottle { [weak self] text in self?.optimizeThinking += text }
    private lazy var chatThrottle = StreamThrottle { [weak self] text in
        guard let self, let last = self.chatMessages.indices.last, self.chatMessages[last].role == .assistant else { return }
        self.chatMessages[last].text += text
    }
    private lazy var chatThinkingThrottle = StreamThrottle { [weak self] text in
        guard let self, let last = self.chatMessages.indices.last, self.chatMessages[last].role == .assistant else { return }
        self.chatMessages[last].thinking += text
    }

    init(settings: AppSettings) {
        self.settings = settings
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Settings changes are applied lazily when the next session is prepared.
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let claudeError = error as? ClaudeError, case .cancelled = claudeError { return true }
        return false
    }

    var isBusy: Bool {
        isScanning || analysisPhase.isRunning || isChatting || optimizePhase == .running
    }

    var selectedFile: CodeFile? {
        guard let path = selectedFilePath else { return nil }
        return index?.file(at: path)
    }

    // MARK: Project lifecycle

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the root folder of the application you want CodeScope to analyze."
        if panel.runModal() == .OK, let url = panel.url {
            openProject(at: url)
        }
    }

    func openProject(at url: URL) {
        cancelCurrentTask()
        projectURL = url
        index = nil
        selectedFilePath = nil
        resetAnalysisState()
        chatMessages = []
        chatEngine = nil
        proposals = []
        lastReceipt = nil
        applyMessage = nil
        optimizeTranscript = ""
        optimizePhase = .idle
        optimizeFocusFiles = []
        settings.noteRecentProject(url.path)
        rescan(resetConversation: false)
        loadSavedAnalysis()
    }

    func closeProject() {
        cancelCurrentTask()
        projectURL = nil
        index = nil
        session = nil
        chatEngine = nil
        selectedFilePath = nil
        resetAnalysisState()
        chatMessages = []
        proposals = []
        lastReceipt = nil
    }

    /// Re-indexes the project from disk. The Claude conversation is reset because the cached
    /// codebase snapshot (part of the system prompt) changes with the files.
    func rescan(resetConversation: Bool = true) {
        guard let url = projectURL else { return }
        isScanning = true
        scanStatus = "Indexing…"
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            guard progress.filesIndexed % 20 == 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scanStatus = "Indexed \(progress.filesIndexed) files — \(progress.currentPath)"
                }
            }
        }
        Task { [weak self] in
            let result: Result<ProjectIndex, Error> = await Task.detached(priority: .userInitiated) { () -> Result<ProjectIndex, Error> in
                do {
                    return .success(try ProjectScanner.scan(root: url, progress: onProgress))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.isScanning = false
            switch result {
            case .success(let newIndex):
                self.index = newIndex
                self.scanStatus = "\(newIndex.files.count) files, \(newIndex.totalLines.formattedWithSeparator) lines"
                self.session = nil
                if resetConversation, !self.chatMessages.isEmpty {
                    self.chatEngine = nil
                    self.chatMessages.append(ChatMessage(role: .system, text: "Project re-indexed after changes; the conversation context was refreshed."))
                } else if resetConversation {
                    self.chatEngine = nil
                }
                self.refreshProposalPreviews()
                self.updateContextSummary()
                if let selected = self.selectedFilePath, newIndex.file(at: selected) == nil {
                    self.selectedFilePath = nil
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateContextSummary() {
        guard let index else {
            contextSummary = ""
            return
        }
        let context = ContextBuilder.build(index: index, tokenBudget: settings.tokenBudget)
        contextSummary = context.coverageDescription
    }

    private func resetAnalysisState() {
        analysisPhase = .idle
        narrative = ""
        report = nil
        analysisThinking = ""
        analysisActivity = []
        analysisUsage = TokenUsage()
        analysisDate = nil
        analysisModel = nil
        reportProgressCharacters = 0
    }

    func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: Session

    private func prepareSession() -> CodebaseSession? {
        guard let index else {
            errorMessage = "Open a project first."
            return nil
        }
        guard settings.hasAPIKey else {
            errorMessage = ClaudeError.missingAPIKey.localizedDescription
            return nil
        }
        let configuration = settings.clientConfiguration
        if let session,
           sessionConfiguration == configuration,
           sessionBudget == settings.tokenBudget,
           sessionIndexDate == index.createdAt {
            return session
        }
        let client = ClaudeClient(configuration: configuration)
        let newSession = CodebaseSession(client: client, index: index, tokenBudget: settings.tokenBudget)
        session = newSession
        sessionConfiguration = configuration
        sessionBudget = settings.tokenBudget
        sessionIndexDate = index.createdAt
        contextSummary = newSession.context.coverageDescription
        // Preserve the chat transcript across model/effort changes; the API drops thinking blocks
        // the new model cannot read.
        let history = chatEngine?.messageHistory ?? []
        chatEngine = ChatEngine(session: newSession, history: history)
        return newSession
    }

    // MARK: Analysis

    func analyze() {
        guard let session = prepareSession() else { return }
        cancelCurrentTask()
        resetAnalysisState()
        analysisPhase = .explaining
        analysisActivity.append(ActivityEntry(kind: .status, text: "Sending codebase snapshot (\(session.context.coverageDescription))"))

        let engine = AnalysisEngine(session: session)
        let handler: @Sendable (AgentEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleAnalysisEvent(event)
                }
            }
        }
        let reportHandler: @Sendable (AgentEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleReportEvent(event)
                }
            }
        }

        currentTask = Task { [weak self] in
            do {
                let explained = try await engine.explain(onEvent: handler)
                guard let self, !Task.isCancelled else { return }
                self.narrativeThrottle.finish()
                self.analysisThinkingThrottle.finish()
                self.narrative = explained.narrative
                self.analysisUsage.add(explained.usage)
                self.analysisModel = explained.model
                self.analysisPhase = .reporting
                self.analysisActivity.append(ActivityEntry(kind: .status, text: "Narrative complete; building structured report…"))

                let reported = try await engine.report(narrative: explained.narrative, onEvent: reportHandler)
                guard !Task.isCancelled else { return }
                self.report = reported.report
                self.analysisUsage.add(reported.usage)
                self.analysisDate = Date()
                self.analysisPhase = .done
                self.analysisActivity.append(ActivityEntry(kind: .status, text: "Analysis complete."))
                self.saveAnalysis()
            } catch is CancellationError {
                self?.finishCancelledAnalysis()
            } catch ClaudeError.cancelled {
                self?.finishCancelledAnalysis()
            } catch {
                guard let self else { return }
                self.narrativeThrottle.finish()
                self.analysisThinkingThrottle.finish()
                if case .reporting = self.analysisPhase, !self.narrative.isEmpty {
                    // Keep the narrative even if the structured report failed.
                    self.analysisPhase = .done
                    self.analysisDate = Date()
                    self.analysisActivity.append(ActivityEntry(kind: .error, text: "Structured report failed: \(error.localizedDescription)"))
                    self.saveAnalysis()
                } else {
                    self.analysisPhase = .failed(error.localizedDescription)
                    self.analysisActivity.append(ActivityEntry(kind: .error, text: error.localizedDescription))
                }
            }
        }
    }

    private func finishCancelledAnalysis() {
        narrativeThrottle.finish()
        analysisThinkingThrottle.finish()
        if narrative.isEmpty {
            analysisPhase = .idle
        } else {
            analysisPhase = .done
            analysisActivity.append(ActivityEntry(kind: .status, text: "Cancelled; keeping the partial narrative."))
        }
    }

    private func handleAnalysisEvent(_ event: AgentEvent) {
        switch event {
        case .text(let text):
            narrativeThrottle.append(text)
        case .thinking(let text):
            analysisThinkingThrottle.append(text)
        case .status(let text):
            analysisActivity.append(ActivityEntry(kind: .status, text: text))
        case .toolCall(let name, let summary):
            analysisActivity.append(ActivityEntry(kind: .tool, text: "\(name) \(summary)"))
        case .toolResult(let name, let preview, let isError):
            analysisActivity.append(ActivityEntry(kind: isError ? .error : .result, text: "\(name) → \(preview)"))
        case .fallback(let from, let to):
            analysisActivity.append(ActivityEntry(kind: .fallback, text: "\(from) declined; continued on \(to)"))
        case .usage:
            break
        }
    }

    private func handleReportEvent(_ event: AgentEvent) {
        switch event {
        case .text(let text):
            reportProgressCharacters += text.count
        case .status(let text):
            analysisActivity.append(ActivityEntry(kind: .status, text: text))
        case .fallback(let from, let to):
            analysisActivity.append(ActivityEntry(kind: .fallback, text: "\(from) declined; continued on \(to)"))
        default:
            break
        }
    }

    // MARK: Saved analysis

    private var analysisFileURL: URL? {
        projectURL?.appendingPathComponent(".codescope/analysis.json")
    }

    private func saveAnalysis() {
        guard let url = analysisFileURL else { return }
        let saved = SavedAnalysis(narrative: narrative, report: report, date: analysisDate ?? Date(), model: analysisModel)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(saved).write(to: url)
        } catch {
            analysisActivity.append(ActivityEntry(kind: .error, text: "Could not save analysis: \(error.localizedDescription)"))
        }
    }

    private func loadSavedAnalysis() {
        guard let url = analysisFileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(SavedAnalysis.self, from: data) else { return }
        narrative = saved.narrative
        report = saved.report
        analysisDate = saved.date
        analysisModel = saved.model
        analysisPhase = .done
        analysisActivity = [ActivityEntry(kind: .status, text: "Loaded saved analysis from \(saved.date.formatted(date: .abbreviated, time: .shortened)).")]
    }

    // MARK: Chat

    func sendChat() {
        let question = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isChatting else { return }
        guard prepareSession() != nil, let engine = chatEngine else { return }
        chatInput = ""
        chatMessages.append(ChatMessage(role: .user, text: question))
        chatMessages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        isChatting = true

        let handler: @Sendable (AgentEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleChatEvent(event)
                }
            }
        }

        currentTask = Task { [weak self] in
            do {
                let result = try await engine.ask(question, onEvent: handler)
                guard let self else { return }
                self.chatThrottle.finish()
                self.chatThinkingThrottle.finish()
                if let last = self.chatMessages.indices.last {
                    self.chatMessages[last].text = result.message.text.isEmpty ? self.chatMessages[last].text : result.message.text
                    self.chatMessages[last].isStreaming = false
                    self.chatMessages[last].proposalCount = result.proposals.count
                }
                if !result.proposals.isEmpty, let root = self.projectURL {
                    let items = result.proposals.map { edit in
                        ProposalItem(edit: edit, preview: EditApplier.preview(edit, root: root), isSelected: true, changeSetSummary: "From conversation")
                    }
                    self.proposals.append(contentsOf: items)
                    self.applyMessage = "\(items.count) proposed edit(s) from the conversation are ready to review in Optimize."
                }
                self.isChatting = false
            } catch {
                guard let self else { return }
                self.chatThrottle.finish()
                self.chatThinkingThrottle.finish()
                if let last = self.chatMessages.indices.last, self.chatMessages[last].role == .assistant {
                    self.chatMessages[last].isStreaming = false
                    let isCancel = AppState.isCancellation(error)
                    if self.chatMessages[last].text.isEmpty {
                        self.chatMessages[last].text = isCancel ? "_Cancelled._" : "⚠️ \(error.localizedDescription)"
                    } else if !isCancel {
                        self.chatMessages[last].activity.append(ActivityEntry(kind: .error, text: error.localizedDescription))
                    }
                }
                self.isChatting = false
            }
        }
    }

    private func handleChatEvent(_ event: AgentEvent) {
        guard let last = chatMessages.indices.last, chatMessages[last].role == .assistant else { return }
        switch event {
        case .text(let text):
            chatThrottle.append(text)
        case .thinking(let text):
            chatThinkingThrottle.append(text)
        case .status(let text):
            chatMessages[last].activity.append(ActivityEntry(kind: .status, text: text))
        case .toolCall(let name, let summary):
            chatMessages[last].activity.append(ActivityEntry(kind: .tool, text: "\(name) \(summary)"))
        case .toolResult(let name, let preview, let isError):
            if isError {
                chatMessages[last].activity.append(ActivityEntry(kind: .error, text: "\(name) → \(preview)"))
            }
        case .fallback(let from, let to):
            chatMessages[last].activity.append(ActivityEntry(kind: .fallback, text: "\(from) declined; continued on \(to)"))
        case .usage:
            break
        }
    }

    func clearChat() {
        cancelCurrentTask()
        isChatting = false
        chatMessages = []
        chatEngine?.reset()
    }

    // MARK: Optimisation

    func useOpportunity(_ opportunity: ArchitectureReport.Opportunity) {
        optimizePrompt = opportunity.suggestedPrompt.isEmpty ? "\(opportunity.title): \(opportunity.detail)" : opportunity.suggestedPrompt
        optimizeFocusFiles = Array(opportunity.files.prefix(8))
        assistantTab = .optimize
    }

    func usePreset(_ prompt: String) {
        optimizePrompt = prompt
    }

    func addSelectedFileToFocus() {
        guard let path = selectedFilePath, index?.file(at: path) != nil, !optimizeFocusFiles.contains(path) else { return }
        optimizeFocusFiles.append(path)
    }

    func removeFocusFile(_ path: String) {
        optimizeFocusFiles.removeAll { $0 == path }
    }

    func runOptimization() {
        let instruction = optimizePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            errorMessage = "Describe what you want to optimize first."
            return
        }
        guard let session = prepareSession() else { return }
        cancelCurrentTask()
        optimizePhase = .running
        optimizeTranscript = ""
        optimizeThinking = ""
        optimizeActivity = [ActivityEntry(kind: .status, text: "Starting optimization with \(settings.model) at \(settings.effort.displayName) effort")]
        optimizeUsage = TokenUsage()
        applyMessage = nil

        let engine = OptimizationEngine(session: session)
        let focus = optimizeFocusFiles
        let handler: @Sendable (AgentEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleOptimizeEvent(event)
                }
            }
        }

        currentTask = Task { [weak self] in
            do {
                let result = try await engine.run(instruction: instruction, focusFiles: focus, onEvent: handler)
                guard let self else { return }
                self.optimizeThrottle.finish()
                self.optimizeThinkingThrottle.finish()
                self.optimizeTranscript = result.summary.isEmpty ? self.optimizeTranscript : result.summary
                self.optimizeUsage = result.usage
                if let root = self.projectURL {
                    var items: [ProposalItem] = []
                    for changeSet in result.changeSets {
                        for edit in changeSet.edits {
                            items.append(ProposalItem(edit: edit,
                                                      preview: EditApplier.preview(edit, root: root),
                                                      isSelected: true,
                                                      changeSetSummary: changeSet.summary))
                        }
                    }
                    self.proposals.append(contentsOf: items)
                    self.optimizeActivity.append(ActivityEntry(kind: .status, text: items.isEmpty ? "Finished without proposing edits." : "Proposed \(items.count) edit(s)."))
                }
                self.optimizePhase = .done
            } catch {
                guard let self else { return }
                self.optimizeThrottle.finish()
                self.optimizeThinkingThrottle.finish()
                if AppState.isCancellation(error) {
                    self.optimizePhase = .idle
                    self.optimizeActivity.append(ActivityEntry(kind: .status, text: "Cancelled."))
                } else {
                    self.optimizePhase = .failed(error.localizedDescription)
                    self.optimizeActivity.append(ActivityEntry(kind: .error, text: error.localizedDescription))
                }
            }
        }
    }

    private func handleOptimizeEvent(_ event: AgentEvent) {
        switch event {
        case .text(let text):
            optimizeThrottle.append(text)
        case .thinking(let text):
            optimizeThinkingThrottle.append(text)
        case .status(let text):
            optimizeActivity.append(ActivityEntry(kind: .status, text: text))
        case .toolCall(let name, let summary):
            optimizeActivity.append(ActivityEntry(kind: .tool, text: "\(name) \(summary)"))
        case .toolResult(let name, let preview, let isError):
            optimizeActivity.append(ActivityEntry(kind: isError ? .error : .result, text: "\(name) → \(preview)"))
        case .fallback(let from, let to):
            optimizeActivity.append(ActivityEntry(kind: .fallback, text: "\(from) declined; continued on \(to)"))
        case .usage(let usage):
            optimizeUsage = usage
        }
    }

    func toggleProposal(_ id: UUID) {
        guard let indexOfItem = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[indexOfItem].isSelected.toggle()
    }

    func setAllProposals(selected: Bool) {
        for i in proposals.indices {
            proposals[i].isSelected = selected
        }
    }

    func removeProposal(_ id: UUID) {
        proposals.removeAll { $0.id == id }
    }

    func clearProposals() {
        proposals = []
    }

    private func refreshProposalPreviews() {
        guard let root = projectURL else { return }
        for i in proposals.indices {
            proposals[i].preview = EditApplier.preview(proposals[i].edit, root: root)
        }
    }

    var selectedApplicableProposals: [ProposalItem] {
        proposals.filter { $0.isSelected && $0.preview.isApplicable }
    }

    func applySelectedProposals() {
        guard let root = projectURL else { return }
        let selected = selectedApplicableProposals
        guard !selected.isEmpty else {
            errorMessage = "No applicable edits are selected."
            return
        }
        let summary = Set(selected.map { $0.changeSetSummary }).joined(separator: "; ")
        do {
            let receipt = try EditApplier.apply(selected.map { $0.edit }, root: root, summary: summary)
            lastReceipt = receipt
            let appliedIDs = Set(selected.map { $0.id })
            proposals.removeAll { appliedIDs.contains($0.id) }
            applyMessage = "Applied \(receipt.entries.count) edit(s). Backups: \(receipt.backupPath)"
            rescan()
        } catch {
            errorMessage = "Applying edits failed: \(error.localizedDescription)"
        }
    }

    func revertLastApply() {
        guard let receipt = lastReceipt else { return }
        do {
            try EditApplier.revert(receipt)
            lastReceipt = nil
            applyMessage = "Reverted \(receipt.entries.count) file(s) from the last apply."
            rescan()
        } catch {
            errorMessage = "Revert failed: \(error.localizedDescription)"
        }
    }
}
