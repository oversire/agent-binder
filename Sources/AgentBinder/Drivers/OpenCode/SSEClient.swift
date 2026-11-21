import Foundation

/// Splits a `text/event-stream` body into the data of its events.
///
/// Only `data:` lines count; the payload carries its own type. A line over the cap is dropped whole,
/// so the stream gets in step again at the next line.
struct SSEParser {
    let maxLine: Int
    private var line: [UInt8] = []
    private var overflow = false
    private var data: [UInt8] = []

    init(maxLine: Int) { self.maxLine = max(maxLine, 1) }

    /// Adds bytes. It returns the events that a blank line completed.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [Data] {
        var out: [Data] = []
        for b in bytes {
            if let f = feed(b) { out.append(f) }
        }
        return out
    }

    /// Adds one byte. It returns the event that a blank line completed.
    mutating func feed(_ b: UInt8) -> Data? {
        if b == 0x0A { return endLine() }
        if overflow { return nil }
        if line.count >= maxLine {
            overflow = true
            line.removeAll(keepingCapacity: true)
            return nil
        }
        line.append(b)
        return nil
    }

    /// Ends the body. It returns the last event when no blank line closed it.
    mutating func finish() -> Data? {
        if !line.isEmpty && !overflow { _ = endLine() }
        line.removeAll(keepingCapacity: true)
        overflow = false
        return flush()
    }

    private mutating func endLine() -> Data? {
        defer {
            line.removeAll(keepingCapacity: true)
            overflow = false
        }
        if overflow { return nil }
        if line.last == 0x0D { line.removeLast() }
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return flush() }
        guard line.starts(with: Self.dataField) else { return nil }
        let rest = String(decoding: line.dropFirst(Self.dataField.count), as: UTF8.self)
        data += Array(rest.trimmingCharacters(in: .whitespaces).utf8)
        data.append(0x0A)
        return nil
    }

    private mutating func flush() -> Data? {
        defer { data.removeAll(keepingCapacity: true) }
        while data.last == 0x0A { data.removeLast() }
        return data.isEmpty ? nil : Data(data)
    }

    private static let dataField = Array("data:".utf8)
}

/// One event-stream connection to `opencode serve`. The stream has no time limit.
struct SSEClient: Sendable {
    let http: OpenCodeHTTP

    /// Reads the stream until the connection ends. `onOpen` runs once the server answers with a
    /// status below 400.
    func run(
        directory: String?, onOpen: @Sendable () -> Void, onEvent: @Sendable (Data) -> Void
    ) async throws {
        var r = http.request("GET", http.wire.eventPath, directory: directory, timeout: .greatestFiniteMagnitude)
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try http.checkOpen()
        let (bytes, resp) = try await http.session.bytes(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            throw AgentBinderError.vendor(
                code: status, message: "\(http.wire.harness) \(http.wire.eventPath): HTTP \(status)")
        }
        onOpen()
        var parser = SSEParser(maxLine: http.maxBytes)
        do {
            for try await b in bytes {
                if let f = parser.feed(b) { onEvent(f) }
            }
        } catch {
            if let f = parser.finish() { onEvent(f) }
            throw error
        }
        if let f = parser.finish() { onEvent(f) }
    }
}
