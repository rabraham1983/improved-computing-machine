import Foundation

// MARK: - Configuration

public enum Effort: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, medium, high, xhigh, max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

public struct ClaudeModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let note: String

    public init(id: String, displayName: String, note: String) {
        self.id = id
        self.displayName = displayName
        self.note = note
    }
}

public enum ClaudeModels {
    public static let defaultModel = "claude-opus-5-5"

    public static let available: [ClaudeModelInfo] = [
        ClaudeModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", note: "Recommended. Best balance of depth and cost for code analysis."),
        ClaudeModelInfo(id: "claude-fable-5-1", displayName: "Claude Fable 5.1", note: "Most capable model. Higher cost; best for the hardest optimisations."),
        ClaudeModelInfo(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", note: "Faster and cheaper; good for everyday questions."),
        ClaudeModelInfo(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", note: "Fastest and cheapest; suitable for quick questions on small projects.")
    ]

    /// Models on which the server-side `fallbacks: "default"` parameter is accepted.
    public static func supportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable") || model.hasPrefix("claude-mythos") || model.hasPrefix("claude-sonnet-5-5")
    }
}

public struct ClaudeConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var model: String
    public var effort: Effort
    public var enableFallbacks: Bool
    public var showThinking: Bool
    public var maxTokens: Int
    public var endpoint: URL

    public init(apiKey: String,
                model: String = ClaudeModels.defaultModel,
                effort: Effort = .high,
                enableFallbacks: Bool = true,
                showThinking: Bool = true,
                maxTokens: Int = 64_000,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.enableFallbacks = enableFallbacks
        self.showThinking = showThinking
        self.maxTokens = maxTokens
        self.endpoint = endpoint
    }
}

// MARK: - Errors

public enum ClaudeError: LocalizedError, Sendable {
    case missingAPIKey
    case httpError(status: Int, type: String?, message: String)
    case network(String)
    case invalidResponse(String)
    case streamError(String)
    case refusal(category: String?, explanation: String?)
    case maxTokensReached
    case tooManyIterations
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key is configured. Add one in Settings (⌘,)."
        case .httpError(let status, let type, let message):
            switch status {
            case 401: return "Authentication failed (401). Check your API key in Settings."
            case 403: return "Permission denied (403): \(message)"
            case 429: return "Rate limited (429). Wait a moment and try again. \(message)"
            case 529: return "The API is overloaded (529). Try again shortly."
            default: return "API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
            }
        case .network(let message):
            return "Network error: \(message)"
        case .invalidResponse(let message):
            return "Unexpected response: \(message)"
        case .streamError(let message):
            return "Stream error: \(message)"
        case .refusal(let category, let explanation):
            var text = "Claude declined this request"
            if let category { text += " (\(category))" }
            if let explanation, !explanation.isEmpty { text += ": \(explanation)" }
            return text + "."
        case .maxTokensReached:
            return "The response hit the output token limit before finishing. Try a narrower request."
        case .tooManyIterations:
            return "The agent loop exceeded its tool-call limit without finishing."
        case .cancelled:
            return "Cancelled."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .httpError(let status, _, _):
            return status == 429 || status == 408 || status == 409 || status == 529 || (500...504).contains(status)
        case .network:
            return true
        default:
            return false
        }
    }
}

// MARK: - Messages

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadInputTokens: Int = 0
    public var cacheCreationInputTokens: Int = 0

    public init() {}

    public mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadInputTokens += other.cacheReadInputTokens
        cacheCreationInputTokens += other.cacheCreationInputTokens
    }

    public var totalInput: Int { inputTokens + cacheReadInputTokens + cacheCreationInputTokens }

    static func parse(_ json: JSONValue?) -> TokenUsage {
        var usage = TokenUsage()
        guard let json else { return usage }
        usage.inputTokens = json["input_tokens"]?.intValue ?? 0
        usage.outputTokens = json["output_tokens"]?.intValue ?? 0
        usage.cacheReadInputTokens = json["cache_read_input_tokens"]?.intValue ?? 0
        usage.cacheCreationInputTokens = json["cache_creation_input_tokens"]?.intValue ?? 0
        return usage
    }
}

