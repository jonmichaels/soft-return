import CoreGraphics
import Foundation

/// THE APP'S OWN PDF, IN CTRL-KD'S ENGINE-WORDS SCHEMA.
///
/// ## Why this exists
///
/// `AppNativeFidelityTests` measures the app's Native facsimile against the real WordStar
/// captures using ctrl-kd's own tolerance model. Handing that gate a PDF does not work, and
/// the first armed run proved it: every word on all 18 documents came back `pdf=None`, "no
/// corresponding word anywhere". ctrl-kd's `tools/fidelity_gate.py` extracts words with a
/// regex over ITS OWN emitter's op shape — its docstring says so outright, "Every
/// text-drawing operation `pdf.py` writes has one shape: `BT /Fn SIZE Tf [SCALE Tz ]RISE Ts
/// X Y Td (TEXT) Tj ET`". The app's Native view is Quartz, which positions with `Tm` and
/// draws with `TJ` arrays, so that regex matches zero ops against it.
///
/// ctrl-kd 3292630 added the fix: `--engine-words FILE`, a pre-extracted substitute for the
/// PDF, so a PDF written by ANY emitter is judged by the exact same matching and tolerance
/// machinery. The tolerance model stays the oracle; only the emitter-specific extractor is
/// replaced. This type is the app's half — it produces that JSON from the app's own bytes.
///
/// ## Why CGPDFScanner and not PDFKit
///
/// The schema's `y_top_pt` is the BASELINE, and the tolerance model works at sub-point
/// resolution. `PDFSelection.bounds(for:)` and `PDFPage.characterBounds(at:)` return a glyph
/// BOX (ascent+descent), not a baseline, so using them means deriving the baseline from a
/// font descent — an approximation, carried into a coordinate gate, exactly where an
/// approximation must not go. A content-stream scan reads the text matrix itself, where the
/// baseline is the translation component and is therefore exact by construction, with no
/// font metrics involved in `y` at all.
///
/// Font metrics are needed only to advance `x` WITHIN a shown string, to split it into
/// words. That comes from the font's own `/Widths` (or `/W` for a CID font), in 1/1000 em,
/// which is the same number the viewer uses — not a guess.
///
/// ## Coordinate conventions, both of which are traps
///
/// PDF space is bottom-left origin with y increasing UP. The schema is page-local
/// top-left origin with y increasing DOWN. So `y_top_pt = pageHeight - baselineY`, using
/// THIS page's own MediaBox height — per page, never a constant, because a document may mix
/// sheet sizes. `x_pt` is the left edge of the word's own first glyph.
enum AppPDFWords {

    // MARK: - The schema (fidelity_gate.py ENGINE_WORDS_SCHEMA_VERSION 1)

    struct Word: Encodable, Sendable {
        let text: String
        let x_pt: Double
        let y_top_pt: Double
        let size_pt: Double
        let font: String?
        let font_class: String
        let page: Int
    }

    struct Raster: Encodable, Sendable {
        let x_pt: Double
        let y_top_pt: Double
        let w_pt: Double
        let h_pt: Double
        let page: Int
    }

    struct Payload: Encodable, Sendable {
        let schema_version: Int
        let n_pages: Int
        let words: [Word]
        let rasters: [Raster]
    }

    /// ONE DRAWN CHARACTER — engine-chars schema v2, the form the gate now takes.
    ///
    /// This is what the app emits and it is ALL the app emits: `x_pt`/`x_end_pt` are the
    /// glyph's ADVANCE start and end in page-local points with any text-matrix scale already
    /// applied (never the ink box — the segmenter measures the gap between one `x_end_pt`
    /// and the next `x_pt`), `y_top_pt` is the baseline with a top-left origin and y down
    /// and the rise NOT applied, and `font_class` is supplied here rather than derived from
    /// a subset name downstream.
    ///
    /// NO WORD-BOUNDARY LOGIC LIVES ON THIS SIDE ANY MORE. It briefly did — a port of
    /// ctrl-kd's mechanism-Z rule — and a second copy of that rule is exactly what this
    /// schema exists to delete: it segmented the engine's PDF correctly and the app's
    /// Quartz PDF wrongly, and the tier went from 6 failing documents to 18 before the two
    /// underlying bugs (text-matrix scale, reading order) were found. ctrl-kd now segments
    /// both sides with one implementation.
    struct Char: Encodable, Sendable {
        let text: String
        let x_pt: Double
        let x_end_pt: Double
        let y_top_pt: Double
        let size_pt: Double
        let font: String?
        let font_class: String
        let page: Int
    }

