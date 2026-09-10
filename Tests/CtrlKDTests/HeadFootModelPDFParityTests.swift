import Foundation
import Testing
@testable import CtrlKD

/// planning #251 part d (found by the app coder, job 348 follow-up: sawyer/-SCREEN.WS
/// page 1, the app's own BOTHNOTE.WS page 1): `attachHeadFootLinesPrinted` used to SKIP
/// every notes-aware-path page with no `explicitBreakBI` and no columnar merge -- the
/// proxy for ctrl-kd's own bare-Python-list pages -- on the theory there was nothing TO
/// resolve. `runningOps`'s real per-page render loop resolved and DREW their header/
/// footer/auto-page-number regardless: the model said `nil` where the PDF drew "1" at
/// (291.6, 732.0). Two sources of truth that could (and did) disagree.
///
/// This suite is Swift's own INDEPENDENT corpus-wide proof that the fix closed the gap
/// -- the mirror of ctrl-kd's own `tools/verify_head_foot_model.py` (see that file's own
/// header for the full account), but deliberately self-contained: it reads sr's own
/// `Page` structs directly (no JSON round-trip through `emitLayout`) and sr's own
/// rendered PDF bytes, with no reference to ctrl-kd at all. `AnswerKeyParityTests`
/// already proves sr's `layout`/`pdf` cells are byte-identical to ctrl-kd's own oracle
/// (which the Python script checks against real PDF bytes) -- this suite does not lean
/// on that chain; it is a second, independent check from first principles.
///
/// Scope: DEFAULT `EmitOptions()` only. A document rendered with `--headers off` or an
/// explicit `--page-numbers on/off` override is DELIBERATELY out of scope, matching
/// `attachHeadFootLinesPrinted`'s own doc comment: the model always resolves the
/// document's own NATURAL 'auto' state, a flag only ever tells the WRITER whether to
/// draw it -- a different, already-documented divergence, not this defect.
///
/// ## Gating
/// Same `CTRLKD_SAWYER_ARCHIVE` knob every sibling corpus suite in this file uses
/// (`sawyerArchivePath`/`sawyerArchiveArmed`/`sawyerArchiveSkipReason`, declared once in
/// `WSChangeTests.swift`) -- unarmed, `headFootModelParityGateIsArmed` is the one named
/// Skip and the parameterized test collapses to zero cases.
@Suite struct HeadFootModelPDFParityTests {

    // MARK: - Reading a rendered PDF's own object graph

    /// One entry per page content stream, in REAL page order -- walked from the PDF's
    /// own object graph (`/Type /Catalog` -> `/Pages` -> `/Kids` -> each page's own
    /// `/Contents`), mirroring `tools/verify_head_foot_model.py`'s own
    /// `split_page_streams` exactly (byte-for-byte the same algorithm, ported rather
    /// than reimplemented from scratch) -- NOT `ModernRulingsTests.swift`'s
    /// `pdfContentStreams`, whose heuristic "every stream/endstream block" scan would
    /// miscount a page whose own content stream draws no text at all (this writer's own
    /// object layout never embeds any OTHER `stream`/`endstream` pair a real corpus
    /// document reaches with a text-free page, but walking the object graph directly
    /// needs no such assumption).
    struct PDFStructureError: Error, CustomStringConvertible {
        let description: String
    }

