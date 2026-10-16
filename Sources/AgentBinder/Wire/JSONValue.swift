import Foundation

/// A JSON value. Integers and doubles stay apart, so an id `1` goes back on the wire as `1`, not `1.0`.
package enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: decode

    /// Parses one JSON document. It returns nil for text that is not JSON.
    package static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue(any: any)
    }

    package static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    package init(any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.int64Value)
            }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    // MARK: encode

    /// The compact JSON text, with sorted keys.
    package var jsonString: String {
        var out = ""
        write(to: &out)
        return out
    }

    package var jsonData: Data { Data(jsonString.utf8) }

    /// The JSON text with two-space indents and sorted keys, for config files.
    package var prettyString: String {
        var out = ""
        writePretty(to: &out, level: 0)
        return out
    }

    private func writePretty(to out: inout String, level: Int) {
        let pad = String(repeating: "  ", count: level + 1)
        let end = String(repeating: "  ", count: level)
        switch self {
        case .array(let a) where !a.isEmpty:
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += pad
                v.writePretty(to: &out, level: level + 1)
                out += i < a.count - 1 ? ",\n" : "\n"
            }
            out += end + "]"
        case .object(let o) where !o.isEmpty:
            out += "{\n"
            let keys = o.keys.sorted()
            for (i, k) in keys.enumerated() {
                out += pad
                JSONValue.writeString(k, to: &out)
                out += ": "
                o[k]!.writePretty(to: &out, level: level + 1)
                out += i < keys.count - 1 ? ",\n" : "\n"
            }
            out += end + "}"
        default:
            write(to: &out)
        }
    }

    /// One NDJSON frame: the JSON text and a newline.
    package var frame: Data { Data((jsonString + "\n").utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isFinite {
                if d == d.rounded(), abs(d) < 1e15 {
                    out += String(format: "%.1f", d)
                } else {
                    out += "\(d)"
                }
            } else {
                out += "null"
            }
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(k, to: &out)
                out += ":"
                o[k]!.write(to: &out)
            }
            out += "}"
        }
    }

    package static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    /// The JSON text of a string, with quotes and escapes.
    package static func quote(_ s: String) -> String {
        var out = ""
        writeString(s, to: &out)
        return out
    }

    // MARK: access

    package subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    package subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    /// Walks a path of object keys.
    package func at(_ path: String...) -> JSONValue? {
        var v: JSONValue? = self
        for k in path { v = v?[k] }
        return v
    }

    package var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The text of a content value: a string as it is, or the text fields of a block list.
    package var flattenedText: String {
        switch self {
        case .string(let s): return s
        case .array(let items):
            return items.compactMap { $0["text"]?.string }.filter { !$0.isEmpty }.joined(separator: "\n")
        default: return ""
        }
    }

    package var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded() && abs(d) < 9.2e18: return Int64(d)
        default: return nil
        }
    }

    package var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    package var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    package var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    package var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    package var isNull: Bool { self == .null }

    /// A string value, or the JSON text of any other value. Nil and null give an empty string.
    package var text: String {
        switch self {
        case .string(let s): return s
        case .null: return ""
        default: return jsonString
        }
    }
}

extension Optional where Wrapped == JSONValue {
    /// The string value, or an empty string.
    package var stringValue: String { self?.string ?? "" }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral
{
    package init(stringLiteral value: String) { self = .string(value) }
    package init(integerLiteral value: Int64) { self = .int(value) }
    package init(booleanLiteral value: Bool) { self = .bool(value) }
    package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    package init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    package init(floatLiteral value: Double) { self = .double(value) }
    package init(nilLiteral: ()) { self = .null }
}

extension JSONValue: Codable {
    package init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
