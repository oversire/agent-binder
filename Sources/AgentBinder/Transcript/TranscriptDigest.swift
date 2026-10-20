/// How much of a transcript a ``TranscriptReader`` keeps.
public struct TranscriptBudget: Hashable, Sendable, Codable {
    /// The number of earlier turns, before the last ones. The default is 12.
    public var earlier: Int
    /// The number of last turns with the full agent text. The default is 3.
    public var full: Int
    /// The maximum length of the agent text of one last turn, in Unicode code points. The default is 4000.
    ///
    /// The reader keeps the end of the text. A value below 1 counts as 1.
    public var maxChars: Int

    /// Makes a budget. A negative count counts as 0.
    public init(earlier: Int = 12, full: Int = 3, maxChars: Int = 4000) {
        self.earlier = earlier
        self.full = full
        self.maxChars = maxChars
    }

    /// Decodes a budget. A missing field takes its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranscriptBudget()
        earlier = try c.decodeIfPresent(Int.self, forKey: .earlier) ?? d.earlier
        full = try c.decodeIfPresent(Int.self, forKey: .full) ?? d.full
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? d.maxChars
    }
}

/// A short record of the history of one agent session.
///
/// A turn is a human prompt and the agent output until the next human prompt.
/// Earlier turns keep the start of the prompt and the start of the last agent text block.
/// The last turns keep the full agent text, up to ``TranscriptBudget/maxChars``. Tool input and output are left out.
/// All lengths count Unicode code points.
public struct TranscriptDigest: Codable, Hashable, Sendable {
    /// One earlier turn.
    public struct EarlierTurn: Codable, Hashable, Sendable {
        /// The first 120 code points of the human prompt.
        public var prompt: String
        /// The first 700 code points of the last agent text block of the turn.
        public var closing: String
        /// The developer stopped the turn. The JSON form leaves out a false value.
        public var interrupted: Bool

        /// Makes an earlier turn.
        public init(prompt: String, closing: String, interrupted: Bool = false) {
            self.prompt = prompt
            self.closing = closing
            self.interrupted = interrupted
        }

        /// Decodes an earlier turn. A missing `interrupted` is false.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prompt = try c.decode(String.self, forKey: .prompt)
            closing = try c.decode(String.self, forKey: .closing)
            interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        }

        /// Encodes the turn. It leaves out `interrupted` when it is false.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(prompt, forKey: .prompt)
            try c.encode(closing, forKey: .closing)
            if interrupted { try c.encode(true, forKey: .interrupted) }
        }

        private enum CodingKeys: String, CodingKey { case prompt, closing, interrupted }
    }

    /// One of the last turns.
    public struct LastTurn: Codable, Hashable, Sendable {
        /// The first 1500 code points of the human prompt.
        public var prompt: String
        /// The agent text blocks, joined with an empty line. When it is too long, the reader keeps the end.
        public var text: String
        /// The number of tool calls in the turn.
        public var tools: Int
        /// The developer stopped the turn. The JSON form leaves out a false value.
        public var interrupted: Bool

        /// Makes a last turn.
        public init(prompt: String, text: String, tools: Int, interrupted: Bool = false) {
            self.prompt = prompt
            self.text = text
            self.tools = tools
            self.interrupted = interrupted
        }

        /// Decodes a last turn. A missing `interrupted` is false.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prompt = try c.decode(String.self, forKey: .prompt)
            text = try c.decode(String.self, forKey: .text)
            tools = try c.decode(Int.self, forKey: .tools)
            interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        }

        /// Encodes the turn. It leaves out `interrupted` when it is false.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(prompt, forKey: .prompt)
            try c.encode(text, forKey: .text)
            try c.encode(tools, forKey: .tools)
            if interrupted { try c.encode(true, forKey: .interrupted) }
        }

        private enum CodingKeys: String, CodingKey { case prompt, text, tools, interrupted }
    }

    /// The harness that wrote the transcript.
    public var harness: Harness
    /// The session id of the harness.
    public var sessionId: String
    /// The number of turns in the session.
    public var turns: Int
    /// The earlier turns, oldest first.
    public var earlier: [EarlierTurn]
    /// The last turns, oldest first.
    public var last: [LastTurn]
    /// The reader left out turns, or it cut the text of a last turn.
    public var truncated: Bool

    /// Makes a digest.
    public init(
        harness: Harness, sessionId: String, turns: Int, earlier: [EarlierTurn], last: [LastTurn], truncated: Bool
    ) {
        self.harness = harness
        self.sessionId = sessionId
        self.turns = turns
        self.earlier = earlier
        self.last = last
        self.truncated = truncated
    }
}

/// The errors of ``TranscriptReader``. Each case has a stable machine ``code``.
public enum TranscriptError: Error, Sendable, Equatable {
    /// The reader cannot read the transcripts of this harness.
    case unsupportedHarness(Harness)
    /// No transcript is at the path or for the session.
    case notFound(String)

    /// The stable machine code of the error.
    public var code: String {
        switch self {
        case .unsupportedHarness: return "unsupported_harness"
        case .notFound: return "transcript_not_found"
        }
    }
}

extension TranscriptError: CustomStringConvertible {
    /// A log line for the error. It is not UI text.
    public var description: String {
        switch self {
        case .unsupportedHarness(let h): return "agentbinder: no transcript reader for harness \(h)"
        case .notFound(let what): return "agentbinder: transcript not found: \(what)"
        }
    }
}