    static func objectGraphPageStreams(_ pdf: [UInt8]) throws -> [[UInt8]] {
        guard !contains(pdf, bytes("/Filter")) else {
            var msg = "compressed content stream -- this "
            msg += "suite assumes sr's own always-uncompressed writer"
            throw PDFStructureError(description: msg)
        }
        // `N 0 obj ... endobj` -> (object number, raw body bytes, own stream body if any).
        var objects: [Int: (body: ArraySlice<UInt8>, stream: ArraySlice<UInt8>?)] = [:]
        let objMarker = bytes(" 0 obj")
        let endobjMarker = bytes("endobj")
        let streamOpen = bytes("stream\n")
        let streamClose = bytes("endstream")
        var i = 0
        while i < pdf.count {
            guard let objAt = find(pdf, objMarker, from: i) else { break }
            // Walk backward from `objAt` over the digits of the object number.
            var numStart = objAt
            while numStart > 0, pdf[numStart - 1].isASCIIDigit { numStart -= 1 }
            guard numStart < objAt, let num = Int(latin1(Array(pdf[numStart..<objAt])))
            else { i = objAt + objMarker.count; continue }
            let bodyStart = objAt + objMarker.count
            guard let endAt = find(pdf, endobjMarker, from: bodyStart) else { break }
            let body = pdf[bodyStart..<endAt]
            var stream: ArraySlice<UInt8>? = nil
            if let sOpen = find(Array(body), streamOpen, from: 0),
               let sClose = find(Array(body), streamClose, from: sOpen + streamOpen.count) {
                let base = body.startIndex
                stream = body[(base + sOpen + streamOpen.count)..<(base + sClose)]
            }
            objects[num] = (body, stream)
            i = endAt + endobjMarker.count
        }

        guard let catNum = objects.first(where: { contains(Array($0.value.body), bytes("/Type /Catalog")) })?.key
        else { throw PDFStructureError(description: "no /Type /Catalog object found") }
        guard let pagesNum = refAfter(Array(objects[catNum]!.body), marker: "/Pages ")
        else { throw PDFStructureError(description: "/Type /Catalog has no /Pages reference") }

        func leafPages(_ pagesNum: Int) throws -> [Int] {
            guard let body = objects[pagesNum]?.body else {
                throw PDFStructureError(description: "object \(pagesNum) (/Type /Pages) missing")
            }
            guard let kids = kidsList(Array(body)) else {
                throw PDFStructureError(description: "object \(pagesNum) (/Type /Pages) has no /Kids array")
            }
            var out: [Int] = []
            for kid in kids {
                guard let kidBody = objects[kid]?.body else { continue }
                if contains(Array(kidBody), bytes("/Type /Pages")) {
                    out += try leafPages(kid)
                } else {
                    out.append(kid)
                }
            }
            return out
        }

        var out: [[UInt8]] = []
        for pageNum in try leafPages(pagesNum) {
            guard let pageBody = objects[pageNum]?.body else { out.append([]); continue }
            guard let contentsNum = refAfter(Array(pageBody), marker: "/Contents ") else {
                out.append([]); continue
            }
            out.append(objects[contentsNum]?.stream.map(Array.init) ?? [])
        }
        return out
    }

    /// The integer object number in `"... <marker><N> 0 R ..."`.
    private static func refAfter(_ body: [UInt8], marker: String) -> Int? {
        guard let at = find(body, bytes(marker), from: 0) else { return nil }
        var j = at + marker.count
        var digits: [UInt8] = []
        while j < body.count, body[j].isASCIIDigit { digits.append(body[j]); j += 1 }
        return digits.isEmpty ? nil : Int(latin1(digits))
    }

    /// `/Kids [n1 0 R n2 0 R ...]` -> `[n1, n2, ...]`.
    private static func kidsList(_ body: [UInt8]) -> [Int]? {
        guard let open = find(body, bytes("/Kids ["), from: 0) else { return nil }
        guard let close = find(body, bytes("]"), from: open) else { return nil }
        let inner = Array(body[(open + 7)..<close])
        var nums: [Int] = []
        var j = 0
        while j < inner.count {
            if inner[j].isASCIIDigit {
                var digits: [UInt8] = []
                while j < inner.count, inner[j].isASCIIDigit { digits.append(inner[j]); j += 1 }
                nums.append(Int(latin1(digits))!)
            } else {
                j += 1
            }
        }
        return nums
    }