public struct ToolUseCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSONValue
}

public struct AssistantMessage: Sendable {
    public var id: String?
    public var model: String?
    /// Raw content blocks exactly as the API returned them (text, thinking, tool_use, …).
    public var content: [JSONValue] = []
    public var stopReason: String?
    public var stopDetails: JSONValue?
    public var usage = TokenUsage()

    public init() {}

    /// Concatenated text of all text blocks.
    public var text: String {
        content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined()
    }

    public var thinkingSummary: String {
        content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "thinking" else { return nil }
            let text = block["thinking"]?.stringValue ?? ""
            return text.isEmpty ? nil : text
        }.joined(separator: "\n\n")
    }

    public var toolUses: [ToolUseCall] {
        content.compactMap { block -> ToolUseCall? in
            guard block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue else { return nil }
            return ToolUseCall(id: id, name: name, input: block["input"] ?? .object([:]))
        }
    }

    public var isRefusal: Bool { stopReason == "refusal" }

    /// Content blocks suitable for replaying as an assistant turn in the next request:
    /// empty text blocks are removed (the API rejects them) and, after a mid-output fallback,
    /// model-internal blocks that precede the final fallback marker are dropped as documented.
    public var replayableContent: [JSONValue] {
        var blocks = content
        if let lastFallback = blocks.lastIndex(where: { $0["type"]?.stringValue == "fallback" }) {
            var kept: [JSONValue] = []
            for (index, block) in blocks.enumerated() {
                let type = block["type"]?.stringValue ?? ""
                if index < lastFallback {
                    if type == "text" { kept.append(block) }
                } else if index > lastFallback {
                    kept.append(block)
                }
            }
            blocks = kept
        }
        return blocks.filter { block in
            if block["type"]?.stringValue == "text" {
                let text = block["text"]?.stringValue ?? ""
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }
}

public struct MessageRequest: Sendable {
    public var system: [JSONValue]
    public var messages: [JSONValue]
    public var tools: [JSONValue]
    /// JSON schema for structured output (`output_config.format`).
    public var outputSchema: JSONValue?
    public var toolChoice: JSONValue?
    public var maxTokens: Int?

    public init(system: [JSONValue] = [],
                messages: [JSONValue],
                tools: [JSONValue] = [],
                outputSchema: JSONValue? = nil,
                toolChoice: JSONValue? = nil,
                maxTokens: Int? = nil) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.outputSchema = outputSchema
        self.toolChoice = toolChoice
        self.maxTokens = maxTokens
    }
}

public enum StreamEvent: Sendable {
    case messageStart(model: String)
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseStarted(name: String)
    case toolInputDelta(String)
    case fallback(from: String, to: String)
    case usage(TokenUsage)
}

// MARK: - Client

/// Thin streaming client for the Claude Messages API (`POST /v1/messages`), implemented over
/// URLSession because there is no official Swift SDK.
public final class ClaudeClient: @unchecked Sendable {
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let configuration: ClaudeConfiguration
    private let session: URLSession