    struct CharsPayload: Encodable, Sendable {
        let schema_version: Int
        let n_pages: Int
        let chars: [Char]
        let rasters: [Raster]
    }

    /// `classify_font()`'s vocabulary. The schema requires the PRODUCER to supply this — a
    /// subset name like `ABCDEF+Helvetica` cannot be reclassified downstream by ctrl-kd's
    /// base-14 prefix heuristic — so the mapping lives here and answers `unknown` rather
    /// than guessing.
    static func fontClass(for name: String?) -> String {
        guard let name else { return "unknown" }
        // A subset prefix is exactly six uppercase letters and a '+'. Strip it before
        // matching, or every subset-embedded face classifies as unknown.
        let bare = name.contains("+") ? String(name.split(separator: "+", maxSplits: 1).last!) : name
        let lower = bare.lowercased()
        if lower.contains("courier") || lower.contains("mono") { return "fixed" }
        if lower.contains("symbol") || lower.contains("dingbat") || lower.contains("wingding") {
            return "symbol"
        }
        if lower.contains("helvetica") || lower.contains("arial") || lower.contains("univers")
            || lower.contains("sans") { return "sans" }
        if lower.contains("times") || lower.contains("serif") || lower.contains("roman")
            || lower.contains("garamond") || lower.contains("georgia") { return "serif" }
        return "unknown"
    }

    // MARK: - Extraction