    private static func find(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard from >= 0, needle.count > 0, from + needle.count <= haystack.count else { return nil }
        var i = from
        while i + needle.count <= haystack.count {
            if Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Expected bytes: `esc`'s own pre-backslash-escape output

    /// `esc()`'s own raw bytes BEFORE its backslash-escaping (which `contentSpans`
    /// already reverses on the PDF side) -- reusing `esc()` itself (the lookalike/
    /// cp1252 pass is `private` to `PDFWriter.swift`) rather than re-deriving its table.
    private static func degrade(_ text: String) -> [UInt8] {
        let escaped = esc(text)
        var out: [UInt8] = []
        var i = 0
        while i < escaped.count {
            if escaped[i] == 0x5C, i + 1 < escaped.count { out.append(escaped[i + 1]); i += 2 }
            else { out.append(escaped[i]); i += 1 }
        }
        return out
    }

    /// `ShownSpan.text` back to the exact original bytes -- it was built from `latin1`,
    /// a 1-byte-1-scalar mapping, so this is an exact inverse.
    private static func rawBytes(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { UInt8($0.value) }
    }

    // MARK: - The check itself

    struct Mismatch: CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    /// Returns every model/PDF disagreement found on `doc`'s own default-options
    /// printed PDF -- empty means every page's head/foot/auto-page-number entry was
    /// found, at the stated (text, x, y), in the real rendered bytes.
    static func mismatches(_ doc: Document) throws -> [Mismatch] {
        let pages = docToPagelines(doc, printed: true)
        let pdf = emitPDF(doc, mode: .printed)
        let pageStreams = try objectGraphPageStreams(pdf)
        guard pageStreams.count >= pages.count else {
            var msg = "PDF has \(pageStreams.count) page content stream(s), "
            msg += "model has \(pages.count) page(s)"
            return [Mismatch(text: msg)]
        }

        var out: [Mismatch] = []
        for (pi, page) in pages.enumerated() {
            let spans = contentSpans(pageStreams[pi])

            if let auto = page.autoPageno {
                let wantX = tenth(auto.x), wantY = tenth(auto.y)
                let wantBytes = degrade(auto.text)
                let found = spans.contains { span in
                    guard let x = span.x, let y = span.y else { return false }
                    return rawBytes(span.text) == wantBytes
                        && tenth(x) == wantX && tenth(y) == wantY
                }
                if !found {
                    var msg = "page \(pi + 1): autoPageno \"\(auto.text)\" "
                    msg += "at (\(wantX), \(wantY)) not drawn anywhere in the PDF's own "
                    msg += "page \(pi + 1) content stream"
                    out.append(Mismatch(text: msg))
                }
            }

            for (kind, lines) in [("header", page.headerLines), ("footer", page.footerLines)] {
                for (li, entry) in (lines ?? []).enumerated() {
                    let runs = hfRuns(entry.text)
                    guard !runs.isEmpty else { continue }   // control-bytes-only slot, writer skips it too
                    let wantY = tenth(entry.y)
                    var wantX = tenth(entry.x)
                    var drawnRuns = runs
                    let proportional = entry.font.map {
                        $0 >= 0 && $0 < doc.fonts.count && doc.fonts[$0].proportional
                    } ?? false
                    if proportional, runs[0].text.trimmed().isEmpty {
                        wantX = tenth(entry.x + Double(runs[0].text.count) * pdfPtPerCol)
                        drawnRuns = Array(runs.dropFirst())
                    }
                    let wantBytes = drawnRuns.flatMap { degrade($0.text) }
                    guard !wantBytes.isEmpty else { continue }
                    let row = spans.filter { $0.y != nil && tenth($0.y!) == wantY }
                        .sorted { ($0.x ?? 0) < ($1.x ?? 0) }
                    guard !row.isEmpty else {
                        var msg = "page \(pi + 1): \(kind)Lines[\(li)] "
                        msg += "\"\(entry.text)\" at y=\(wantY) -- no PDF text drawn on "
                        msg += "that row at all"
                        out.append(Mismatch(text: msg))
                        continue
                    }
                    let gotBytes = row.flatMap { rawBytes($0.text) }
                    if gotBytes != wantBytes {
                        var msg = "page \(pi + 1): \(kind)Lines[\(li)] "
                        msg += "text \(wantBytes) != PDF row text \(gotBytes) at y=\(wantY)"
                        out.append(Mismatch(text: msg))
                    }
                    if let gotX = row.first?.x, tenth(gotX) != wantX {
                        var msg = "page \(pi + 1): \(kind)Lines[\(li)] x "
                        msg += "\(wantX) != PDF row x \(tenth(gotX)) at y=\(wantY)"
                        out.append(Mismatch(text: msg))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Corpus-wide

    @Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
    func headFootModelParityGateIsArmed() {
        #expect(SawyerPresetDriftFixture.loaded != nil)
    }

    static var docNames: [String] {
        guard sawyerArchiveArmed, let docs = SawyerPresetDriftFixture.loaded else { return [] }
        return docs.keys.sorted()
    }

    @Test(arguments: docNames) func headFootModelMatchesPDFCorpusWide(docName: String) throws {
        let entry = try #require(SawyerPresetDriftFixture.loaded?[docName])
        let fileURL = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(entry.path)
        let bytes = [UInt8](try Data(contentsOf: fileURL))
        let doc = try parse(bytes, variant: nil)
        let found = try Self.mismatches(doc)
        #expect(found.isEmpty, "\(docName): \(found.map(\.description).joined(separator: "; "))")
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= 0x30 && self <= 0x39 }
}
