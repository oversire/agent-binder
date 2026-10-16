/// Reports `got >= want`. A version that does not parse is never at least.
func semverAtLeast(_ got: String, _ want: String) -> Bool {
    guard let g = parseSemver(got), let w = parseSemver(want) else { return false }
    if g.0 != w.0 { return g.0 > w.0 }
    if g.1 != w.1 { return g.1 > w.1 }
    return g.2 >= w.2
}

/// Reads `major.minor[.patch]` from a version line. It drops a leading `v`, a pre-release suffix and trailing text.
func parseSemver(_ s: String) -> (Int, Int, Int)? {
    var v = Substring(firstToken(s))
    if v.hasPrefix("v") { v = v.dropFirst() }
    if let i = v.firstIndex(where: { $0 == "-" || $0 == "+" }), i > v.startIndex { v = v[..<i] }
    let parts = v.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }
    var n = [0, 0, 0]
    for (i, p) in parts.prefix(3).enumerated() {
        guard let x = Int(p) else { return nil }
        n[i] = x
    }
    return (n[0], n[1], n[2])
}

/// The first field of a line that spaces separate.
func firstToken(_ s: String) -> String {
    s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init) ?? ""
}
