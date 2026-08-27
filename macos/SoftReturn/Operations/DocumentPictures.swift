import CtrlKD
import Foundation

/// Resolve a document's `.PIX` image references against the real filesystem — the app's own
/// copy of `soft-return`'s `SoftReturnCLI/PixResolve.swift`, because that logic needs real
/// directory listing (`FileManager`) and lives in a Foundation-based target the app cannot
/// import: `SoftReturnCLI` is a package TARGET, not one of `soft-return`'s exposed `products`
/// (only `CtrlKD` is), and the worker has no push access to that separate repo to change that
/// (see the engine-repo-no-push-creds note). `CtrlKD` itself stays Foundation-free by design
/// (`Package.swift`'s own platform-floor ruling), so this is exactly the situation
/// `PixResolve.swift`'s own header describes for why it isn't part of `CtrlKD` either — the
/// app is in the same position `SoftReturnCLI` is, one level further out.
///
/// The resolution ALGORITHM below (DOS-path tail suffixes, longest first, walked against the
/// document's own directory then each ancestor, then a basename probe against a fixed set of
/// legacy/modern locations, case-insensitive throughout) is a deliberate byte-for-byte port of
/// `resolvePix`/`resolveDocumentPictures` — kept in lockstep on purpose, not left to drift,
/// exactly as `soft-return`'s own CLAUDE.md rules divergence between the Python and Swift
/// engines. Decoding itself (`pixDecode`/`pixToPNG`/`pixPhysicalSizeIn`) is NOT duplicated —
/// those live in `CtrlKD` (Foundation-free, no real-filesystem need) and are called directly.
enum DocumentPictures {

    /// Fixed probe locations tried (each relative to the document's own directory, then each
    /// ancestor) once the DOS-path tail-suffix walk turns up nothing. Same order as
    /// `PixResolve.swift`'s own `basenameProbes`: same-dir first, then the two Inset-native
    /// conventions, then the three modern ones.
    private static let basenameProbes: [[String]] = [
        [],
        ["INSET", "PIX"],
        ["INSET"],
        ["media"],
        ["attachments"],
        ["images"],
    ]

    /// One `PixResult` per `doc.graphics` entry, in order — same contract as the engine's own
    /// `resolveDocumentPictures`: decode once per document regardless of how many output
    /// formats get requested, and a `docPath` with nothing to search from (empty) reports every
    /// tag `.unresolved` rather than attempting anything. A missing/unreadable/undecodable
    /// image is reported via `PixResult.error`, never thrown — the ruling this mirrors
    /// (2026-08-17: "proper error handling for missing/unreadable image files is required
    /// (report, never fail the conversion)") applies here exactly as it does in the CLI.
    static func resolve(_ doc: CtrlKD.Document, docPath: String,
                        fileManager: FileManager = .default) -> [PixResult] {
        guard !doc.graphics.isEmpty else { return [] }
        var results: [PixResult] = []
        results.reserveCapacity(doc.graphics.count)
        for (idx, rawPath) in doc.graphics.enumerated() {
            var r = PixResult(index: idx, rawPath: rawPath)
            guard !docPath.isEmpty,
                  let resolved = resolvePix(rawPath, docPath: docPath, fileManager: fileManager) else {
                r.error = .unresolved
                results.append(r)
                continue
            }
            r.resolvedPath = resolved
            guard let data = fileManager.contents(atPath: resolved) else {
                r.error = .unreadable
                results.append(r)
                continue
            }
            let bytes = [UInt8](data)
            r.rawBytes = bytes
            do {
                let (gcols, grows, _) = try pixDecode(bytes)
                r.gcols = gcols
                r.grows = grows
                r.png = try pixToPNG(bytes)
            } catch PixError.textModeUnsupported {
                r.error = .textMode
                results.append(r)
                continue
            } catch {
                r.error = .formatError
                results.append(r)
                continue
            }
            if let size = pixPhysicalSizeIn(bytes) {
                r.widthIn = size.widthIn
                r.heightIn = size.heightIn
            }
            results.append(r)
        }
        return results
    }

    // MARK: - Resolution (port of PixResolve.swift)

    private static func resolvePix(_ tagPayload: String, docPath: String,
                                   fileManager: FileManager, maxAncestors: Int = 8) -> String? {
        let parts = parseDOSPath(tagPayload)
        guard !parts.isEmpty else { return nil }

        var isDir: ObjCBool = false
        let docExists = fileManager.fileExists(atPath: docPath, isDirectory: &isDir)
        let docDir = (docExists && !isDir.boolValue) ? dirname(docPath) : docPath
        let ancs = ancestors(docDir, maxUp: maxAncestors)

        for anc in ancs {
            for suf in tailSuffixes(parts) {
                if let hit = ciResolve(anc, suf, fileManager: fileManager) { return hit }
            }
        }

        let basename = parts[parts.count - 1]
        for anc in ancs {
            for probe in basenameProbes {
                if let hit = ciResolve(anc, probe + [basename], fileManager: fileManager) { return hit }
            }
        }
        return nil
    }

    /// A pix tag's raw payload -> path components, drive letter and any trailing NUL padding
    /// dropped. Port of `parseDOSPath`.
    private static func parseDOSPath(_ payload: String) -> [String] {
        var text = String(payload.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)[0])
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(text.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":" {
            text = String(String.UnicodeScalarView(scalars[2...]))
        }
        return text.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
    }

    /// `[a, b, c] -> [[a,b,c], [b,c], [c]]` — longest (most specific) first.
    private static func tailSuffixes(_ parts: [String]) -> [[String]] {
        (0..<parts.count).map { Array(parts[$0...]) }
    }

    /// `start` itself, then each parent, nearest first, up to `maxUp` levels or the filesystem
    /// root, whichever comes first.
    private static func ancestors(_ start: String, maxUp: Int) -> [String] {
        var out = [start]
        var cur = start
        for _ in 0..<maxUp {
            let parent = dirname(cur)
            if parent == cur || parent.isEmpty { break }
            out.append(parent)
            cur = parent
        }
        return out
    }

    /// Walk `components` under `base`, matching each one case-insensitively against the real
    /// directory listing. Returns the real, correctly-cased path if every component was found
    /// and the result is a file; `nil` otherwise.
    private static func ciResolve(_ base: String, _ components: [String],
                                  fileManager: FileManager) -> String? {
        var cur = base
        for comp in components {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: cur) else { return nil }
            let target = comp.lowercased()
            guard let match = entries.first(where: { $0.lowercased() == target }) else { return nil }
            cur = joinPath(cur, match)
        }
        var isDir: ObjCBool = false
        return (fileManager.fileExists(atPath: cur, isDirectory: &isDir) && !isDir.boolValue) ? cur : nil
    }

    // MARK: - Tiny path helpers (port of SoftReturnCLI/Paths.swift — `os.path`, not `NSString`,
    // semantics: `NSString.deletingLastPathComponent`/`.appendingPathComponent` normalize and
    // treat a dot-leading name as an extension in ways `os.path` does not).

    private static func dirname(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        let head = String(path[..<slash])
        return head.isEmpty ? "/" : head
    }

    private static func joinPath(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        if name.hasPrefix("/") { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