    public init(configuration: ClaudeConfiguration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 600
        sessionConfiguration.timeoutIntervalForResource = 3600
        sessionConfiguration.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfiguration)
    }

    /// Sends a streaming request, forwarding incremental events, and returns the complete message.
    public func send(_ request: MessageRequest,
                     onEvent: @escaping @Sendable (StreamEvent) -> Void) async throws -> AssistantMessage {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        let body = try buildBody(for: request)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await perform(body: body, onEvent: onEvent)
            } catch let error as ClaudeError {
                attempt += 1
                guard error.isRetryable, attempt <= 3 else { throw error }
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            } catch is CancellationError {
                throw ClaudeError.cancelled
            } catch let urlError as URLError {
                if urlError.code == .cancelled { throw ClaudeError.cancelled }
                attempt += 1
                guard attempt <= 3 else { throw ClaudeError.network(urlError.localizedDescription) }
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            } catch {
                throw ClaudeError.network(error.localizedDescription)
            }
        }
    }

    // MARK: Request body

    func buildBody(for request: MessageRequest) throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "max_tokens": .int(request.maxTokens ?? configuration.maxTokens),
            "stream": .bool(true),
            "messages": .array(request.messages)
        ]
        if !request.system.isEmpty {
            body["system"] = .array(request.system)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools)
            if let toolChoice = request.toolChoice {
                body["tool_choice"] = toolChoice
            }
        }
        // Adaptive thinking is the only mode on current models; `display` controls what we see.
        body["thinking"] = [
            "type": "adaptive",
            "display": .string(configuration.showThinking ? "summarized" : "omitted")
        ]
        var outputConfig: [String: JSONValue] = ["effort": .string(configuration.effort.rawValue)]
        if let schema = request.outputSchema {
            outputConfig["format"] = [
                "type": "json_schema",
                "schema": schema
            ]
        }
        body["output_config"] = .object(outputConfig)
        if usesFallbacks {
            body["fallbacks"] = .string("default")
        }
        return try JSONValue.object(body).encoded()
    }

    var usesFallbacks: Bool {
        configuration.enableFallbacks && ClaudeModels.supportsFallbacks(configuration.model)
    }

    func makeURLRequest(body: Data) -> URLRequest {
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(ClaudeClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        if usesFallbacks {
            urlRequest.setValue(ClaudeClient.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        return urlRequest
    }

    // MARK: Streaming

    private func perform(body: Data, onEvent: @escaping @Sendable (StreamEvent) -> Void) async throws -> AssistantMessage {
        let urlRequest = makeURLRequest(body: body)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse("Not an HTTP response")
        }
        if http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 1_000_000 { break }
            }
            throw ClaudeClient.errorFromBody(status: http.statusCode, data: data)
        }

        var accumulator = StreamAccumulator()
        var parser = SSEParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = parser.feed(line: line) {
                try accumulator.handle(eventName: event.name, data: event.data, onEvent: onEvent)
            }
        }
        if let event = parser.flush() {
            try accumulator.handle(eventName: event.name, data: event.data, onEvent: onEvent)
        }
        return accumulator.finish()
    }

    static func errorFromBody(status: Int, data: Data) -> ClaudeError {
        if let json = try? JSONValue.parse(data) {
            let error = json["error"]
            let message = error?["message"]?.stringValue ?? json["message"]?.stringValue ?? String(decoding: data, as: UTF8.self)
            return .httpError(status: status, type: error?["type"]?.stringValue, message: message)
        }
        let text = String(decoding: data, as: UTF8.self)
        return .httpError(status: status, type: nil, message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)
    }
}

// MARK: - SSE parsing

public struct SSEEvent: Equatable, Sendable {
    public var name: String
    public var data: String
}

/// Incremental Server-Sent-Events line parser.
public struct SSEParser: Sendable {
    private var eventName = ""
    private var dataLines: [String] = []

    public init() {}

    /// Feed one line (without its terminating newline). Returns a complete event when a blank
    /// line terminates one.
    public mutating func feed(line rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            return nil // comment / keep-alive
        }
        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var rest = String(line[line.index(after: colon)...])
            if rest.hasPrefix(" ") { rest.removeFirst() }
            value = rest
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    public mutating func flush() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            eventName = ""
            return nil
        }
        let event = SSEEvent(name: eventName, data: dataLines.joined(separator: "\n"))
        eventName = ""
        dataLines = []
        return event
    }
}

/// Rebuilds a complete `AssistantMessage` from the streamed event sequence.
public struct StreamAccumulator: Sendable {
    private struct BlockBuilder {
        var start: [String: JSONValue]
        var text = ""
        var thinking = ""
        var signature = ""
        var partialJSON = ""
    }

    private var message = AssistantMessage()
    private var builders: [Int: BlockBuilder] = [:]
    private var finished: [Int: JSONValue] = [:]

    public init() {}

