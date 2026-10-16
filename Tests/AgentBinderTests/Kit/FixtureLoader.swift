import Foundation
import Testing

@testable import AgentBinder

/// Reads the recorded frames in `Tests/Fixtures` and checks events against golden files.
enum Fixtures {
    /// `AGENTBINDER_UPDATE_GOLDEN=1` writes the golden files again.
    static let updateKey = "AGENTBINDER_UPDATE_GOLDEN"

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    /// The fixtures with an extension under a folder, as paths relative to ``root``, sorted.
    static func list(_ folder: String, ext: String = "ndjson") -> [String] {
        let base = url(folder)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }
            .map { folder + "/" + $0.path.dropFirst(base.path.count + 1) }.sorted()
    }

    /// The frames of an NDJSON fixture, without blank lines.
    static func lines(_ rel: String) throws -> [Data] {
        let data = try Data(contentsOf: url(rel))
        return data.split(separator: 0x0A).map { Data($0) }.filter { !FrameReader.isBlank($0) }
    }

    static func json(_ rel: String) throws -> JSONValue {
        try #require(JSONValue.parse(try Data(contentsOf: url(rel))))
    }

    /// Feeds each frame of a fixture to an adapter.
    static func parse(_ rel: String, _ adapter: any WireAdapter) throws -> [Event] {
        try lines(rel).flatMap { adapter.parse($0) }
    }

    /// Compares events with `<name>.expected.json` next to the fixture.
    static func expectGolden(
        _ rel: String, _ events: [Event], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let golden = url((rel as NSString).deletingPathExtension + ".expected.json")
        let got = JSONValue.array(events.map(\.snapshot)).prettyString + "\n"
        if ProcessInfo.processInfo.environment[updateKey] == "1" {
            try got.write(to: golden, atomically: true, encoding: .utf8)
            return
        }
        guard let want = try? String(contentsOf: golden, encoding: .utf8) else {
            Issue.record(
                "no golden file \(golden.lastPathComponent); run with \(updateKey)=1", sourceLocation: sourceLocation)
            return
        }
        #expect(got == want, "golden \(golden.lastPathComponent)", sourceLocation: sourceLocation)
    }
}
