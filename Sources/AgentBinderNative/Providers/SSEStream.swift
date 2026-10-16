import Foundation

/// One server-sent event.
struct SSEEvent: Sendable, Equatable {
    var event: String
    var data: String
}

/// Splits a `text/event-stream` body into events. `event:` sets the type, the `data:` lines join
/// with a newline, and a blank line ends the event. Comment lines (`:`) and other fields are skipped.
struct SSEDecoder {
    static let maxEvent = 16 << 20
    private var line: [UInt8] = []
    private var event = ""
    private var data: [String] = []
    private var size = 0

    /// Adds one byte. It returns the event that a blank line completed.
    mutating func feed(_ b: UInt8) throws -> SSEEvent? {
        guard b == 0x0A else {
            line.append(b)
            size += 1
            if size > Self.maxEvent { throw SSEDecoder.TooLarge() }
            return nil
        }
        if line.last == 0x0D { line.removeLast() }
        defer { line = [] }
        return take(String(decoding: line, as: UTF8.self))
    }

    /// Ends the body. It returns an event that no blank line closed.
    mutating func finish() -> SSEEvent? {
        if !line.isEmpty, let e = take(String(decoding: line, as: UTF8.self)) { return e }
        line = []
        return take("")
    }

    private mutating func take(_ l: String) -> SSEEvent? {
        if l.isEmpty {
            defer {
                event = ""
                data = []
                size = 0
            }
            return data.isEmpty ? nil : SSEEvent(event: event, data: data.joined(separator: "\n"))
        }
        if l.hasPrefix(":") { return nil }
        let (field, value) = Self.split(l)
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }

    private static func split(_ l: String) -> (String, String) {
        guard let i = l.firstIndex(of: ":") else { return (l, "") }
        var v = l[l.index(after: i)...]
        if v.first == " " { v = v.dropFirst() }
        return (String(l[..<i]), String(v))
    }

    struct TooLarge: Error, CustomStringConvertible {
        var description: String { "server-sent event exceeds 16 MiB" }
    }
}

extension URLSession.AsyncBytes {
    /// The events of the body.
    var events: AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { c in
            let t = Task {
                var d = SSEDecoder()
                do {
                    for try await b in self {
                        if let e = try d.feed(b) { c.yield(e) }
                    }
                    if let e = d.finish() { c.yield(e) }
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}
