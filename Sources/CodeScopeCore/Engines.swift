import Foundation

/// Shared state for one opened project: the index, the cached context block, and the client.
public final class CodebaseSession: @unchecked Sendable {
    public let client: ClaudeClient
    public let index: ProjectIndex
    public let context: CodebaseContext
    public let rootURL: URL
    public let executor: CodebaseToolExecutor

    public init(client: ClaudeClient, index: ProjectIndex, tokenBudget: Int = ContextBuilder.defaultTokenBudget) {
        self.client = client
        self.index = index
        self.context = ContextBuilder.build(index: index, tokenBudget: tokenBudget)
        self.rootURL = URL(fileURLWithPath: index.rootPath, isDirectory: true)
        self.executor = CodebaseToolExecutor(index: index)
    }

    /// Thread-safe collector for `propose_edits` calls made during a turn.
    public final class ProposalCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(summary: String, edits: [ProposedEdit])] = []

        public init() {}

        func add(summary: String, edits: [ProposedEdit]) {
            lock.lock()
            storage.append((summary, edits))
            lock.unlock()
        }

        public var changeSets: [(summary: String, edits: [ProposedEdit])] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        public var allEdits: [ProposedEdit] {
            changeSets.flatMap { $0.edits }
        }
    }

    func makeLoop(collector: ProposalCollector?) -> AgentLoop {
        let executor = self.executor
        let root = self.rootURL
        return AgentLoop(client: client, tools: CodebaseToolset.definitions) { call in
            if call.name == CodebaseToolset.proposeEdits {
                guard let collector else {
                    return ToolResult("Edits are not accepted in this mode; describe the change in prose instead.", isError: true)
                }
                let parsed = EditApplier.parse(toolInput: call.input)
                if parsed.edits.isEmpty {
                    return ToolResult("No valid edits were found in the input.", isError: true)
                }
                // Validate hunks against the current files so Claude can fix mismatches immediately.
                var problems: [String] = []
                for edit in parsed.edits {
                    let preview = EditApplier.preview(edit, root: root)
                    if let error = preview.error {
                        problems.append(error)
                    }
                }
                if !problems.isEmpty {
                    return ToolResult("The edits were NOT recorded because some could not be applied:\n- " + problems.joined(separator: "\n- ") + "\nRe-read the affected files with read_file and resend the full propose_edits call with corrected hunks.", isError: true)
                }
                collector.add(summary: parsed.summary, edits: parsed.edits)
                let paths = parsed.edits.map { "\($0.action.rawValue) \($0.path)" }
                return ToolResult("Recorded \(parsed.edits.count) edit(s) for review: " + paths.joined(separator: "; "))
            }
            return executor.execute(call)
        }
    }
}

// MARK: - Analysis

public struct AnalysisResult: Sendable {
    public var narrative: String
    public var report: ArchitectureReport?
    public var usage: TokenUsage
    public var modelUsed: String?
}

public final class AnalysisEngine: @unchecked Sendable {
    public let session: CodebaseSession

    public init(session: CodebaseSession) {
        self.session = session
    }

