import XCTest
@testable import CodeScopeCore

final class ClaudeClientTests: XCTestCase {

    func testSSEParserAssemblesEvents() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(line: "event: message_start"))
        XCTAssertNil(parser.feed(line: "data: {\"a\":1}"))
        let event = parser.feed(line: "")
        XCTAssertEqual(event, SSEEvent(name: "message_start", data: "{\"a\":1}"))
        XCTAssertNil(parser.feed(line: ": keep-alive"))
        XCTAssertNil(parser.feed(line: ""))
        XCTAssertNil(parser.feed(line: "data: part1"))
        XCTAssertNil(parser.feed(line: "data: part2\r"))
        XCTAssertEqual(parser.flush(), SSEEvent(name: "", data: "part1\npart2"))
    }

    func testStreamAccumulatorBuildsTextAndToolUse() throws {
        var accumulator = StreamAccumulator()
        var deltas: [String] = []
        let handler: (StreamEvent) -> Void = { event in
            if case .textDelta(let text) = event { deltas.append(text) }
        }
        let events: [(String, String)] = [
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":5}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\": "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"a.swift\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ]
        for (name, data) in events {
            try accumulator.handle(eventName: name, data: data, onEvent: handler)
        }
        let message = accumulator.finish()
        XCTAssertEqual(message.model, "claude-opus-5-5")
        XCTAssertEqual(message.text, "Hello")
        XCTAssertEqual(deltas, ["Hel", "lo"])
        XCTAssertEqual(message.stopReason, "tool_use")
        XCTAssertEqual(message.usage.outputTokens, 42)
        XCTAssertEqual(message.usage.inputTokens, 10)
        XCTAssertEqual(message.usage.cacheReadInputTokens, 5)
        XCTAssertEqual(message.toolUses.count, 1)
        XCTAssertEqual(message.toolUses.first?.name, "read_file")
        XCTAssertEqual(message.toolUses.first?.input["path"]?.stringValue, "a.swift")
        XCTAssertEqual(message.content[0]["signature"]?.stringValue, "sig")
        XCTAssertEqual(message.thinkingSummary, "hmm")
        XCTAssertEqual(message.replayableContent.count, 3)
    }

    func testReplayableContentDropsEmptyText() {
        var message = AssistantMessage()
        message.content = [["type": "text", "text": "  "], ["type": "text", "text": "ok"]]
        XCTAssertEqual(message.replayableContent.count, 1)
    }

    func testRequestBodyShape() throws {
        let config = ClaudeConfiguration(apiKey: "k", model: "claude-opus-5-5", effort: .xhigh, enableFallbacks: true, showThinking: false)
        let client = ClaudeClient(configuration: config)
        let request = MessageRequest(system: [["type": "text", "text": "sys"]],
                                     messages: [["role": "user", "content": "hi"]],
                                     tools: CodebaseToolset.json,
                                     outputSchema: ArchitectureReport.schema,
                                     toolChoice: ["type": "none"])
        let body = try JSONValue.parse(client.buildBody(for: request))
        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5-5")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body["max_tokens"]?.intValue, 64_000)
        XCTAssertEqual(body["thinking"]?["type"]?.stringValue, "adaptive")
        XCTAssertEqual(body["thinking"]?["display"]?.stringValue, "omitted")
        XCTAssertEqual(body["output_config"]?["effort"]?.stringValue, "xhigh")
        XCTAssertEqual(body["output_config"]?["format"]?["type"]?.stringValue, "json_schema")
        XCTAssertEqual(body["fallbacks"]?.stringValue, "default")
        XCTAssertEqual(body["tool_choice"]?["type"]?.stringValue, "none")
        XCTAssertEqual(body["tools"]?.arrayValue?.count, CodebaseToolset.definitions.count)
        XCTAssertNil(body["temperature"])

        let urlRequest = client.makeURLRequest(body: Data())
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "k")
    }

    func testHaikuHasNoFallbacks() throws {
        let client = ClaudeClient(configuration: ClaudeConfiguration(apiKey: "k", model: "claude-haiku-5-5"))
        let body = try JSONValue.parse(client.buildBody(for: MessageRequest(messages: [["role": "user", "content": "hi"]])))
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(client.makeURLRequest(body: Data()).value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = ["b": 1, "a": ["x", true, .null, 2.5]]
        let data = try value.encoded()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":["x",true,null,2.5],"b":1}"#)
        XCTAssertEqual(try JSONValue.parse(data), value)
    }

    func testErrorBodyParsing() {
        let data = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        let error = ClaudeClient.errorFromBody(status: 401, data: data)
        guard case .httpError(let status, let type, let message) = error else { return XCTFail() }
        XCTAssertEqual(status, 401)
        XCTAssertEqual(type, "authentication_error")
        XCTAssertEqual(message, "invalid x-api-key")
    }

    func testArchitectureReportDecodes() throws {
        let json = """
        {"title":"T","oneLiner":"o","purpose":"p","architectureStyle":"s","languages":[{"name":"Swift","role":"app"}],
         "entryPoints":[{"path":"a","description":"d"}],"components":[{"name":"c","responsibility":"r","files":["a"],"keyTypes":["K"],"interactsWith":[]}],
         "executionFlow":[{"step":"1","description":"d","files":[]}],"dataFlow":"df","externalDependencies":[],"buildAndRun":"b",
         "concerns":[{"title":"t","severity":"high","detail":"d","files":[]}],
         "optimizationOpportunities":[{"title":"t","category":"performance","impact":"high","effort":"low","detail":"d","files":["a"],"suggestedPrompt":"do it"}],
         "glossary":[]}
        """
        let report = try ArchitectureReport.decode(from: "```json\n" + json + "\n```")
        XCTAssertEqual(report.title, "T")
        XCTAssertEqual(report.optimizationOpportunities.first?.suggestedPrompt, "do it")
    }
}
