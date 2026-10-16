import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("AnthropicTests")
struct AnthropicTests {
    @Test func validation() throws {
        let s = Stub([])
        #expect(throws: NativeError.config("anthropic: credentials format \"openai\" is not \"anthropic\"")) {
            try AnthropicModel(credentials: s.credentials(.openai))
        }
        #expect(throws: NativeError.config("anthropic: the API key is empty")) {
            try AnthropicModel(credentials: Credentials(format: .anthropic, apiKey: ""))
        }
        #expect(try AnthropicModel(credentials: s.credentials(.anthropic)).name == "claude-sonnet-5-5")
        #expect(try AnthropicModel(credentials: s.credentials(.anthropic), model: "").name == "claude-sonnet-5-5")
    }

    @Test func streamText() async throws {
        let s = Stub([try .sse("anthropic-text.sse")])
        let (parts, error) = await collect(try s.anthropic(), .hi)
        #expect(error == nil)
        #expect(
            parts == [
                .textDelta("Hel"), .textDelta("lo"),
                .finish(
                    Finish(
                        reason: .stop, raw: "end_turn",
                        usage: ModelUsage(input: 25, output: 7, cacheRead: 5, cacheWrite: 3))),
            ])
    }

    // Fixed on purpose: the signature is a stream part.
    @Test func streamThinking() async throws {
        let s = Stub([try .sse("anthropic-thinking.sse")])
        let (parts, _) = await collect(try s.anthropic(), .hi)
        #expect(
            parts == [
                .reasoningDelta("plan"), .reasoningDelta("ning"), .reasoningSignature("sigA"), .textDelta("Answer"),
                .finish(Finish(reason: .stop, raw: "end_turn", usage: ModelUsage(input: 30, output: 9))),
            ])
    }

    @Test func streamToolUse() async throws {
        let s = Stub([try .sse("anthropic-tool.sse")])
        let (parts, _) = await collect(try s.anthropic(), .hi)
        let id = "toolu_01abc"
        #expect(
            parts == [
                .textDelta("Checking."), .toolInputStart(id: id), .toolInputDelta(id: id, fragment: #"{"city":"#),
                .toolInputDelta(id: id, fragment: #""SF"}"#),
                .toolCallDone(ToolCall(id: id, name: "get_weather", input: Data(#"{"city":"SF"}"#.utf8))),
                .finish(Finish(reason: .toolCalls, raw: "tool_use", usage: ModelUsage(input: 40, output: 12))),
            ])
    }

    @Test func streamFallback() async throws {
        let s = Stub([try .sse("anthropic-fallback.sse")])
        let (parts, _) = await collect(try s.anthropic(), .hi)
        #expect(
            parts == [
                .reasoningDelta("hmm"), .fallback(model: "claude-opus-5-5"), .textDelta("ok"),
                .finish(Finish(reason: .stop, raw: "end_turn", usage: ModelUsage(input: 20, output: 4))),
            ])
    }

    @Test func midStreamError() async throws {
        let s = Stub([try .sse("anthropic-error.sse")])
        let (parts, error) = await collect(try s.anthropic(), .hi)
        #expect(parts == [.textDelta("Hi")])
        let e = try #require(error as? ProviderError)
        #expect(e.type == "overloaded_error" && e.message == "Overloaded" && e.status == nil)
    }

    // Fixed on purpose: a stream that ends early is a failure, not a normal end.
    @Test func incompleteStream() async throws {
        let s = Stub([.sse(text: "event: ping\ndata: {\"type\":\"ping\"}\n\n")])
        let (parts, error) = await collect(try s.anthropic(), .hi)
        #expect(parts.isEmpty && (error as? ProviderError)?.type == "stream_incomplete")
    }

    @Test func headers() async throws {
        let s = Stub([try .sse("anthropic-text.sse"), try .sse("anthropic-text.sse")])
        _ = await collect(try s.anthropic(headers: ["x-trace": "t1", "anthropic-beta": "b1"]), .hi)
        _ = await collect(try s.anthropic(model: "claude-haiku-5-5"), .hi)
        let h = s.requests[0].headers
        #expect(s.requests[0].url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(h["x-api-key"] == "k" && h["anthropic-version"] == "2023-06-01" && h["x-trace"] == "t1")
        #expect(h["anthropic-beta"] == "b1,server-side-fallback-2026-07-01")
        #expect(s.requests[0].body["fallbacks"]?.string == "default")
        // Haiku has no fallback model.
        #expect(s.requests[1].headers["anthropic-beta"] == nil && s.requests[1].body["fallbacks"] == nil)
    }

    @Test func requestShape() async throws {
        let s = Stub([try .sse("anthropic-text.sse")])
        let schema = Data(
            #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city",3],"additionalProperties":false}"#
                .utf8)
        let r = ModelRequest(
            system: "be brief",
            messages: [
                Message(
                    role: .user,
                    parts: [.file(FilePart(mediaType: "image/png", data: Data([1, 2, 3]))), .text("look")]),
                Message(
                    role: .assistant,
                    parts: [
                        .reasoning(ReasoningPart(text: "t", signature: "sigA")),
                        .reasoning(ReasoningPart(text: "lost")),
                        .text(""),
                        .toolCall(ToolCall(id: "c1", name: "get_weather", input: Data(#"{"city":"SF"}"#.utf8))),
                        .toolCall(ToolCall(id: "c2", name: "noop")),
                    ]),
                Message(
                    role: .tool,
                    parts: [.toolResult(ToolResult(callID: "c1", content: [.text("sunny")], isError: true))]),
                Message(role: .tool, parts: [.toolResult(ToolResult(callID: "c2", content: []))]),
                Message(role: .user, parts: [.file(FilePart(mediaType: "application/pdf", url: "https://x/a.pdf"))]),
            ],
            tools: [
                ToolSpec(name: "get_weather", description: "weather", inputSchema: schema), ToolSpec(name: "noop"),
            ],
            toolChoice: .named("get_weather"), effort: "high")
        _ = await collect(try s.anthropic { $0.webSearch = true }, r)
        let want: JSONValue = [
            "model": "claude-sonnet-5-5", "max_tokens": 64000, "stream": true,
            "system": [["type": "text", "text": "be brief"]],
            "cache_control": ["type": "ephemeral"],
            "fallbacks": "default",
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": "high"],
            "tool_choice": ["type": "tool", "name": "get_weather"],
            "tools": [
                [
                    "name": "get_weather", "description": "weather", "eager_input_streaming": true,
                    "input_schema": [
                        "type": "object", "properties": ["city": ["type": "string"]], "required": ["city"],
                        "additionalProperties": false,
                    ],
                ],
                [
                    "name": "noop", "eager_input_streaming": true,
                    "input_schema": ["type": "object", "properties": [:]],
                ],
                ["type": "web_search_20260209", "name": "web_search", "max_uses": 3],
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AQID"]],
                        ["type": "text", "text": "look"],
                    ],
                ],
                [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "t", "signature": "sigA"],
                        ["type": "tool_use", "id": "c1", "name": "get_weather", "input": ["city": "SF"]],
                        ["type": "tool_use", "id": "c2", "name": "noop", "input": [:]],
                    ],
                ],
                // Fixed on purpose: the results and the next user text go in one user message.
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result", "tool_use_id": "c1", "is_error": true,
                            "content": [["type": "text", "text": "sunny"]],
                        ],
                        ["type": "tool_result", "tool_use_id": "c2"],
                        ["type": "document", "source": ["type": "url", "url": "https://x/a.pdf"]],
                    ],
                ],
            ],
        ]
        #expect(s.requests[0].body.jsonString == want.jsonString)
    }

    @Test func gatewayGetsNoNewFields() async throws {
        let s = Stub([try .sse("anthropic-text.sse")])
        let m = try s.anthropic { $0.baseURL = URL(string: "https://gw.example/anthropic") }
        _ = await collect(m, ModelRequest(messages: [.user("hi")], tools: [ToolSpec(name: "t")], maxOutputTokens: 100))
        let q = s.requests[0]
        #expect(q.url.absoluteString == "https://gw.example/anthropic/v1/messages")
        #expect(q.headers["anthropic-beta"] == nil && q.body["fallbacks"] == nil && q.body["max_tokens"]?.int == 100)
        #expect(q.body["tools"]?.array?.first?["eager_input_streaming"] == nil && q.body["thinking"] == nil)
        #expect(q.body["tool_choice"] == ["type": "auto"])
    }

    @Test func toolChoiceModes() async throws {
        let m = try Stub([]).anthropic()
        let t = [ToolSpec(name: "t")]
        #expect(try m.body(ModelRequest(messages: [], tools: t, toolChoice: .none))["tool_choice"] == ["type": "none"])
        #expect(
            try m.body(ModelRequest(messages: [], tools: t, toolChoice: .required))["tool_choice"] == ["type": "any"])
        #expect(try m.body(ModelRequest(messages: [], toolChoice: .required))["tool_choice"] == nil)
        #expect(try m.body(ModelRequest(messages: [], toolChoice: .required))["tools"] == nil)
        let off = try Stub([]).anthropic { $0.promptCaching = false }
        #expect(try off.body(.hi)["cache_control"] == nil && off.body(.hi)["system"] == nil)
    }

    @Test func paramErrors() throws {
        let m = try Stub([]).anthropic()
        #expect(throws: NativeError.config("anthropic: unknown effort \"bogus\"")) {
            try m.body(ModelRequest(messages: [], effort: "bogus"))
        }
        #expect(throws: NativeError.config("anthropic: named tool choice needs a name")) {
            try m.body(ModelRequest(messages: [], tools: [ToolSpec(name: "t")], toolChoice: .named("")))
        }
        #expect(throws: NativeError.config("anthropic: tool input schema: not a JSON object")) {
            try m.body(ModelRequest(messages: [], tools: [ToolSpec(name: "t", inputSchema: Data("[1]".utf8))]))
        }
        #expect(throws: NativeError.config("anthropic: file part has neither data nor url")) {
            try m.body(ModelRequest(messages: [Message(role: .user, parts: [.file(FilePart(mediaType: "image/png"))])]))
        }
    }

    @Test func retriesThenStreams() async throws {
        let s = Stub([
            .status(
                529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
                headers: ["retry-after": "2"]),
            .fail(.networkConnectionLost),
            try .sse("anthropic-text.sse"),
        ])
        let (parts, error) = await collect(try s.anthropic(), .hi)
        #expect(error == nil && parts.count == 3 && s.requests.count == 3)
        #expect(s.waits.value.count == 2 && s.waits.value[0] == .seconds(2))
    }

    @Test func retriesEnd() async throws {
        let s = Stub(Array(repeating: .status(500, "oops", headers: ["request-id": "req_1"]), count: 4))
        let (_, error) = await collect(try s.anthropic(), .hi)
        let e = try #require(error as? ProviderError)
        #expect(e.status == 500 && e.message == "oops" && e.requestID == "req_1" && s.requests.count == 3)
    }

    @Test(arguments: [
        (
            401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#,
            [String: String]()
        ),
        (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#, [:]),
        (
            429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#,
            ["x-should-retry": "false"]
        ),
    ])
    func errorsWithoutRetry(status: Int, body: String, headers: [String: String]) async throws {
        let s = Stub([.status(status, body, headers: headers.merging(["x-request-id": "r9"]) { a, _ in a })])
        let (_, error) = await collect(try s.anthropic(), .hi)
        let e = try #require(error as? ProviderError)
        #expect(e.status == status && e.requestID == "r9" && e.type?.hasSuffix("_error") == true)
        #expect(s.requests.count == 1 && s.waits.value.isEmpty)
        #expect(e.code.hasPrefix("native.") && e.description.hasPrefix("anthropic: http \(status) "))
    }

    @Test func rateLimitClassifies() {
        let e = ProviderError(provider: "anthropic", status: 429, type: "rate_limit_error", message: "slow down")
        #expect(e.classification.cls == .limit)
    }
}
