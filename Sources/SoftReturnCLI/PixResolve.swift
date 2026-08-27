import CtrlKD

/// Resolve a WordStar pix tag (symmetric type 0x10, a DOS filename payload) to a real
/// `.PIX` file sitting somewhere near the document that references it, then decode it —
/// the filesystem-touching half of ctrl-kd's `piximg.py`/`pictures.py`. Lives here
/// (SoftReturnCLI), not in the Foundation-free `CtrlKD` engine target, because it needs
/// real directory listing; `CLIEnvironment.listDirectory`/`.isFile` supply that
/// testably, the same injection pattern `Run.swift` already uses for every other
/// filesystem touch.
///
/// RULED (Jon, 2026-08-17/18 — WordStar-Feature-Decision-Register.md, "PIX images
/// RULED IN"). The tags carry ABSOLUTE DOS PATHS (e.g.
/// `C:\WS\INSET\PIX\WORDSTAR.PIX`), captured from whatever machine authored the
/// document decades ago — the drive and the leading directories are meaningless on the
/// machine doing the conversion today, but the TAIL of that path is real evidence of
/// where the image sat relative to the document. Resolution order, in full:
///
///   1. Parse the DOS path into components (drive letter dropped). Build its TAIL
///      SUFFIXES — the full component list, then with the first component dropped,
///      then the first two dropped, ... down to just the bare filename. Try each
///      suffix, LONGEST first (most specific), against the document's own directory,
///      then each ancestor directory in turn (nearest first).
///   2. If nothing matched, fall back to basename probing: the bare filename alone in
///      the SAME probe order of locations — same-dir, then `INSET/PIX/`, `INSET/`,
///      then the logical modern conventions `media/`, `attachments/`, `images/`.
///
/// Matching is CASE-INSENSITIVE throughout (DOS heritage: 8.3 names, no case
/// distinction ever existed in the source data) even though the filesystems this runs
/// on today are typically case-sensitive.
///
/// Degradation: this only LOCATES a file; it makes no claim the bytes are the SAME
/// image the original DOS machine resolved. A missing file is reported by returning
/// `nil` — callers surface that as a diagnose-visible fact and render nothing better
/// than a placeholder, never raise (RULED 2026-08-17: "proper error handling for
/// missing/unreadable image files is required (report, never fail the conversion)").

/// Fixed probe locations tried (each relative to the document's own directory, then
/// each ancestor) once the DOS-path tail-suffix walk turns up nothing. Order matters:
/// same-dir first, then the two Inset-native conventions, then the three modern ones.
/// An empty array means "the probe directory itself" (same-dir).
private let basenameProbes: [[String]] = [
    [],
    ["INSET", "PIX"],
    ["INSET"],
    ["media"],
    ["attachments"],
    ["images"],
]

/// Python's `str.strip()` (ASCII/Unicode whitespace both ends) — this module's own
/// tiny mirror of `CtrlKD/Whitespace.swift`'s internal `trimmed()`, which is not
/// `public` and so isn't visible across the module boundary.
private func stripWhitespace(_ s: String) -> String {
    var scalars = Substring(s)
    while let f = scalars.first, f.isWhitespace { scalars = scalars.dropFirst() }
    while let l = scalars.last, l.isWhitespace { scalars = scalars.dropLast() }
    return String(scalars)
}

/// A pix tag's raw payload -> path components, drive letter and any trailing NUL
/// padding dropped. Port of `_parse_dos_path`.
func parseDOSPath(_ payload: String) -> [String] {
    var text = String(payload.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)[0])
    text = stripWhitespace(text)
    let scalars = Array(text.unicodeScalars)
    if scalars.count >= 2, scalars[1] == ":" {
        text = String(String.UnicodeScalarView(scalars[2...]))
    }
    return text.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
}