    enum ExtractError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self { case .unreadable(let why): return "AppPDFWords: \(why)" }
        }
    }


    /// RISE SNAPPING — a raised marker belongs to the line it was raised FROM.
    ///
    /// Ported from ctrl-kd's own reader (2026-09-07), which solved the identical problem for
    /// the identical reason. The two producers disagree about a superscript's baseline: the
    /// engine's own schema states the rise is NOT applied to `y`, so its footnote marker sits
    /// on its line's baseline, while a Quartz PDF bakes the rise into the text matrix and the
    /// marker's baseline sits a couple of points above. Read by exact baseline, the app's
    /// marker becomes a LINE OF ITS OWN: a footnoted paper from the private corpus came back
    /// with page 1 at 30 lines against the engine's 26, one extra per footnote reference, and
    /// its pages ran 30/32/33/32/36/33 against 26/28/29/28/29/28 in the same shape.
    ///
    /// So a MINORITY baseline within `riseWindow` of a line's own majority baseline is
    /// snapped to it. Minority by count, because a line is its ordinary text: a marker is one
    /// or two characters against a line's dozens, and the rule must never let a raised RUN
    /// pull a real line onto its neighbour. The window is ctrl-kd's own 8pt — comfortably
    /// more than any rise this corpus uses and comfortably less than any lead.
    ///
    /// The schema is deliberately NOT widened with a rise field. Every consumer of these
    /// payloads asks which LINE a character is on; none asks how far it was raised, and the
    /// engine's own side could only ever answer zero, since its `y` never carried a rise to
    /// begin with. A field that one producer can never populate is not parity, it is a
    /// second way to be wrong.
    static let riseWindow = 6.0

    /// A RAISED RUN IS A FRAGMENT OF ITS LINE, so it is markedly lighter than the lines this
    /// page is made of — and that, not a fixed ratio against its own neighbour, is what tells
    /// the two apart.
    ///
    /// Three rules have been tried here. "Several times lighter than the neighbour it snaps
    /// onto" is false of this corpus's own sub/superscript documents, where whole runs are
    /// raised: SUB-SUPE.TST's "proline: CCA, CCC, CCG, and CCT. For" came apart into
    /// "proline: . For" and a 22-character line of its own, because 22 against 40 is not a
    /// several-fold minority. Dropping the weight test altogether and leaving the WINDOW to do
    /// the work assumes two real lines are always a lead apart and a lead is always more than
    /// 6pt — true of the 12pt default and false of MARKUP.WS, whose whole page is set at a 2pt
    /// lead, so every line on it was strictly heavier than the one above and every one of them
    /// was swallowed. Its page 1 read as a single 300-character line of interleaved words.
    ///
    /// What holds in both is the PAGE's own scale: a raised run is a piece of a line, so it
    /// weighs a fraction of what this page's typical line weighs, whatever the lead happens to
    /// be. A page whose lines are all of a size — MARKUP.WS's, or any ordinary page — has no
    /// such fraction on it and nothing snaps.
    static let raisedRunShare = 0.5

    /// AND TWO PIECES THAT TOGETHER MAKE ABOUT ONE LINE ARE ONE LINE. The share above asks
    /// only about the lighter piece, and a run can be half a line and still be a run:
    /// SUB-SUPE.TST page 2's "smallest possible bit of time." is 29 characters against a page
    /// whose typical line is nearer 56 — outside the share by one character, and plainly a
    /// piece of the 60-character line the engine draws it on.
    ///
    /// Asking what the two make TOGETHER settles that without a finer fraction: a raised run
    /// and its line add up to one line, and two REAL lines add up to two. MARKUP.WS's 2pt-lead
    /// page is 50 against 50 and adds up to twice its own typical line, so nothing on it
    /// merges however close it sits.
    static let mergedLineAllowance = 1.25

    /// The page's typical line weight: the median of every baseline's own weight. Median
    /// rather than mean, so one 300-character run-on or one lone marker cannot move it.
    static func typicalWeight(_ weights: [Double: Int]) -> Double {
        let sorted = weights.values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? Double(sorted[middle - 1] + sorted[middle]) / 2.0
            : Double(sorted[middle])
    }

    /// The snapped baseline for every distinct baseline on one page, keyed by the original.
    ///
    /// `weights` is how many characters sit on each baseline. `sizes` is the type SIZE on
    /// each — and where it is known it outranks every weight rule below, because it is the
    /// thing a raised run actually IS.
    ///
    /// WordStar sets a sup/sub run SMALLER (the engine's own `sized`, two-thirds, and
    /// Mechanism G's per-family ratio), so a reduced run beside a full-size one is a piece of
    /// that line and not a line of its own, whatever either of them weighs. That matters
    /// because weight against the page's typical line has a blind spot this corpus really
    /// contains: -README.WS's tag page is forty rows of "CLARIFY [Clarify]", so its TYPICAL
    /// line is nine characters long and the 12pt half of every row is heavy against it. Seven
    /// characters against nine says nothing; 12pt against 9pt says everything.
    ///
    /// Weight still decides where the sizes are equal or unknown — MARKUP.WS's whole 2pt-lead
    /// page is one size, and the engine's own side carries no sup/sub reduction at all.
    static func snappedBaselines(_ weights: [Double: Int],
                                 sizes: [Double: Double] = [:]) -> [Double: Double] {
        var mapping: [Double: Double] = [:]
        let sorted = weights.keys.sorted()
        let typical = typicalWeight(weights)
        let ceiling = typical * raisedRunShare
        for baseline in sorted {
            let own = weights[baseline] ?? 0
            // ONLY A FRAGMENT SNAPS, and there are two ways to be one: light against this
            // page's own typical line, or light ENOUGH that the pair adds up to a single one.
            // See `raisedRunShare` and `mergedLineAllowance`.
            let candidates = sorted.filter {
                guard $0 != baseline, abs($0 - baseline) <= riseWindow else { return false }
                let other = weights[$0] ?? 0
                // SIZE FIRST, where both baselines have one: smaller type is a reduced run
                // and joins the full-size line beside it; full-size type never joins smaller.
                let ownSize = sizes[baseline] ?? 0
                let otherSize = sizes[$0] ?? 0
                if ownSize > 0, otherSize > 0, abs(ownSize - otherSize) > 0.01 {
                    return ownSize < otherSize
                }
                // STRICTLY HEAVIER, or equal and EARLIER on the page — because a mutual snap
                // is not a merge. SUB-SUPE.TST page 2's line is drawn as a 9pt lowered run
                // and a 12pt one 0.74pt apart, 26 characters each: under a plain "heavier or
                // equal" each chose the other and the pair came back as two lines in swapped
                // order. Breaking the tie toward the earlier baseline sends both to the same
                // place, which is what merging means.
                guard other > own || ($0 < baseline && other == own) else { return false }
                return Double(own) < ceiling
                    || Double(own + other) <= typical * mergedLineAllowance
            }
            let best = candidates.min {
                let left = (weights[$0] ?? 0, -abs($0 - baseline))
                let right = (weights[$1] ?? 0, -abs($1 - baseline))
                return left.0 != right.0 ? left.0 > right.0 : left.1 > right.1
            }
            mapping[baseline] = best ?? baseline
        }
        return mapping
    }

    static func payload(from pdf: [UInt8]) throws -> Payload {
        let data = Data(pdf) as CFData
        guard let provider = CGDataProvider(data: data),
              let document = CGPDFDocument(provider)
        else { throw ExtractError.unreadable("the bytes did not parse as a PDF") }

        var words: [Word] = []
        var rasters: [Raster] = []
        for number in 1...max(document.numberOfPages, 1) {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let state = PageScan(pageNumber: number, pageHeight: Double(box.height),
                                 pageOrigin: (Double(box.origin.x), Double(box.origin.y)))
            state.run(page: page)
            // Segmentation happens once, after every character on the page is known — see
            // `PageScan.segmentedWords()`, which is a port of ctrl-kd's own rule.
            var pageWords = state.segmentedWords()
            var weights: [Double: Int] = [:]
            // The LARGEST type on each baseline: a line's own size, since a line that carries
            // both its body face and something smaller is a line at its body face.
            var sizes: [Double: Double] = [:]
            for word in pageWords {
                weights[word.y_top_pt, default: 0] += word.text.count
                sizes[word.y_top_pt] = max(sizes[word.y_top_pt] ?? 0, word.size_pt)
            }
            let snapped = snappedBaselines(weights, sizes: sizes)
            // A WORD THAT STAYS PUT KEEPS ITS PLACE IN THE DRAWING ORDER; A WORD THAT MOVES
            // TAKES ITS PLACE BY X.
            //
            // Those are the two different things a shared baseline can mean, and each needs
            // the other's rule. An OVERPRINT pass is drawn at the baseline it already has —
            // nothing snaps — and it is a whole run from the margin, so reading it in drawing
            // order keeps it whole where sorting by x would zip it through the line beneath
            // (MICKEE.WS page 12). A raised MARKER is drawn at its own higher baseline and
            // snapped down onto the line, and it belongs where it SITS on that line, not at
            // the front of it — LYING.WS, NOTES.TST, SUB-SUPE.TST and eight pages of a
            // footnoted paper from the private corpus all read "1 the sentence." for "the
            // sentence.1" when a snapped word simply kept the order its own original baseline
            // was visited in.
            var placed: [Word] = []
            var moved: [Word] = []
            for word in pageWords {
                let target = snapped[word.y_top_pt] ?? word.y_top_pt
                guard target != word.y_top_pt else {
                    placed.append(word)
                    continue
                }
                moved.append(Word(text: word.text, x_pt: word.x_pt, y_top_pt: target,
                                  size_pt: word.size_pt, font: word.font,
                                  font_class: word.font_class, page: word.page))
            }
            for word in moved {
                let index = placed.firstIndex {
                    $0.y_top_pt == word.y_top_pt && $0.x_pt > word.x_pt
                } ?? placed.lastIndex { $0.y_top_pt == word.y_top_pt }.map { $0 + 1 }
                    ?? placed.count
                placed.insert(word, at: index)
            }
            pageWords = placed
            words += pageWords
            rasters += state.rasters
        }
        return Payload(schema_version: 1, n_pages: document.numberOfPages,
                       words: words, rasters: rasters)
    }

    /// Leftmost PAINTED glyph per baseline, page-local top-down, for every page.
    /// See `PageScan.firstInkByBaseline()` for why this cannot come from the words.
    static func firstInkByBaseline(from pdf: [UInt8], page wanted: Int) throws -> [Double: Double] {
        let data = Data(pdf) as CFData
        guard let provider = CGDataProvider(data: data),
              let document = CGPDFDocument(provider), let page = document.page(at: wanted)
        else { return [:] }
        let box = page.getBoxRect(.mediaBox)
        let state = PageScan(pageNumber: wanted, pageHeight: Double(box.height),
                             pageOrigin: (Double(box.origin.x), Double(box.origin.y)))
        state.run(page: page)
        var out: [Double: Double] = [:]
        for (baseline, x) in state.firstInkByBaseline() {
            // Same page-local, top-down convention the words use.
            let key = ((Double(box.height) - (baseline - Double(box.origin.y))) * 10).rounded() / 10
            out[key] = min(out[key] ?? .greatestFiniteMagnitude, x - Double(box.origin.x))
        }
        return out
    }

    /// EVERY drawn glyph on one page, grouped by baseline, left to right — x and character.
    ///
    /// `firstInkByBaseline` answers "where does this baseline's ink start", which is the
    /// number the oracle asserts on. This answers "what is actually ON that baseline", which
    /// is the number a FAILURE needs, and the two remaining left-margin rows are why: both
    /// turn on whether the engine wrote a box-drawing character as a text operator where the
    /// app treats it as geometry. Asserting on the first and reporting on neither left that
    /// question needing a hand-run dump every time.
    ///
    /// Graphics are NOT filtered here. The whole point is to see whether a `graphicChars`
    /// member appears in the engine's text operators at all — filtering them would erase the
    /// evidence. It is called only on a failing row.
    static func inkRunsByBaseline(from pdf: [UInt8], page wanted: Int)
        -> [Double: [(x: Double, text: Character)]] {
        let data = Data(pdf) as CFData
        guard let provider = CGDataProvider(data: data),
              let document = CGPDFDocument(provider), let page = document.page(at: wanted)
        else { return [:] }
        let box = page.getBoxRect(.mediaBox)
        let state = PageScan(pageNumber: wanted, pageHeight: Double(box.height),
                             pageOrigin: (Double(box.origin.x), Double(box.origin.y)))
        state.run(page: page)
        var out: [Double: [(x: Double, text: Character)]] = [:]
        for glyph in state.glyphs {
            // Same page-local, top-down key `firstInkByBaseline` uses, so a caller can look
            // up with the key it already matched on.
            let key = ((Double(box.height) - (glyph.baseline - Double(box.origin.y))) * 10)
                .rounded() / 10
            out[key, default: []].append((glyph.xStart - Double(box.origin.x), glyph.text))
        }
        for key in out.keys { out[key]?.sort { $0.x < $1.x } }
        return out
    }

    /// That run rendered for a failure message: the line's text, then the leftmost few marks
    /// with their x, so "the engine's first text ink is at 14.40" can be read as "because it
    /// drew `░` there as a text operator".
    static func describeInkRun(_ run: [(x: Double, text: Character)], limit: Int = 6) -> String {
        guard !run.isEmpty else { return "<no text operators on this baseline>" }
        let text = String(run.map(\.text)).prefix(48)
        let marks = run.prefix(limit)
            .map { String(format: "%@@%.2f", String($0.text), $0.x) }
            .joined(separator: " ")
        return "\"\(text)\" [\(marks)]"
    }

    /// The app's PDF as engine-chars v2: every drawn character, no segmentation.
    static func charsPayload(from pdf: [UInt8]) throws -> CharsPayload {
        let data = Data(pdf) as CFData
        guard let provider = CGDataProvider(data: data),
              let document = CGPDFDocument(provider)
        else { throw ExtractError.unreadable("the bytes did not parse as a PDF") }

        var chars: [Char] = []
        var rasters: [Raster] = []
        for number in 1...max(document.numberOfPages, 1) {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let state = PageScan(pageNumber: number, pageHeight: Double(box.height),
                                 pageOrigin: (Double(box.origin.x), Double(box.origin.y)))
            state.run(page: page)
            var pageChars = state.emittedChars()
            var weights: [Double: Int] = [:]
            for char in pageChars { weights[char.y_top_pt, default: 0] += 1 }
            let snapped = snappedBaselines(weights)
            pageChars = pageChars.map { char in
                let target = snapped[char.y_top_pt] ?? char.y_top_pt
                guard target != char.y_top_pt else { return char }
                return Char(text: char.text, x_pt: char.x_pt, x_end_pt: char.x_end_pt,
                            y_top_pt: target, size_pt: char.size_pt, font: char.font,
                            font_class: char.font_class, page: char.page)
            }
            chars += pageChars
            rasters += state.rasters
        }
        return CharsPayload(schema_version: 2, n_pages: document.numberOfPages,
                            chars: chars, rasters: rasters)
    }

    static func charsJSON(from pdf: [UInt8]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(charsPayload(from: pdf))
    }

    static func json(from pdf: [UInt8]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload(from: pdf))
    }
}
