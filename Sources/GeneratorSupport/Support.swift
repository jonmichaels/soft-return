import Foundation

// What the regeneration executables (`generate-answer-key-sr`,
// `generate-sawyer-preset-drift-sr`) share. They are run by hand, never from `swift test`,
// and each writes one reviewed oracle file under `TestDocs/oracle/`.

public struct GeneratorError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// This file lives at `Sources/GeneratorSupport/Support.swift`; the repo root is three
/// components up.
public let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The commit the generator ran at, recorded in the file it writes.
public func gitInfo() throws -> (sha: String, date: String) {
    func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repoRoot.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return (try run(["rev-parse", "HEAD"]), try run(["log", "-1", "--format=%cI", "HEAD"]))
}

public struct SawyerDoc {
    public let name: String
    public let relativePath: String
}

/// ctrl-kd's own answer key (`$CTRLKD_SRC/../tests/answer_key.json`), read purely as a
/// (name, path) LIST of the Sawyer convertible set, never for its cells, so every
/// generator and `AnswerKeyParityTests` agree on what the corpus is. Sorted by name.
public func loadSawyerConvertibleDocs(ctrlkdSrc: String) throws -> [SawyerDoc] {
    let keyPath = URL(fileURLWithPath: ctrlkdSrc).deletingLastPathComponent()
        .appendingPathComponent("tests/answer_key.json")
    let data = try Data(contentsOf: keyPath)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let groups = json["groups"] as? [String: Any],
          let sawyer = groups["sawyer"] as? [String: Any],
          let convertible = sawyer["convertible"] as? [String: Any]
    else {
        throw GeneratorError(message: "\(keyPath.path) did not parse in the expected shape")
    }
    var docs: [SawyerDoc] = []
    for (name, raw) in convertible {
        guard let dict = raw as? [String: Any], let path = dict["path"] as? String else { continue }
        docs.append(SawyerDoc(name: name, relativePath: path))
    }
    return docs.sorted { $0.name < $1.name }
}
