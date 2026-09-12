import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// THE MODERN GATE: the app's Modern view puts the same lines on the same pages as the
/// library's own Modern PDF.
///
/// ## What it measures, and what it deliberately does not
///
/// Jon's option B (planning #222): the Modern VIEW stays AppKit, but it must agree with the
/// engine's Modern PDF. What "agree" can mean here is narrower than it is for Native, and the
/// difference decides the whole design.
///
/// Native has real WordStar captures to measure against, and `AppNativeFidelityTests` uses
/// ctrl-kd's tolerance model to check sub-point PLACEMENT. Modern has no capture — WordStar
/// never printed it — and its placement cannot match by construction: the Modern view renders
/// in the user's own chosen font at their own size, which is the documented divergence the
/// build spec calls out and which option B explicitly keeps. A geometric oracle would fail on
/// every document for that reason alone and tell us nothing about what was actually asked
/// for.
///
/// So this gate measures STRUCTURE: the page count, and per page the sequence of line texts.
/// That is exactly what "page and line breaks equal to the library's Modern PDF" means as a
/// measurement, and it catches option B's items where they actually show. Wrong leading or
/// leftover paragraph air moves a page break. A hyphen the engine does not make changes a
/// line's text. A wrong note font changes where the appendix breaks.
///
/// ## The font is pinned, and that is not a dodge
///
/// The app's Modern font and size are set to the engine's own Modern face for the duration of
/// this gate — the engine's fontless Modern body is Times at `modernBodyPt`, notes at
/// `modernNotePt` (`PDFModernLayout.swift`). A reader who picks Georgia at 16pt gets
/// different line breaks, and that is CORRECT behaviour, not a defect: reflowing to the
/// reader's type is what a reading view is for. Pinning the face is what makes line breaks a
/// comparable quantity at all; without it this gate would be asserting that two different
/// fonts wrap identically, which is false and uninteresting.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct AppModernFidelityTests {

    /// The engine's own Modern metrics, vendored rather than imported: `modernBodyPt` and
    /// `modernNotePt` are `internal` to CtrlKD, the same situation `DocumentPictures`' own
    /// header explains for the pix constants. Both are pinned literals in
    /// `PDFModernLayout.swift`, not derived arithmetic, so they carry no drift risk.
    static let engineModernBodyPt = 14
    static let engineModernFace = "Times New Roman"

    /// The same documents `AppNativeFidelityTests` measures — the 12 that can be named in a
    /// file that ships public (planning #243).
    static let documents = AppNativeFidelityTests.documents

    // MARK: - Reading both sides the same way

    /// One page's lines, as the sequence of WORDS on each — not a concatenation of drawn
    /// characters.
    ///
    /// The first version of this did concatenate characters, and it was wrong in a way worth
    /// recording, because it would have been reported as twelve failing documents. The two
    /// emitters represent a space differently: the app draws space GLYPHS, while the library
    /// positions each word with its own offset and draws no space at all. Read character by
    /// character, every library line came back as "HavealookatthisfileunderWordStar's" and
    /// every comparison failed for a reason that has nothing to do with page or line breaks.
    ///
    /// Words are the representation-independent quantity, and `AppPDFWords`' segmentation is
    /// ctrl-kd's own rule applied identically to both sides — the same discipline the Native
    /// gate settled on when it stopped segmenting its own side. Leading indentation
    /// disappears with it, which is correct here: this gate is about WHERE THE BREAKS FALL,
    /// and indentation is placement, which Modern legitimately renders in the reader's own
    /// type.
    static func lines(of pdf: [UInt8]) throws -> [[String]] {
        let payload = try AppPDFWords.payload(from: pdf)
        var byPage: [Int: [Double: [(x: Double, text: String)]]] = [:]
        for word in payload.words {
            // Baselines group to a tenth of a point: a line's own words share a baseline
            // exactly within each emitter, and a tenth is far below any real line gap.
            let baseline = (word.y_top_pt * 10).rounded() / 10
            byPage[word.page, default: [:]][baseline, default: []].append((word.x_pt, word.text))
        }
        var pages: [[String]] = []
        // EVERY PAGE, INCLUDING ONE WITH NO TEXT AT ALL. Walking the keys present skips a
        // page whose whole content the library draws as geometry — and the app, which draws
        // those same characters as text glyphs, still has words on it, so one side's list
        // came back one entry shorter and every page after it was compared against its
        // neighbour. BOXES.WS is the case: its page 4 is nothing but box rows, so the
        // library's payload has no words on it at all, and the gate read the app's page 5
        // against the library's page 4 for the rest of the document.
        let lastPage = byPage.keys.max() ?? 0
        for page in stride(from: 1, through: lastPage, by: 1) {
            guard let pageLines = byPage[page] else { pages.append([]); continue }
            let baselines = pageLines.keys.sorted()              // top-down, y grows downward
            var rendered: [String] = []
            for baseline in baselines {
                // RUNS IN THEIR OWN ORDER, THE RUNS THEMSELVES ORDERED BY WHERE THEY BEGIN.
                //
                // A baseline can carry more than one run — an overprint pass, a knockout, a
                // `.l#` line-number gutter — and neither "sort every word by x" nor "keep the
                // drawing order" is right for all of them. Sorting by x zips two passes
                // through each other (MICKEE.WS page 12 read "UsiTnhge MLIeCfKtE Eb
                // uwthtiolne..."); keeping the drawing order puts the app's line-number
                // gutter AFTER its line, because the app paints it as an overlay while the
                // engine writes it inline first — PRINT.TST page 3 read "Line Numbers 1"
                // against "1 Line Numbers".
                //
                // A run is a maximal stretch whose x keeps increasing, which is what a run of
                // text IS; ordering the runs by their own first x puts the gutter before its
                // line and leaves two passes that both start at the margin in the order both
                // producers drew them (the sort is stable).
                var runs: [[(x: Double, text: String)]] = []
                for word in pageLines[baseline]! {
                    if let last = runs.last?.last, word.x >= last.x {
                        runs[runs.count - 1].append(word)
                    } else {
                        runs.append([word])
                    }
                }
                let run = runs
                    .enumerated()
                    .sorted { left, right in
                        let leftX = left.element.first?.x ?? 0
                        let rightX = right.element.first?.x ?? 0
                        return leftX != rightX ? leftX < rightX : left.offset < right.offset
                    }
                    .flatMap(\.element)
                let text = run.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // A RULE IS NOT A LINE OF TEXT ON EITHER SIDE, and it is only text on one.
                //
                // The engine draws cp437 box drawing in Modern as VECTORS (`graphicOps`), so
                // its PDF carries no text operators for a rule at all; the app draws the same
                // characters as text glyphs. Read as text, an all-graphic line is therefore
                // present on the app side and absent on the library's for every rule in the
                // corpus — a guaranteed mismatch that says nothing about where either side
                // breaks its PROSE, which is what this gate measures.
                //
                // -README page 1 is the case: its 65-character `═` rule measures 644.73pt in
                // the app's Mac face against a 468pt column, so the app wraps it and the
                // wrap pushes the paragraph after it out of step — the library's own line
                // reads "...plain-text version as" while the app's reads "...plain-text
                // version" with an orphaned "as" beneath. Neither is a break decision about
                // that paragraph.
                //
                // The underlying width difference is real and is planning #216/#251 (the
                // engine's cell geometry is not exported, so the app cannot draw these on the
                // library's grid yet). Until it is, comparing them AS TEXT measures the
                // reader, not the renderer.
                let bare = text.filter { !$0.isWhitespace }
                if !bare.isEmpty, bare.allSatisfy({ CtrlKD.graphicChars.contains($0) }) {
                    continue
                }
                rendered.append(text)
            }
            pages.append(rendered)
        }
        return pages
    }

    /// The app's own Modern PDF, rendered with the engine's Modern face pinned.
    @MainActor
    static func appModernPDF(forDocumentNamed name: String, pins: Bool = true) throws -> [UInt8] {
        let url = try #require(AppNativeFidelityTests.resolveSource(name),
                               "\(name): not resolvable in this corpus")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "AppModernFidelity.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.modernFontName = engineModernFace
        settings.modernFontSize = engineModernBodyPt
        let state = try DocumentState(data: bytes, settings: settings, docPath: url.path)
        state.style.setManually(.modern)
        // AND THE DECLARED FACES TOO, not just the fallback. Jon's ruling 2026-09-11: the app
        // keeps drawing a document's own declared typeface in Modern and the engines will not
        // embed fonts, so neither product changes and the COMPARISON has to. Pinning
        // `modernFontName` alone only ever governed a run NO font block covers; a run one
        // does covers resolved to the nearest Mac face (LYING.WS and WARPRAYR.WS declare
        // Garamond, which the app draws as Hoefler Text and the library can only set as
        // Times), and two faces break their lines in different places for a reason that is
        // nobody's defect. See `DocumentRenderer.modernBase14MeasurementPin`.
        DocumentRenderer.modernBase14MeasurementPin = pins
        defer { DocumentRenderer.modernBase14MeasurementPin = false }
        // `pictures: .embed` EXPLICITLY, because `ExportEngine.render`'s own default for it
        // is `SettingsStore.shared.defaultPictures` — the app-wide store, not the private one
        // this function just built for the face — so what the reference embeds and what the
        // app draws depended on a setting neither side of this gate states. -README.WS is the
        // case and it is the mirror image of the one `engineModernPDF` below already records:
        // the library resolved its picture and the app drew "[image: WORDSTAR.PIX]" as a line
        // of TEXT, so page 1 carried a phantom line the reference does not have and every
        // page after it diffed against the wrong one. Both sides resolve now.
        let products = try ExportEngine.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
            style: .modern, title: name, docPath: url.path, pictures: .embed)
        return try #require(products.first?.bytes, "\(name): the app produced no Modern PDF")
    }

    /// The library's own Modern PDF for the same document, WITH ITS PICTURES RESOLVED.
    ///
    /// The `pixResults` argument is not optional decoration: `EmitOptions()`'s own default is
    /// an EMPTY list, and an empty list forces `embedImages` false in every `PDFLayout` body
    /// resolver regardless of what `pictures` says, so every `.PIX` tag falls back to its
    /// literal `[image: NAME]` PLACEHOLDER TEXT. That is job 441's finding, and this gate
    /// walked straight into it: -README's library page 1 opened with a line reading
    /// "[image: WORDSTAR.PIX]" that the app does not have, because the app draws the picture.
    /// One phantom line at the top of page 1 offsets every line after it, so the diff counted
    /// the whole document as divergent — the first divergence this gate reported was its own
    /// reference, not the app.
    ///
    /// Resolved through `DocumentPictures.resolve`, the SAME call `DocumentState.init` and
    /// `PixelOracleAppEngine.renderEngine` already make, so the reference embeds exactly what
    /// a real Modern export would.
    static func engineModernPDF(forDocumentNamed name: String) throws -> [UInt8] {
        let url = try #require(AppNativeFidelityTests.resolveSource(name),
                               "\(name): not resolvable in this corpus")
        let document = parseWS([UInt8](try Data(contentsOf: url)))
        let pixResults = DocumentPictures.resolve(document, docPath: url.path)
        return emitPDF(document, mode: .modern, options: EmitOptions(pixResults: pixResults))
    }

    // MARK: - Comparing two line lists

    /// One page's difference, as a real diff rather than a positional comparison.
    struct PageDiff {
        /// Lines the library has that the app does not.
        let missing: [String]
        /// Lines the app has that the library does not.
        let extra: [String]
        /// Insertions plus deletions — the number of lines that would have to change for
        /// the two pages to agree.
        var editDistance: Int { missing.count + extra.count }
    }

    /// WHY A DIFF AND NOT `app[i] != library[i]`.
    ///
    /// The first version of this gate compared line N against line N. That makes one
    /// inserted line early in a page count as a difference on every line after it, so the
    /// reported number measured MISALIGNMENT, not disagreement — excellent as a pass/fail
    /// gate, useless as a measure of whether a change is helping. It said 1611 places when
    /// the real question was how many lines actually differ.
    ///
    /// A longest common subsequence gives that directly: what is left over on each side is
    /// exactly the lines one has and the other does not, and their sum is the edit distance.
    /// The ASSERTION is unchanged — any difference at all still fails — this only changes
    /// what a failure REPORTS.
    /// A NEEDLE THAT DOES NOT HAVE TO KNOW ABOUT ZERO-WIDTH MARKS.
    ///
    /// Modern inserts two of them, both so AppKit can only break where the library's own
    /// `modernWrap` breaks: U+2060 word joiners inside a token that carries a UAX #14 break
    /// opportunity the library has not got (a hyphen, a solidus, a backslash), and U+200B
    /// where two styled runs meet with no space between them. They paint nothing and the PDF
    /// carries no glyph for either, but they sit in the string every test searches — so a
    /// literal needle like "Thirty-Dollar Prize" or "LL: " stops matching the moment one
    /// lands inside it.
    ///
    /// Matched THROUGH them rather than stripped, because the ranges these tests get back
    /// are used against the real attributed string and its layout: the indices have to be
    /// that string's own.
    static func needleRange(_ needle: String, in haystack: NSString) -> NSRange {
        let pattern = needle.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\u{2060}\u{200B}]*")
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return regex.firstMatch(in: haystack as String,
                                range: NSRange(location: 0, length: haystack.length))?.range
            ?? NSRange(location: NSNotFound, length: 0)
    }

    /// TWO PDF ALPHABETS ARE NOT TWO LINES — `Oracle.EngineText.sameLine`, the same
    /// comparison `theAppPaginatesExactlyLikeTheLibrary` uses on its own two sides, and for
    /// the same reason: a line that differs only in how the two PRODUCERS spell a mark is
    /// not a line the two disagree about.
    ///
    /// Modern's own instance of it is the marks the library draws as GEOMETRY. Its
    /// `modernLineOps` sends every `graphicChars` character to `graphicOps`, which emits
    /// filled rectangles — measured in its own PDF stream, -README.WS's three-square break
    /// row is `87.7 151.4 4.7 4.7 re f` and carries no text at all — while this app draws the
    /// same row as real glyphs in a covering face (`nativePinGraphicCells`' own doc comment:
    /// "these characters are real text in this app's own storage"). Read back as text, the
    /// library's row is empty and the app's is not, on every box rule, every square bullet
    /// and every `│Figure 1│` in the corpus.
    ///
    /// `EngineTextComparisonTests` pins both halves of that rule, including the negative one
    /// this gate depends on: real text can never go missing from either side
    /// (`realTextCannotGoMissing`), an ASCII `?` is not a wildcard, and an ordinary dingbat
    /// is not one either.
    static func sameLine(_ appLine: String, _ libraryLine: String) -> Bool {
        appLine == libraryLine || Oracle.EngineText.sameLine(app: appLine, library: libraryLine)
    }

    static func diff(app: [String], library: [String]) -> PageDiff {
        // Standard LCS table. Pages are tens of lines, so the quadratic table is nothing.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: library.count + 1),
                          count: app.count + 1)
        for i in stride(from: app.count - 1, through: 0, by: -1) {
            for j in stride(from: library.count - 1, through: 0, by: -1) {
                lcs[i][j] = sameLine(app[i], library[j])
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var missing: [String] = [], extra: [String] = []
        var i = 0, j = 0
        while i < app.count, j < library.count {
            if sameLine(app[i], library[j]) { i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { extra.append(app[i]); i += 1 }
            else { missing.append(library[j]); j += 1 }
        }
        extra.append(contentsOf: app[i...])
        missing.append(contentsOf: library[j...])
        return PageDiff(missing: missing, extra: extra)
    }

    // MARK: - The gate

    @Test(arguments: AppModernFidelityTests.documents)
    @MainActor func appModernMatchesTheLibrarysModernPageAndLineBreaks(doc: String) throws {
        let app = try Self.lines(of: Self.appModernPDF(forDocumentNamed: doc))
        let library = try Self.lines(of: Self.engineModernPDF(forDocumentNamed: doc))

        var rows: [String] = []
        var distance = 0
        var pagesDiffering = 0

        // A page the other side does not have at all diffs against nothing, so its whole
        // content counts — which is right: every line on it is a line the two disagree about.
        for page in 0..<max(app.count, library.count) {
            let appPage = page < app.count ? app[page] : []
            let libraryPage = page < library.count ? library[page] : []
            let pageDiff = Self.diff(app: appPage, library: libraryPage)
            guard pageDiff.editDistance > 0 else { continue }
            distance += pageDiff.editDistance
            pagesDiffering += 1
            for line in pageDiff.missing.prefix(3) {
                rows.append("  page \(page + 1): library has \"\(line.prefix(64))\", the app does not")
            }
            for line in pageDiff.extra.prefix(3) {
                rows.append("  page \(page + 1): the app has \"\(line.prefix(64))\", the library does not")
            }
        }

        let pageCounts = app.count == library.count
            ? "page counts agree at \(library.count)"
            : "the app lays out \(app.count) Modern page(s), the library \(library.count)"
        // Edit distance first, then a sample: the number is the quantity a change is judged
        // on, and a bare list of rows with no denominator is the shape of report this tier
        // has been burned by.
        let summary = "\(doc): edit distance \(distance) across \(pagesDiffering) differing "
            + "page(s); \(pageCounts)\n" + rows.prefix(12).joined(separator: "\n")
        #expect(distance == 0, "\(summary)")
    }
}