    public mutating func handle(eventName: String, data: String, onEvent: (StreamEvent) -> Void) throws {
        let json: JSONValue
        do {
            json = try JSONValue.parse(data)
        } catch {
            throw ClaudeError.streamError("Malformed event payload: \(data.prefix(200))")
        }
        let type = json["type"]?.stringValue ?? eventName

        switch type {
        case "message_start":
            let messageJSON = json["message"]
            message.id = messageJSON?["id"]?.stringValue
            message.model = messageJSON?["model"]?.stringValue
            message.usage = TokenUsage.parse(messageJSON?["usage"])
            onEvent(.messageStart(model: message.model ?? ""))
            onEvent(.usage(message.usage))

        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"]?.objectValue else { return }
            builders[index] = BlockBuilder(start: block)
            let blockType = block["type"]?.stringValue ?? ""
            if blockType == "tool_use" {
                onEvent(.toolUseStarted(name: block["name"]?.stringValue ?? ""))
            } else if blockType == "fallback" {
                onEvent(.fallback(from: block["from"]?["model"]?.stringValue ?? "?", to: block["to"]?["model"]?.stringValue ?? "?"))
            } else if blockType == "text", let text = block["text"]?.stringValue, !text.isEmpty {
                builders[index]?.text = text
                onEvent(.textDelta(text))
            }

        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"] else { return }
            switch delta["type"]?.stringValue ?? "" {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                builders[index]?.text += text
                onEvent(.textDelta(text))
            case "thinking_delta":
                let text = delta["thinking"]?.stringValue ?? ""
                builders[index]?.thinking += text
                if !text.isEmpty { onEvent(.thinkingDelta(text)) }
            case "signature_delta":
                builders[index]?.signature += delta["signature"]?.stringValue ?? ""
            case "input_json_delta":
                let partial = delta["partial_json"]?.stringValue ?? ""
                builders[index]?.partialJSON += partial
                onEvent(.toolInputDelta(partial))
            default:
                break
            }

        case "content_block_stop":
            guard let index = json["index"]?.intValue, let builder = builders.removeValue(forKey: index) else { return }
            finished[index] = StreamAccumulator.finalize(builder)

        case "message_delta":
            if let delta = json["delta"] {
                if let stop = delta["stop_reason"]?.stringValue { message.stopReason = stop }
                if let details = delta["stop_details"], !details.isNull { message.stopDetails = details }
            }
            if let usage = json["usage"] {
                if let output = usage["output_tokens"]?.intValue { message.usage.outputTokens = output }
                if let input = usage["input_tokens"]?.intValue, input > 0 { message.usage.inputTokens = input }
                if let read = usage["cache_read_input_tokens"]?.intValue, read > 0 { message.usage.cacheReadInputTokens = read }
                if let created = usage["cache_creation_input_tokens"]?.intValue, created > 0 { message.usage.cacheCreationInputTokens = created }
                onEvent(.usage(message.usage))
            }

        case "error":
            let error = json["error"]
            throw ClaudeError.streamError(error?["message"]?.stringValue ?? "unknown stream error")

        default:
            break // ping, message_stop, unknown future events
        }
    }

    private static func finalize(_ builder: BlockBuilder) -> JSONValue {
        var block = builder.start
        switch block["type"]?.stringValue ?? "" {
        case "text":
            block["text"] = .string(builder.text)
        case "thinking":
            block["thinking"] = .string(builder.thinking)
            if !builder.signature.isEmpty {
                block["signature"] = .string(builder.signature)
            }
        case "tool_use":
            if builder.partialJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if block["input"] == nil { block["input"] = .object([:]) }
            } else if let parsed = try? JSONValue.parse(builder.partialJSON) {
                block["input"] = parsed
            } else {
                block["input"] = .object(["_malformed_input": .string(builder.partialJSON)])
            }
        default:
            break
        }
        return .object(block)
    }

    public mutating func finish() -> AssistantMessage {
        for (index, builder) in builders {
            finished[index] = StreamAccumulator.finalize(builder)
        }
        builders = [:]
        message.content = finished.keys.sorted().compactMap { finished[$0] }
        return message
    }
}
