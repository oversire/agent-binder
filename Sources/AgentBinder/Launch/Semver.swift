/// A version of the form `major.minor.patch`.
struct Semver: Comparable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    static func < (a: Semver, b: Semver) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        return a.patch < b.patch
    }

    /// Reports `got >= want`. A version that does not parse is never at least.
    static func atLeast(_ got: String, _ want: String) -> Bool {
        guard let g = Semver(line: got), let w = Semver(line: want) else { return false }
        return g >= w
    }

    /// The first field of a line that spaces separate.
    static func firstToken(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init) ?? ""
    }
}

extension Semver {
    /// Reads `major.minor[.patch]` from a version line. It drops a leading `v`, a pre-release suffix and trailing text.
    init?(line: String) {
        var v = Substring(Semver.firstToken(line))
        if v.hasPrefix("v") { v = v.dropFirst() }
        if let i = v.firstIndex(where: { $0 == "-" || $0 == "+" }), i > v.startIndex { v = v[..<i] }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var n = [0, 0, 0]
        for (i, p) in parts.prefix(3).enumerated() {
            guard let x = Int(p) else { return nil }
            n[i] = x
        }
        self.init(major: n[0], minor: n[1], patch: n[2])
    }
}
