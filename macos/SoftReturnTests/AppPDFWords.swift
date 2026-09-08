import CoreGraphics
import Foundation

/// THE APP'S OWN PDF, IN CTRL-KD'S ENGINE-WORDS SCHEMA.
///
/// ## Why this exists
///
/// `AppNativeFidelityTests` measures the app's Printed facsimile against the real WordStar
/// captures using ctrl-kd's own tolerance model. Handing that gate a PDF does not work, and
/// the first armed run proved it: every word on all 18 documents came back `pdf=None`, "no
/// corresponding word anywhere". ctrl-kd's `tools/fidelity_gate.py` extracts words with a
/// regex over ITS OWN emitter's op shape — its docstring says so outright, "Every
/// text-drawing operation `pdf.py` writes has one shape: `BT /Fn SIZE Tf [SCALE Tz ]RISE Ts
/// X Y Td (TEXT) Tj ET`". The app's Printed view is Quartz, which positions with `Tm` and
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
            words += state.segmentedWords()
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
            chars += state.emittedChars()
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
