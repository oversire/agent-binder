import Foundation

/// The leading YAML frontmatter of a document, in the subset that `SKILL.md` files use.
///
/// It reads flat `key: value` pairs, quoted values and the `>` and `|` block scalars.
/// It skips nested mappings; it does not parse them wrong.
package struct Frontmatter: Equatable {
    package var values: [String: String]

    package subscript(key: String) -> String? { values[key] }

    package init(_ text: String) {
        values = [:]
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return }
        var i = 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            i += 1
            // An indented line belongs to a nested block of the key above it.
            if trimmed.isEmpty || trimmed.hasPrefix("#") || line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch value {
            case ">", ">-", ">+", "|", "|-", "|+":
                let (block, next) = Frontmatter.blockScalar(lines, start: i, literal: value.hasPrefix("|"))
                values[key] = block
                i = next
            default:
                values[key] = Frontmatter.unquote(value)
            }
        }
    }

    // Returns the block with its style, and the index of the first line after it.
    private static func blockScalar(_ lines: [String], start: Int, literal: Bool) -> (String, Int) {
        var indent = -1
        var body: [String] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                body.append("")
                i += 1
                continue
            }
            let lead = line.prefix { $0 == " " }.count
            if indent < 0 {
                if lead == 0 { break }
                indent = lead
            }
            if lead < indent { break }
            body.append(String(line.dropFirst(indent)))
            i += 1
        }
        while body.last == "" { body.removeLast() }
        if literal { return (body.joined(separator: "\n") + "\n", i) }
        // Folded: a blank line becomes a newline, a single line break becomes a space.
        var out = ""
        for (j, line) in body.enumerated() {
            if j == 0 {
                out += line
            } else if line.isEmpty {
                out += "\n"
            } else if body[j - 1].isEmpty {
                out += line
            } else {
                out += " " + line
            }
        }
        if !out.isEmpty { out += "\n" }
        return (out, i)
    }

    // Removes matching quotes, and a trailing comment from an unquoted value.
    private static func unquote(_ v: String) -> String {
        if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" {
            let inner = String(v.dropFirst().dropLast())
            if f == "\"" {
                return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        var s = v
        if let r = s.range(of: " #") { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
