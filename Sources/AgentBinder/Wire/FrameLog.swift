import Darwin
import Foundation

/// A debug trail of every frame in and out, one JSON line per frame.
///
/// The log does not redact secrets, so the file has mode 0600.
final class FrameLog: Sendable {
    enum Direction: String {
        case `in`
        case out
    }

    private let fd: Locked<Int32>

    /// Opens the log for append. It makes the file when it does not exist.
    init(path: URL) throws {
        let fd = Darwin.open(path.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw AgentBinderError.launch("frame log \(path.path): \(String(cString: strerror(errno)))")
        }
        self.fd = Locked(fd)
    }

    deinit { close() }

    /// Writes one frame. A frame that is not JSON goes in as a string.
    func write(_ dir: Direction, _ frame: Data) {
        let raw = JSONValue.parse(frame)?.jsonString ?? JSONValue.quote(String(decoding: frame, as: UTF8.self))
        let at = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
        let line = Data("{\"at\":\"\(at)\",\"dir\":\"\(dir.rawValue)\",\"frame\":\(raw)}\n".utf8)
        fd.withLock { fd in
            guard fd >= 0 else { return }
            line.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
        }
    }

    func close() {
        fd.withLock { fd in
            if fd >= 0 { _ = Darwin.close(fd) }
            fd = -1
        }
    }
}
