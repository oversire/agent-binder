import Foundation

/// The session instructions for a protocol without a field for them.
enum Instructions {
    /// Joins the instructions of the consumer and the skill index.
    static func join(_ instructions: String?, skillIndex: String) -> String {
        let a = (instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let b = skillIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + "\n\n" + b
    }

    /// The fenced block of the instructions, or an empty string.
    static func block(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        return "<session-instructions>\n" + t + "\n</session-instructions>"
    }

    /// Puts the instructions before the text of the first prompt. Later turns carry the text alone.
    static func withInstructions(_ instructions: String?, _ text: String, first: Bool) -> String {
        guard first else { return text }
        let b = block(instructions ?? "")
        return b.isEmpty ? text : b + "\n\n" + text
    }
}
