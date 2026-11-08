import Foundation

/// Events emitted while an agentic turn runs, for display in the UI.
public enum AgentEvent: Sendable {
    case status(String)
    case text(String)
    case thinking(String)
    case toolCall(name: String, summary: String)
    case toolResult(name: String, preview: String, isError: Bool)
    case fallback(from: String, to: String)
    case usage(TokenUsage)
}

public typealias ToolHandler = @Sendable (ToolUseCall) async -> ToolResult

/// Drives the request → tool_use → tool_result loop until Claude ends its turn. The message
/// history is append-only (never edited), so replayed thinking blocks stay valid and the
/// prompt cache prefix is preserved.
public final class AgentLoop: @unchecked Sendable {
    public let client: ClaudeClient
    public let tools: [ToolDefinition]
    public let handler: ToolHandler
    public let maxIterations: Int

    public init(client: ClaudeClient, tools: [ToolDefinition], maxIterations: Int = 40, handler: @escaping ToolHandler) {
        self.client = client
        self.tools = tools
        self.maxIterations = maxIterations
        self.handler = handler
    }

    public struct Outcome: Sendable {
        public let finalMessage: AssistantMessage
        public let totalUsage: TokenUsage
        public let iterations: Int
    }

    /// Runs one user turn to completion. `messages` must end with a user message; on return it
    /// contains every assistant and tool_result message appended during the turn.
    public func run(system: [JSONValue],
                    messages: inout [JSONValue],
                    outputSchema: JSONValue? = nil,
                    toolChoice: JSONValue? = nil,
                    onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> Outcome {
        var iterations = 0
        var totalUsage = TokenUsage()
        var askedToWrapUp = false

        while true {
            try Task.checkCancellation()
            iterations += 1
            if iterations > maxIterations + 2 {
                throw ClaudeError.tooManyIterations
            }

            let request = MessageRequest(system: system,
                                         messages: messages,
                                         tools: tools.map { $0.json },
                                         outputSchema: outputSchema,
                                         toolChoice: toolChoice)
            let response = try await client.send(request) { event in
                switch event {
                case .textDelta(let text): onEvent(.text(text))
                case .thinkingDelta(let text): onEvent(.thinking(text))
                case .toolUseStarted(let name): onEvent(.status("Calling \(name)…"))
                case .fallback(let from, let to): onEvent(.fallback(from: from, to: to))
                case .usage(let usage): onEvent(.usage(usage))
                case .messageStart, .toolInputDelta: break
                }
            }
            totalUsage.add(response.usage)

            let replay = response.replayableContent
            if !replay.isEmpty {
                messages.append(["role": "assistant", "content": .array(replay)])
            }

            switch response.stopReason ?? "end_turn" {
            case "tool_use":
                let calls = response.toolUses
                if calls.isEmpty {
                    return Outcome(finalMessage: response, totalUsage: totalUsage, iterations: iterations)
                }
                var results: [JSONValue] = []
                for call in calls {
                    try Task.checkCancellation()
                    onEvent(.toolCall(name: call.name, summary: AgentLoop.summarize(call)))
                    let result = await handler(call)
                    onEvent(.toolResult(name: call.name, preview: String(result.content.prefix(160)), isError: result.isError))
                    var block: [String: JSONValue] = [
                        "type": "tool_result",
                        "tool_use_id": .string(call.id),
                        "content": .string(result.content)
                    ]
                    if result.isError {
                        block["is_error"] = .bool(true)
                    }
                    results.append(.object(block))
                }
                if iterations >= maxIterations && !askedToWrapUp {
                    askedToWrapUp = true
                    results.append(["type": "text", "text": "You have used the available tool budget. Stop calling tools now and give your final answer with what you have learned."])
                }
                messages.append(["role": "user", "content": .array(results)])

            case "pause_turn":
                continue

            case "refusal":
                throw ClaudeError.refusal(category: response.stopDetails?["category"]?.stringValue,
                                          explanation: response.stopDetails?["explanation"]?.stringValue)

            case "max_tokens":
                throw ClaudeError.maxTokensReached

            default:
                return Outcome(finalMessage: response, totalUsage: totalUsage, iterations: iterations)
            }
        }
    }

    static func summarize(_ call: ToolUseCall) -> String {
        switch call.name {
        case CodebaseToolset.readFile:
            var text = call.input["path"]?.stringValue ?? "?"
            if let start = call.input["start_line"]?.intValue {
                text += " (from line \(start)"
                if let end = call.input["end_line"]?.intValue { text += " to \(end)" }
                text += ")"
            }
            return text
        case CodebaseToolset.searchCode:
            return "/\(call.input["pattern"]?.stringValue ?? "")/" + (call.input["path_prefix"]?.stringValue.map { " in \($0)" } ?? "")
        case CodebaseToolset.listDirectory, CodebaseToolset.listSymbols:
            return call.input["path"]?.stringValue ?? ""
        case CodebaseToolset.proposeEdits:
            let count = call.input["edits"]?.arrayValue?.count ?? 0
            return "\(count) edit\(count == 1 ? "" : "s") — \(call.input["summary"]?.stringValue ?? "")"
        default:
            return call.input.encodedString().prefix(120).description
        }
    }
}
