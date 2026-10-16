import Foundation

/// POSIX shell word splitting, without expansion.
///
/// Unquoted white space separates words. Single quotes are literal. Double quotes keep white space
/// and honor a backslash before `"`, `\`, `$`, `` ` `` and a newline. A backslash outside quotes
/// escapes the next character. A path with spaces or a literal backslash thus stays one argument.
public enum ShellWords {
    /// Splits a command line into arguments.
    public static func split(_ command: String) -> [String] {
        var out: [String] = []
        var cur: [UInt8] = []
        var started = false
        var quote: UInt8 = 0
        let s = Array(command.utf8)
        func flush() {
            if started {
                out.append(String(decoding: cur, as: UTF8.self))
                cur.removeAll()
                started = false
            }
        }
        var i = 0
        while i < s.count {
            let c = s[i]
            defer { i += 1 }
            switch quote {
            case UInt8(ascii: "'"):
                if c == UInt8(ascii: "'") { quote = 0 } else { cur.append(c) }
                continue
            case UInt8(ascii: "\""):
                if c == UInt8(ascii: "\"") {
                    quote = 0
                } else if c == UInt8(ascii: "\\"), i + 1 < s.count, escapableInDoubleQuotes(s[i + 1]) {
                    i += 1
                    cur.append(s[i])
                } else {
                    cur.append(c)
                }
                continue
            default: break
            }
            switch c {
            case UInt8(ascii: "'"), UInt8(ascii: "\""):
                quote = c
                started = true
            case UInt8(ascii: "\\"):
                if i + 1 < s.count {
                    i += 1
                    cur.append(s[i])
                    started = true
                } else {
                    cur.append(c)
                }
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"):
                flush()
            default:
                cur.append(c)
                started = true
            }
        }
        flush()
        return out
    }

    private static func escapableInDoubleQuotes(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "$"), UInt8(ascii: "`"), UInt8(ascii: "\n"):
            return true
        default: return false
        }
    }
}