/// `[a, b, c] -> [[a,b,c], [b,c], [c]]` — longest (most specific) first. Port of
/// `_tail_suffixes`.
private func tailSuffixes(_ parts: [String]) -> [[String]] {
    (0..<parts.count).map { Array(parts[$0...]) }
}

/// `start` itself, then each parent, nearest first, up to `maxUp` levels or the
/// filesystem root, whichever comes first. Port of `_ancestors`.
private func ancestors(_ start: String, maxUp: Int) -> [String] {
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

/// Walk `components` under `base`, matching each one case-insensitively against the
/// real directory listing. Returns the real, correctly-cased path if every component
/// was found and the result is a file; `nil` otherwise — never "throws" on a
/// missing/unreadable directory (the injected closures already degrade to `nil`/
/// `false` rather than raising). Port of `_ci_resolve`.
private func ciResolve(_ base: String, _ components: [String],
                       environment: CLIEnvironment) -> String? {
    var cur = base
    for comp in components {
        guard let entries = environment.listDirectory(cur) else { return nil }
        let target = comp.lowercased()
        guard let match = entries.first(where: { $0.lowercased() == target }) else { return nil }
        cur = joinPath(cur, match)
    }
    return environment.isFile(cur) ? cur : nil
}

/// Resolve a pix tag's payload to a real file path near `docPath` (the WordStar
/// document that referenced it), per the ruled resolution order above. Returns `nil`
/// if no candidate exists. Port of `resolve_pix`.
func resolvePix(_ tagPayload: String, docPath: String, environment: CLIEnvironment,
                maxAncestors: Int = 8) -> String? {
    let parts = parseDOSPath(tagPayload)
    guard !parts.isEmpty else { return nil }

    let docDir = environment.isFile(docPath) ? dirname(docPath) : docPath
    let ancs = ancestors(docDir, maxUp: maxAncestors)

    for anc in ancs {
        for suf in tailSuffixes(parts) {
            if let hit = ciResolve(anc, suf, environment: environment) { return hit }
        }
    }

    let basename = parts[parts.count - 1]
    for anc in ancs {
        for probe in basenameProbes {
            if let hit = ciResolve(anc, probe + [basename], environment: environment) { return hit }
        }
    }
    return nil
}

/// Reconstruct, in the SAME order `resolvePix` tries them, the full candidate paths a
/// miss was checked against — for diagnostics only. Port of `probe_candidates`.
func probePixCandidates(_ tagPayload: String, docPath: String, environment: CLIEnvironment,
                        maxAncestors: Int = 8) -> [String] {
    let parts = parseDOSPath(tagPayload)
    guard !parts.isEmpty else { return [] }

    let docDir = environment.isFile(docPath) ? dirname(docPath) : docPath
    let ancs = ancestors(docDir, maxUp: maxAncestors)

    var out: [String] = []
    for anc in ancs {
        for suf in tailSuffixes(parts) {
            out.append(suf.reduce(anc, joinPath))
        }
    }
    let basename = parts[parts.count - 1]
    for anc in ancs {
        for probe in basenameProbes {
            out.append((probe + [basename]).reduce(anc, joinPath))
        }
    }
    return out
}

// ----------------------------------------------------------- resolve + decode + report

/// One `PixResult` per `doc.graphics` entry, in order. `docPath` is falsy (empty) for
/// "no location to search from" (e.g. a library caller holding only bytes in memory) —
/// every tag then reports `.unresolved`, exactly like a genuinely missing file.
/// Decoding happens ONCE per document here regardless of how many output formats get
/// requested — call this once, pass the result array to every emit call for that
/// document. Port of `resolve_document_pictures`.
func resolveDocumentPictures(_ doc: Document, docPath: String, environment: CLIEnvironment) -> [PixResult] {
    var results: [PixResult] = []
    for (idx, rawPath) in doc.graphics.enumerated() {
        var r = PixResult(index: idx, rawPath: rawPath)
        guard !docPath.isEmpty else {
            r.error = .unresolved
            results.append(r)
            continue
        }
        guard let resolved = resolvePix(rawPath, docPath: docPath, environment: environment) else {
            r.error = .unresolved
            results.append(r)
            continue
        }
        r.resolvedPath = resolved
        guard let data = try? environment.readFile(resolved) else {
            r.error = .unreadable
            results.append(r)
            continue
        }
        r.rawBytes = data
        do {
            let (gcols, grows, _) = try pixDecode(data)
            let png = try pixToPNG(data)
            r.gcols = gcols
            r.grows = grows
            r.png = png
        } catch PixError.textModeUnsupported {
            r.error = .textMode
            results.append(r)
            continue
        } catch {
            r.error = .formatError
            results.append(r)
            continue
        }
        if let size = pixPhysicalSizeIn(data) {
            r.widthIn = size.widthIn
            r.heightIn = size.heightIn
        }
        results.append(r)
    }
    return results
}

/// One stderr line per unresolved/undecodable tag: "report, never fail" (ruled
/// 2026-08-17). Not called automatically anywhere — `Run.swift` calls this once per
/// document after `resolveDocumentPictures`. Port of `report_misses`.
func reportPixMisses(_ results: [PixResult], pathLabel: String, docPath: String,
                     environment: CLIEnvironment, maxAncestors: Int = 8) {
    for r in results {
        guard let error = r.error else { continue }
        let name = pixBasename(r.rawPath)
        switch error {
        case .unresolved, .unreadable:
            let where_: String
            if !docPath.isEmpty {
                let probed = probePixCandidates(r.rawPath, docPath: docPath, environment: environment,
                                                maxAncestors: maxAncestors)
                let shown = Array(probed.prefix(20))
                let more = probed.count > 20 ? " (+\(probed.count - 20) more location(s))" : ""
                where_ = shown.isEmpty ? "" : "; probed: " + shown.joined(separator: ", ") + more
            } else {
                where_ = " (no document path given to search near)"
            }
            let reason = error == .unresolved ? "not found" : "found but not readable"
            environment.writeErr(
                "sr: \(pathLabel): PIX image '\(name)' \(reason)\(where_) -- placeholder kept")
        case .textMode:
            environment.writeErr(
                "sr: \(pathLabel): PIX image '\(name)' is a text-mode (alphanumeric) "
                    + "capture -- not previewable in WordStar either, decoding not implemented "
                    + "-- placeholder kept")
        case .formatError:
            environment.writeErr(
                "sr: \(pathLabel): PIX image '\(name)' could not be decoded (malformed "
                    + "or an unsupported .PIX shape) -- placeholder kept")
        }
    }
}

/// Write every successfully-decoded image as a PNG file under `imagesDir` (created if
/// needed), named from the tag's own basename (deduplicated when two tags share one).
/// Returns `{index: filename}` (bare filename, not a path — callers join it under
/// whatever relative prefix their own output uses). Used for `--pictures export`
/// (every applicable format), AND for MD's embed mode (ruled degradation: MD has no
/// true embed, so "embed" for MD means "export files + one stderr note"). Port of
/// `write_export_images`.
func writeExportImages(_ results: [PixResult], imagesDir: String,
                       environment: CLIEnvironment) -> [Int: String] {
    var written: [Int: String] = [:]
    let okResults = results.filter { $0.ok }
    guard !okResults.isEmpty else { return written }
    guard (try? environment.createDirectory(imagesDir)) != nil else { return written }
    var used: Set<String> = []
    for r in okResults {
        let base = stem(pixBasename(r.rawPath))
        let stemName = base.isEmpty ? "image\(r.index)" : base
        var name = stemName + ".png"
        var n = 1
        while used.contains(name) {
            name = "\(stemName)-\(n).png"
            n += 1
        }
        used.insert(name)
        guard let png = r.png, (try? environment.writeFile(joinPath(imagesDir, name), png)) != nil else {
            continue
        }
        written[r.index] = name
    }
    return written
}
