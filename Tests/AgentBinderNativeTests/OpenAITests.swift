import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("OpenAITests")
struct OpenAITests {
    @Test func validation() throws {
        let s = Stub([])
        #expect(throws: NativeError.config("openai: credentials format \"anthropic\" is not \"openai\"")) {
            try OpenAIModel(credentials: s.credentials(.anthropic), model: "m")
        }
        #expect(throws: NativeError.config("openai: the API key is empty")) {
            try OpenAIModel(credentials: Credentials(format: .openai, apiKey: ""), model: "m")
        }
        #expect(throws: NativeError.config("openai: the model name is required")) {
            try OpenAIModel(credentials: s.credentials(.openai), model: nil)
        }
    }

    @Test func streamText() async throws {
        let s = Stub([try .sse("openai-text.sse")])
        let r = ModelRequest(system: "sys", messages: [.user("hi")], maxOutputTokens: 50)
        let (parts, error) = await collect(try s.openai(headers: ["X-Tenant": "t1"]), r)
        #expect(error == nil)
        #expect(
            parts == [
                .textDelta("Hel"), .textDelta("lo"),
                .finish(
                    Finish(
                        reason: .stop, raw: "stop", usage: ModelUsage(input: 11, output: 7, cacheRead: 4, reasoning: 2))
                ),
            ])
        let q = s.requests[0]
        #expect(q.url.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(q.headers["Authorization"] == "Bearer k" && q.headers["X-Tenant"] == "t1")
        let want: JSONValue = [
            "model": "gpt-test", "stream": true, "stream_options": ["include_usage": true],
            "max_completion_tokens": 50,
            "messages": [["role": "system", "content": "sys"], ["role": "user", "content": "hi"]],
        ]
        // Fixed on purpose: no tool_choice without tools.
        #expect(q.body.jsonString == want.jsonString)
    }

    @Test func parallelToolCalls() async throws {
        let s = Stub([try .sse("openai-parallel.sse")])
        let schema = Data(#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#.utf8)
        let r = ModelRequest(
            messages: [
                .user("weather?"),
                Message(
                    role: .assistant,
                    parts: [
                        .reasoning(ReasoningPart(text: "x", signature: "s")), .text("a"), .text("b"),
                        .toolCall(ToolCall(id: "call_a", name: "get_weather", input: Data(#"{"city":"SF"}"#.utf8))),
                        .toolCall(ToolCall(id: "call_z", name: "noop")),
                    ]),
                Message(
                    role: .tool,
                    parts: [
                        .toolResult(ToolResult(callID: "call_a", content: [.text("sunny"), .text("warm")])),
                        .toolResult(ToolResult(callID: "call_z", content: [], isError: true)),
                    ]),
                Message(role: .assistant, parts: [.reasoning(ReasoningPart(text: "only"))]),
            ],
            tools: [
                ToolSpec(name: "get_weather", inputSchema: schema), ToolSpec(name: "bad", inputSchema: Data("{".utf8)),
            ],
            maxOutputTokens: 512, effort: "max")
        let m = try s.openai(baseURL: URL(string: "http://localhost:11434/v1/"))
        let (parts, _) = await collect(m, r)
        #expect(
            parts == [
                .toolInputDelta(id: "call_a", fragment: #"{"city":"#),
                .toolInputDelta(id: "call_b", fragment: #"{"tz":"#),
                .toolInputDelta(id: "call_a", fragment: #""SF"}"#), .toolInputDelta(id: "call_b", fragment: #""UTC"}"#),
                .toolCallDone(ToolCall(id: "call_a", name: "get_weather", input: Data(#"{"city":"SF"}"#.utf8))),
                .toolCallDone(ToolCall(id: "call_b", name: "get_time", input: Data(#"{"tz":"UTC"}"#.utf8))),
                .finish(Finish(reason: .toolCalls, raw: "tool_calls")),
            ])
        let q = s.requests[0]
        #expect(q.url.absoluteString == "http://localhost:11434/v1/chat/completions")
        let want: JSONValue = [
            "model": "gpt-test", "stream": true, "stream_options": ["include_usage": true], "max_tokens": 512,
            "reasoning_effort": "high", "tool_choice": "auto",
            "tools": [
                [
                    "type": "function",
                    "function": [
                        "name": "get_weather", "description": "",
                        "parameters": [
                            "type": "object", "properties": ["city": ["type": "string"]], "required": ["city"],
                        ],
                    ],
                ],
                ["type": "function", "function": ["name": "bad", "description": ""]],
            ],
            "messages": [
                ["role": "user", "content": "weather?"],
                [
                    "role": "assistant", "content": "a\nb",
                    "tool_calls": [
                        [
                            "id": "call_a", "type": "function",
                            "function": ["name": "get_weather", "arguments": #"{"city":"SF"}"#],
                        ],
                        // Fixed on purpose: an empty input is "{}".
                        ["id": "call_z", "type": "function", "function": ["name": "noop", "arguments": "{}"]],
                    ],
                ],
                ["role": "tool", "tool_call_id": "call_a", "content": "sunny\nwarm"],
                ["role": "tool", "tool_call_id": "call_z", "content": ""],
            ],
        ]
        #expect(q.body.jsonString == want.jsonString)
    }

    @Test func toolChoiceModes() throws {
        let m = try Stub([]).openai()
        let t = [ToolSpec(name: "t")]
        #expect(try m.body(ModelRequest(messages: [], tools: t, toolChoice: .none))["tool_choice"] == "none")
        #expect(try m.body(ModelRequest(messages: [], tools: t, toolChoice: .required))["tool_choice"] == "required")
        #expect(
            try m.body(ModelRequest(messages: [], tools: t, toolChoice: .named("t")))["tool_choice"]
                == ["type": "function", "function": ["name": "t"]])
        #expect(try m.body(ModelRequest(messages: [], toolChoice: .none))["tool_choice"] == nil)
        #expect(throws: NativeError.config("openai: named tool choice needs a name")) {
            try m.body(ModelRequest(messages: [], tools: t, toolChoice: .named("")))
        }
        #expect(try m.body(ModelRequest(messages: [], effort: "bogus"))["reasoning_effort"] == nil)
        #expect(try m.body(ModelRequest(messages: [], effort: "low"))["reasoning_effort"] == "low")
        #expect(
            try m.body(ModelRequest(messages: [], tools: t))["tools"]?.array?.first?.at(
                "function", "parameters", "type") == "object")
    }

    @Test func userImageIsADataURL() throws {
        let m = try Stub([]).openai()
        let parts: [Part] = [
            .file(FilePart(mediaType: "image/png", data: Data([1, 2, 3]))),
            .file(FilePart(mediaType: "image/jpeg", url: "https://x/a.jpg")),
            .file(FilePart(mediaType: "text/plain", data: Data([65]))), .text("look"),
        ]
        let b = try m.body(
            ModelRequest(messages: [
                Message(role: .user, parts: parts), .user(""),
                Message(role: .user, parts: [.file(FilePart(mediaType: "image/png"))]),
            ]))
        // The text file, the empty text and the empty image are dropped.
        #expect(b["messages"]?.array?.count == 1)
        let c = b["messages"]?.array?.first?["content"]?.array ?? []
        #expect(c.count == 3)
        #expect(c.first?.at("image_url", "url")?.string == "data:image/png;base64,AQID")
        #expect(c.dropFirst().first?.at("image_url", "url")?.string == "https://x/a.jpg")
        #expect(c.last == ["type": "text", "text": "look"])
    }

    @Test func streamErrorFrame() async throws {
        let s = Stub([
            .sse(
                text:
                    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\"}}]}\n\ndata: {\"error\":{\"message\":\"boom\",\"type\":\"server_error\"}}\n\n"
            )
        ])
        let (parts, error) = await collect(try s.openai(), .hi)
        #expect(parts == [.textDelta("a")])
        let e = try #require(error as? ProviderError)
        #expect(e.message == "received error while streaming: boom" && e.type == "server_error")
    }

    @Test func streamWithoutDone() async throws {
        let s = Stub([
            .sse(
                text:
                    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\"},\"finish_reason\":\"length\"}]}\n\n"
            )
        ])
        let (parts, error) = await collect(try s.openai(), .hi)
        #expect(error == nil && parts == [.textDelta("a"), .finish(Finish(reason: .length, raw: "length"))])
    }

    @Test func httpError() async throws {
        let body = #"{"error":{"message":"bad key","type":"invalid_request_error","code":"invalid_api_key"}}"#
        let s = Stub([.status(401, body, headers: ["x-request-id": "r1"])])
        let (_, error) = await collect(try s.openai(), .hi)
        let e = try #require(error as? ProviderError)
        #expect(
            e.provider == "openai" && e.status == 401 && e.type == "invalid_request_error" && e.message == "bad key")
        #expect(e.requestID == "r1" && e.classification.cls == .auth)
    }

    @Test func finishMap() {
        #expect(OpenAIStream.reason("function_call") == .toolCalls)
        #expect(OpenAIStream.reason("content_filter") == .contentFilter)
        #expect(OpenAIStream.reason("weird") == .other)
    }
}