    /// Step 1: streamed Markdown narrative of how the application works (tools allowed).
    public func explain(onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> (narrative: String, usage: TokenUsage, model: String?) {
        let system = Prompts.system(context: session.context, instructions: Prompts.explainInstructions)
        var messages: [JSONValue] = [["role": "user", "content": .string(Prompts.explainUserMessage)]]
        let loop = session.makeLoop(collector: nil)
        let outcome = try await loop.run(system: system, messages: &messages, onEvent: onEvent)
        return (outcome.finalMessage.text, outcome.totalUsage, outcome.finalMessage.model)
    }

    /// Step 2: structured report via `output_config.format` (no tools used; `tool_choice: none`
    /// keeps the tool list identical so the cached prefix is reused).
    public func report(narrative: String, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> (report: ArchitectureReport, usage: TokenUsage) {
        let system = Prompts.system(context: session.context, instructions: Prompts.reportInstructions)
        let messages: [JSONValue] = [["role": "user", "content": .string(Prompts.reportUserMessage(narrative: narrative))]]

        func attempt(withTools: Bool) async throws -> AssistantMessage {
            let request = MessageRequest(system: system,
                                         messages: messages,
                                         tools: withTools ? CodebaseToolset.json : [],
                                         outputSchema: ArchitectureReport.schema,
                                         toolChoice: withTools ? ["type": "none"] : nil)
            return try await session.client.send(request) { event in
                switch event {
                case .textDelta(let text): onEvent(.text(text))
                case .thinkingDelta(let text): onEvent(.thinking(text))
                case .usage(let usage): onEvent(.usage(usage))
                case .fallback(let from, let to): onEvent(.fallback(from: from, to: to))
                default: break
                }
            }
        }

        var response: AssistantMessage
        do {
            response = try await attempt(withTools: true)
        } catch let error as ClaudeError {
            // Some API versions reject structured output alongside tools; retry without them.
            if case .httpError(let status, _, _) = error, status == 400 {
                onEvent(.status("Retrying structured report without tool definitions…"))
                response = try await attempt(withTools: false)
            } else {
                throw error
            }
        }
        if response.isRefusal {
            throw ClaudeError.refusal(category: response.stopDetails?["category"]?.stringValue,
                                      explanation: response.stopDetails?["explanation"]?.stringValue)
        }
        if response.stopReason == "max_tokens" {
            throw ClaudeError.maxTokensReached
        }
        do {
            let report = try ArchitectureReport.decode(from: response.text)
            return (report, response.usage)
        } catch {
            throw ClaudeError.invalidResponse("The structured report could not be decoded: \(error.localizedDescription)")
        }
    }
}

// MARK: - Chat

public final class ChatEngine: @unchecked Sendable {
    public let session: CodebaseSession
    private let lock = NSLock()
    private var history: [JSONValue] = []

    public init(session: CodebaseSession, history: [JSONValue] = []) {
        self.session = session
        self.history = history
    }

    public var messageHistory: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    public func reset() {
        lock.lock()
        history = []
        lock.unlock()
    }

    /// Sends one user question; the conversation history is kept (append-only) for follow-ups.
    public func ask(_ question: String,
                    allowEdits: Bool = true,
                    onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> (message: AssistantMessage, proposals: [ProposedEdit], usage: TokenUsage) {
        let system = Prompts.system(context: session.context, instructions: Prompts.chatInstructions)
        lock.lock()
        var messages = history
        lock.unlock()
        messages.append(["role": "user", "content": .string(question)])

        let collector = allowEdits ? CodebaseSession.ProposalCollector() : nil
        let loop = session.makeLoop(collector: collector)
        do {
            let outcome = try await loop.run(system: system, messages: &messages, onEvent: onEvent)
            lock.lock()
            history = messages
            lock.unlock()
            return (outcome.finalMessage, collector?.allEdits ?? [], outcome.totalUsage)
        } catch {
            // Keep the history consistent: drop the failed turn entirely.
            throw error
        }
    }
}

// MARK: - Optimisation

public struct OptimizationResult: Sendable {
    public var summary: String
    public var changeSets: [(summary: String, edits: [ProposedEdit])]
    public var usage: TokenUsage
    public var model: String?

    public var allEdits: [ProposedEdit] { changeSets.flatMap { $0.edits } }
}

public final class OptimizationEngine: @unchecked Sendable {
    public let session: CodebaseSession

    public init(session: CodebaseSession) {
        self.session = session
    }

    public func run(instruction: String,
                    focusFiles: [String] = [],
                    onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> OptimizationResult {
        let system = Prompts.system(context: session.context, instructions: Prompts.optimizeInstructions)
        var userText = "Optimization request:\n\n" + instruction
        if !focusFiles.isEmpty {
            userText += "\n\nFocus on these files first: " + focusFiles.joined(separator: ", ")
        }
        var messages: [JSONValue] = [["role": "user", "content": .string(userText)]]
        let collector = CodebaseSession.ProposalCollector()
        let loop = session.makeLoop(collector: collector)
        let outcome = try await loop.run(system: system, messages: &messages, onEvent: onEvent)
        return OptimizationResult(summary: outcome.finalMessage.text,
                                  changeSets: collector.changeSets,
                                  usage: outcome.totalUsage,
                                  model: outcome.finalMessage.model)
    }
}
