import Foundation

/// Splits a byte stream into NDJSON frames, with a frame cap.
///
/// A frame longer than the cap is dropped whole, so the next frame still parses.
/// A last line without a newline is still a frame.
struct FrameReader {
    /// The default frame cap. Giant tool payloads fit; a runaway line does not.
    static let defaultMaxBytes = 16 << 20

    enum Frame: Equatable {
        /// One line, without its line end.
        case line(Data)
        /// A line longer than the cap.
        case tooLarge
    }

    let maxBytes: Int
    private var buf = Data()
    private var overflow = false

    init(maxBytes: Int = FrameReader.defaultMaxBytes) {
        self.maxBytes = maxBytes > 0 ? maxBytes : FrameReader.defaultMaxBytes
    }

    /// Adds bytes and returns the frames that they complete.
    mutating func feed(_ chunk: Data) -> [Frame] {
        var out: [Frame] = []
        var rest = chunk[...]
        while let nl = rest.firstIndex(of: 0x0A) {
            let part = rest[rest.startIndex..<nl]
            // The cap counts the newline, as the Go reader does.
            if overflow || buf.count + part.count + 1 > maxBytes {
                out.append(.tooLarge)
            } else {
                buf.append(part)
                out.append(.line(Self.trimCR(buf)))
            }
            buf = Data()
            overflow = false
            rest = rest[(nl + 1)...]
        }
        if !rest.isEmpty && !overflow {
            if buf.count + rest.count > maxBytes {
                overflow = true
                buf = Data()
            } else {
                buf.append(rest)
            }
        }
        return out
    }

    /// Returns the last frame at EOF, if one is left.
    mutating func finish() -> Frame? {
        defer {
            buf = Data()
            overflow = false
        }
        if overflow { return .tooLarge }
        return buf.isEmpty ? nil : .line(Self.trimCR(buf))
    }

    private static func trimCR(_ d: Data) -> Data {
        d.last == 0x0D ? d.dropLast() : d
    }

    /// True when the frame holds only white space.
    static func isBlank(_ d: Data) -> Bool {
        d.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
    }
}
