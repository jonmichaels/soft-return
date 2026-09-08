import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// THE ORACLE.
///
/// `ctrl-kd` (Python) and `CtrlKD` (Swift) are byte-accurate to each other across 2,119 real
/// files, checked by parity gauntlets. That is why the library landed right. **The app is a
/// third renderer consuming the same numbers, and until this file nothing ever compared it to
/// the two that are proven** — which is why Jon has been the one finding geometry defects, by
/// looking at pages.
///
/// These tests ask the app's own `NSLayoutManager` where it ACTUALLY put the text and check
/// that against `printedMetrics(doc)`, the same façade the PDF emitter uses. The distinction
/// is the whole point: a test that recomputes what the app should have done proves only that
/// the arithmetic was copied consistently. Asking the layout manager what it did is the only
/// way to catch AppKit disagreeing with the library.
///
/// Jon does not verify arithmetic. This file does.
enum Oracle {
    /// Fixtures are read from the SOURCE tree, not the test bundle.
    ///
    /// The project uses a synchronized file group, which does not copy `.ws4`/`.ps` files into
    /// the test bundle as resources — `Bundle.url(forResource:)` returned nil for every one of
    /// them, and the vacuity guard below is what caught it. Deriving the directory from
    /// `#filePath` keeps fixtures next to the test that uses them, with no project-file surgery.
    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static var fixtureURLs: [URL] {
        let names = ["report.ps", "report-no-extension", "boundary.ws4", "narrow.ws4",
                     "no-dot-commands.ws4", "dropped-chapter.ws4"]
        var urls = names
            .map { fixturesDirectory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // Optional extra corpus: widen the gauntlet locally without committing anyone's
        // documents. `CTRLKD_PRIVATE_CORPUS` names the private corpus CLONE ROOT (D3,
        // 2026-09-04: one env var per corpus, one shape, defined by that repo's own README)
        // — a tree of provenance-grouped subdirectories (`sawyer/`, `ws7-private/`,
        // `jon-floppies/`, `fixtures-ws5/`, `pd-samples/`), not a flat folder of documents —
        // so this walks it recursively rather than listing its top level (job 531: unified
        // onto the engine repo's own name -- this app had SOFT_RETURN_EXTRA_FIXTURES/
        // SOFTRETURN_ORACLE_CORPUS as two more names for the same "point me at the private
        // corpus" signal; one name now, everywhere).
        //
        // Planning #192 (2026-09-05): even after the corpus's own documents-only trim, this
        // walk still crosses folders that are never WordStar documents at all by their own
        // corpus README (`ws7-prints/` PCL captures and paper-scan PNGs, `fixtures-ws5/`'s
        // own `PROVENANCE.md`-adjacent siblings, etc.) — a name/extension filter can't tell
        // those from a real document, but the engine's own `detect()` can: an armed run was
        // handing this oracle real binaries (PNGs, PDFs, PCL captures — and, before that trim
        // landed, dictionaries/fonts/macros too) and every downstream consumer of
        // `fixtureURLs` (this file's own geometry tests, `PageBudgetMeasurementTests`) threw
        // `ParseError.notConvertible(variant: .binary, ...)` trying to lay one out. Filtering
        // on `detect()` rather than extension is the same discipline the corpus README itself
        // uses ("never trust `detect()` alone" cuts both ways — corroborate structurally, but
        // don't skip the check either): a file `detect()` calls `.binary` is, by the engine's
        // own classification, not a document this oracle can measure, regardless of name.
        if let extra = ProcessInfo.processInfo.environment["CTRLKD_PRIVATE_CORPUS"],
           let enumerator = FileManager.default.enumerator(
               at: URL(fileURLWithPath: extra), includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                // The hidden-name test has to look at every ANCESTOR, not just the file's own
                // name: `.git/objects/pack/pack-<sha>.pack` has a perfectly ordinary last
                // component, so checking only that walked the corpus clone's own git objects
                // into this oracle. Two of them reached the assertion list as "documents"
                // with measured line geometry, which is how this surfaced.
                let components = fileURL.pathComponents
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      !components.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }),
                      fileURL.pathExtension.lowercased() != "md"
                else { continue }
                // `ws7-prints/` is the WS7 ground-truth PRINT archive, not a document tree:
                // PCL captures, Ghostscript renders, and scans of Jon's own paper printouts.
                // Its own README says so. `detect()` cannot be asked to tell a PCL capture or
                // a scanned PDF from a document reliably enough to be the only gate, and it
                // did not — `DISPLAY.pcl` and all three `m479-scan-doc*.pdf` scans came
                // through it and were measured as if they were WordStar files.
                //
                // Excluded by PATH rather than by extension, because the point is the
                // provenance of the tree, not the spelling of the files in it.
                guard !components.contains("ws7-prints") else { continue }
                guard let bytes = try? Data(contentsOf: fileURL), !bytes.isEmpty,
                      detect([UInt8](bytes)).variant != .binary
                else { continue }
                urls.append(fileURL)
            }
        }
        return urls
    }

    @MainActor
    static func state(for url: URL) throws -> DocumentState {
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Oracle.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
    }

    struct LaidOutPage {
        let textView: NSTextView
        let manager: NSLayoutManager
        let container: NSTextContainer
        let glyphs: NSRange
    }

    /// Render in Printed style through the app's real path and hand back the pages.
    @MainActor
    static func layOut(_ state: DocumentState) -> (RenderedDocument, PagedDocumentView, [LaidOutPage]) {
        state.style.setManually(.printed)
        let rendered = DocumentRenderer.render(state)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        let pages = view.pageViews.compactMap { tv -> LaidOutPage? in
            guard let m = tv.layoutManager, let c = tv.textContainer else { return nil }
            m.ensureLayout(for: c)
            return LaidOutPage(textView: tv, manager: m, container: c, glyphs: m.glyphRange(for: c))
        }
        return (rendered, view, pages)
    }

    /// One laid-out line, as the layout manager reports it.
    struct Line {
        /// Ordinal position on the page — 0 is the first line, blanks included.
        let index: Int
        /// Top of the line fragment, in page coordinates.
        let top: CGFloat
        /// Baseline, in page coordinates. Only meaningful when `hasText`.
        let baseline: CGFloat
        /// Left edge of the line's first INK — the first glyph that is not whitespace.
        /// Only meaningful when `hasText`.
        ///
        /// Not the first GLYPH. A line's leading spaces are glyphs: they are laid out, they
        /// occupy width, and the fragment's first glyph on an indented line is a space
        /// sitting exactly at the margin. Reporting that against a library figure of
        /// `margin + typed columns` made every indented line in the corpus look like the app
        /// had ignored its indent, when the app was placing the ink exactly where the engine
        /// puts it — 20 of 20 rows in the 2026-09-07 run were the margin to the penny, with
        /// `wanted` exactly `margin + typed * 7.2`. Same defect, and the same fix, as the
        /// parity harness's own "both sides now report ink" correction: the two sides were
        /// measuring different things.
        let left: CGFloat
        /// Does this line carry a visible glyph?
        ///
        /// A blank line contains only its newline, which has no visible glyph and therefore no
        /// baseline worth asserting. Measuring one there reported this renderer as 3pt wrong on
        /// every fixture while its fragments sat exactly on the grid — an ORACLE defect, not an
        /// app defect, and the reason the fragment grid is checked separately below.
        let hasText: Bool
        /// Does this line carry any TEXT ink — as against being made entirely of the
        /// characters the engine draws as geometry? When false, `left` is meaningless and the
        /// left-margin assertion skips the line, because the engine's PDF has nothing on that
        /// baseline to compare it against.
        let hasTextInk: Bool
        /// The fragment's own left edge, BEFORE the first-ink offset. Printed in a failure
        /// beside `left` so the gap between them says exactly how much this oracle skipped as
        /// whitespace-or-geometry — which is the number every row resolved on 2026-09-07
        /// turned on.
        let fragmentLeft: CGFloat
        /// The line's own glyph range, kept so a FAILURE can print what the line actually
        /// holds. Carried rather than resolved eagerly because building a substring for every
        /// line of every fixture costs what the `inkOffset` doc comment warns about; a failing
        /// line is rare, and only that one pays.
        let glyphs: NSRange
    }

    /// A failure list that STATES ITS OWN SHAPE before listing itself.
    ///
    /// Swift Testing prints an expectation's array inline, and a long one is truncated by
    /// whatever reads the log. I twice reported a family from the first few entries of one of
    /// these — once as "the +1pt family is four documents" when it was twenty-five rows at
    /// exactly +1.00pt across most of the corpus. The count and the distribution are the
    /// whole diagnosis in a family like that, and they cost nothing to compute, so they go
    /// FIRST where no truncation can remove them (Athena, 2026-09-07).
    static func summarize(_ failures: [String]) -> String {
        guard !failures.isEmpty else { return "" }
        // "off by -1.00", "over by 1.00pt" — whichever this oracle writes.
        var buckets: [String: Int] = [:]
        for failure in failures {
            guard let range = failure.range(of: #"(off|over) by -?[0-9]+\.[0-9]+"#,
                                            options: .regularExpression) else { continue }
            let value = failure[range].split(separator: " ").last.map(String.init) ?? "?"
            buckets[value, default: 0] += 1
        }
        let shape = buckets.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .map { "\($0.value)x \($0.key)" }
            .joined(separator: ", ")
        let documents = Set(failures.compactMap { $0.split(separator: ":").first.map(String.init) })
        return "\(failures.count) row(s) across \(documents.count) document(s)"
            + (shape.isEmpty ? "" : "; deltas: \(shape)") + "\n"
    }

    /// What a line actually says, for a failure message. Control characters are escaped so a
    /// box-drawing run or a stray `\u{2060}` is visible rather than silently blank.
    @MainActor
    static func lineText(of page: LaidOutPage, glyphs: NSRange, limit: Int = 48) -> String {
        let text = page.textView.string as NSString
        let chars = page.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0, NSMaxRange(chars) <= text.length else { return "<no text>" }
        let raw = text.substring(with: chars).prefix(limit)
        return raw.map { character -> String in
            let scalar = character.unicodeScalars.first!
            if scalar.value < 0x20 || scalar.value == 0x2060 || scalar.value == 0xA0 {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(character)
        }.joined()
    }

    /// Every line of a page, read from the layout manager rather than recomputed.
    @MainActor
    static func lines(of page: LaidOutPage, textFrame: CGRect) -> [Line] {
        var result: [Line] = []
        guard page.glyphs.length > 0 else { return result }
        var index = page.glyphs.location
        let end = page.glyphs.location + page.glyphs.length
        var ordinal = 0
        let text = page.textView.string as NSString
        while index < end {
            var effective = NSRange(location: 0, length: 0)
            let fragment = page.manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            let used = page.manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: nil)
            let location = page.manager.location(forGlyphAt: index)
            let ink = inkOffset(in: page, glyphs: effective, text: text, fallback: location.x)
            result.append(Line(
                index: ordinal,
                top: textFrame.origin.y + fragment.origin.y,
                baseline: textFrame.origin.y + fragment.origin.y + location.y,
                left: textFrame.origin.x + fragment.origin.x + ink.offset,
                hasText: used.width > 0,
                hasTextInk: ink.found,
                fragmentLeft: textFrame.origin.x + fragment.origin.x,
                glyphs: effective))
            guard effective.length > 0 else { break }
            index = effective.location + effective.length
            ordinal += 1
        }
        return result
    }

    /// The x of the first TEXT-ink glyph in a fragment, relative to the fragment's own
    /// origin — see `Line.left` for why the first GLYPH is the wrong answer. Falls back
    /// to the fragment's first glyph for a line that has no text ink at all, which
    /// `hasText` filters out of every assertion anyway.
    ///
    /// ## Why block characters are skipped as well as spaces
    ///
    /// "First ink" means first TEXT ink ON BOTH SIDES, because the other side cannot
    /// answer any other question. This oracle compares the app's layout against the first
    /// ink in the ENGINE's own PDF, read from text-drawing operators — and the engine draws
    /// cp437 blocks, shades and box-drawing as VECTOR FILLS, not text (`PDFWriter.swift`'s
    /// own `graphicChars` branch). The app's AppKit layout sets the identical characters as
    /// glyphs. So on any line beginning with them the two sides were being asked different
    /// questions, and the oracle reported the app's margin as short by exactly their width.
    ///
    /// That is the whole left-margin indent cluster. Measured: -SCREEN.WS rows y=216/228/240
    /// read 57.60 against the engine's 72.00, a delta of 14.40pt, and those three lines
    /// begin `\x1b\xfe\x1c ` — one block character plus one space, 2 columns at 12cpi. All
    /// 24 baselines on that page compared and only those three differed. CODES.WS line 7
    /// read 57.60 against 86.40, delta 28.80, and begins with three block characters plus a
    /// space: 4 columns. Neither was an app defect.
    ///
    /// The placement of those characters is NOT lost: it is geometry, and the fidelity gate
    /// compares it as geometry on its raster/vector path (Athena's ruling, 2026-09-07, the
    /// same rule she gave the gate).
    ///
    /// ## `CtrlKD.graphicChars`, and why NOT the app's set of the same name
    ///
    /// There are TWO sets called `graphicChars`: `SoftReturn.graphicChars`
    /// (`Rendering/PrintedVectorGraphics.swift`) is what the APP draws as vectors, and
    /// `CtrlKD.graphicChars` (`PDFDriverLJ6DTP.swift`, made public in sr 506b2e0) is what
    /// the ENGINE does. They are not the same question and this oracle needs the engine's:
    /// the number being compared against is the first ink in the ENGINE'S OWN PDF, so what
    /// matters is which characters are absent from that PDF's text operators. The app's set
    /// is deliberately the wider of the two — `PrintedStructuralParityTests` records that as
    /// a ruling rather than an oversight — and using it here would skip characters the
    /// engine DID write as text, hiding a real margin difference.
    ///
    /// It is read rather than copied for the same reason `stringWidth1000` and
    /// `symbolReverse` are: a second copy of this table drifts the moment the engine adds a
    /// shade or an arc corner. That the app maintains its own second copy is a separate,
    /// pre-existing thing, and not one this oracle should compound.
    ///
    /// Deliberately cheap. This runs for every line of every fixture, and the cost only
    /// showed up once the fix made the test PASS: the assertion loop `break`s on its first
    /// failure per fixture, so while it was failing it stopped after one line per document
    /// and while it passes it walks all of them. A `CharacterSet.whitespaces` query per glyph
    /// took the suite from ~4 minutes to over 15. Space and tab are the only whitespace a
    /// WordStar line can start with, so they are tested directly and first, and the common
    /// case — a line whose first glyph is already text ink — returns without walking
    /// anything. `graphicChars` is a `Set`, so its lookup is a hash, and it is only reached
    /// for a character that is not a space or a tab.
    ///
    /// ## Returns `found: false` for a line with NO text ink, and that matters
    ///
    /// A line can be entirely box-drawing — PAGE.RND line 2 is
    /// `♣─────────────────────────────────────────♠` and nothing else. Skipping graphics
    /// then walking off the end used to fall through to `fallback`, but the LINE TERMINATOR
    /// is neither a space, a tab, nor a `graphicChars` member, so the walk stopped ON THE
    /// NEWLINE and reported its x — 399.55, the far END of the line, against a fragment that
    /// starts at 6.48. The oracle's own failure message is what showed this, within one run
    /// of it being added.
    ///
    /// The honest answer for such a line is not a number at all: the engine draws every mark
    /// on it as geometry, so its PDF has no text ink on that baseline either and there is
    /// nothing to compare. The caller skips those lines, and COUNTS them, for the same reason
    /// the zero-comparison guard exists — an exclusion that quietly swallowed every line
    /// would leave this oracle passing on nothing.
    @MainActor
    private static func inkOffset(in page: LaidOutPage, glyphs: NSRange, text: NSString,
                                  fallback: CGFloat) -> (offset: CGFloat, found: Bool) {
        func isNotTextInk(_ unit: unichar) -> Bool {
            // Line terminators included: a newline is not ink, and treating it as ink is
            // exactly the bug described above.
            if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D { return true }
            guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
            return CtrlKD.graphicChars.contains(Character(scalar))
        }

        var glyph = glyphs.location
        let end = NSMaxRange(glyphs)
        while glyph < end {
            let character = page.manager.characterIndexForGlyph(at: glyph)
            guard character < text.length else { break }
            guard isNotTextInk(text.character(at: character)) else {
                return glyph == glyphs.location
                    ? (fallback, true)   // already ink: the caller's own first-glyph x is right
                    : (page.manager.location(forGlyphAt: glyph).x, true)
            }
            glyph += 1
        }
        return (fallback, false)
    }

    /// The app's own marks on one line, with their x — the mirror of
    /// `AppPDFWords.describeInkRun` for the engine's side.
    ///
    /// The engine's half of this answered -LASERJE.FNT in a single run. The two rows left
    /// after it are both about WHERE a mark sits rather than whether it is text —
    /// ROUNDED.BRD's dots start 1.00pt right of the engine's, PAGE.RND's middle dot 80pt
    /// right — and neither can be read from the app's TEXT alone. Printing both sides'
    /// positions makes the comparison symmetric, which is the same correction this file's own
    /// left-margin fix already needed: two sides measuring different things cannot be compared
    /// at all, whatever their numbers say.
    @MainActor
    static func describeAppInkRun(of page: LaidOutPage, glyphs: NSRange, fragmentLeft: CGFloat,
                                  limit: Int = 6) -> String {
        let text = page.textView.string as NSString
        var marks: [String] = []
        var glyph = glyphs.location
        let end = NSMaxRange(glyphs)
        while glyph < end, marks.count < limit {
            let character = page.manager.characterIndexForGlyph(at: glyph)
            guard character < text.length else { break }
            let unit = text.character(at: character)
            if unit != 0x20, unit != 0x09, unit != 0x0A, unit != 0x0D {
                let x = fragmentLeft + page.manager.location(forGlyphAt: glyph).x
                marks.append(String(format: "%@@%.2f",
                                    String(UnicodeScalar(unit) ?? " "), Double(x)))
            }
            glyph += 1
        }
        return marks.isEmpty ? "<no marks>" : "[\(marks.joined(separator: " "))]"
    }

    /// The text the app placed on one page, line by line.
    @MainActor
    static func pageText(of page: LaidOutPage) -> [String] {
        let text = (page.textView.string as NSString)
        let chars = page.manager.characterRange(forGlyphRange: page.glyphs, actualGlyphRange: nil)
        guard chars.length > 0, NSMaxRange(chars) <= text.length else { return [] }
        return text.substring(with: chars).components(separatedBy: "\n")
    }

    /// The app's own Printed facsimile PDF for a fixture — the AppKit render, i.e. the same
    /// bytes Cmd-P produces and the same path `AppNativeFidelityTests` measures.
    ///
    /// Used only where the layout flow cannot answer: an oversized line's ink lives in the
    /// self-pass overlay, not in the text storage.
    @MainActor
    static func appPrintedPDF(for url: URL, state: DocumentState) throws -> [UInt8] {
        let products = try ExportEngine.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
            style: .printed, viewStyle: .native, title: "", docPath: url.path)
        return try #require(products.first?.bytes,
                            "the app produced no Printed PDF for \(url.lastPathComponent)")
    }

    /// `pageText`, with each OVERSIZED line's real content restored.
    ///
    /// `renderPrinted` deliberately leaves an oversized line BLANK in the main text flow
    /// (`let content = oversized ? PageLine([], soft: base.soft) : base`) and paints it
    /// through `RenderedDocument.oversizedSelfPasses` instead, so the shared text storage
    /// carries only `attributedLine`'s single-space filler at that ordinal. A reader that
    /// looks at the flow alone therefore sees `" "` where the document has its title, and
    /// concludes the app dropped the line.
    ///
    /// That is a reader bug, not a renderer one — the app paints those titles correctly —
    /// and it is the THIRD place tonight the same blind spot turned up, after
    /// `PrintedStructuralParityTests`' own x measurement and its running-line reader. Any
    /// comparison of the app's text against the library's has to consult both layers.
    @MainActor
    static func pageTextIncludingOversizedPasses(
        of page: LaidOutPage, pageIndex: Int, rendered: RenderedDocument
    ) -> [String] {
        var lines = pageText(of: page)
        guard rendered.oversizedSelfPasses.indices.contains(pageIndex) else { return lines }
        for (ordinal, pass) in rendered.oversizedSelfPasses[pageIndex].enumerated() {
            guard let pass, ordinal < lines.count,
                  lines[ordinal].trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            lines[ordinal] = pass.string
        }
        return lines
    }
}
/// Wrapped in a `@Suite` so these tests are ADDRESSABLE.
///
/// As file-scope `@Test` functions they had no suite name, and on this toolchain no working
/// free-function form either — so `ONLY_TESTING=SoftReturnTests/<anything>` selected ZERO
/// tests and the runner reported rc=0 "TEST SUCCEEDED". A green exit code on nothing
/// executed is the same failure that let four of these very oracles be recorded as fixed on
/// 2026-09-07 when their verifying runs never ran a single assertion. Runner REV 8 now
/// fails such a run; this is the other half, so the tests can actually be selected.
///
/// `.serialized` — these lay out HUNDREDS of documents through AppKit on the main actor.
///
/// Run alone, the geometry suite finishes in 185 seconds. Inside a full armed run the SAME
/// tests over the SAME corpus did not finish in 14+ MINUTES, and a previous full run had to
/// be killed after 35. That ~40x gap is not the tests' own cost — it is what happens when
/// several corpus-wide `@MainActor` layout walks are scheduled concurrently with each other
/// and with the suites that drive real windows, QuickLook and the UI target. Serializing
/// them costs nothing when they are the only thing running and stops the full suite from
/// thrashing.
@Suite(.serialized) struct GeometryOracleTests {


/// An oracle that measures nothing is worse than no oracle: it reports success forever.
/// If the fixtures cannot be found, every loop below iterates zero times and every assertion
/// holds vacuously — so this runs first and says the count out loud.
@Test @MainActor func theOracleActuallyHasFixturesToMeasure() throws {
    let urls = Oracle.fixtureURLs
    #expect(urls.count >= 6,
            "the oracle found \(urls.count) fixtures — it is measuring nothing")
    for url in urls {
        let bytes = [UInt8]((try? Data(contentsOf: url)) ?? Data())
        #expect(bytes.count > 0, "\(url.lastPathComponent) is empty")
    }
}

// MARK: - Oracle 1 — geometry

/// Every line sits on the library's baseline grid.
///
/// `metrics.top` is the paper's top edge to the FIRST baseline, `metrics.lead` is
/// baseline-to-baseline, so line n belongs at `top + n * lead`. Asserted in two halves,
/// because they break for different reasons:
///
/// - the FRAGMENT grid, every line including blanks — this is what pagination rests on, and it
///   breaks when a line comes out the wrong HEIGHT (an unattributed newline taking the system
///   font's ~15pt instead of the document's 12pt lead);
/// - the BASELINE, for lines that carry text — this is where the type actually sits.
@Test @MainActor func everyLineSitsOnTheLibrarysBaselineGrid() throws {
    var failures: [String] = []
    let fixtures = Oracle.fixtureURLs
    try #require(!fixtures.isEmpty, "no fixtures — this oracle would pass vacuously")

    for url in fixtures {
        let state = try Oracle.state(for: url)
        let metrics = printedMetrics(state.document)
        let (rendered, _, pages) = Oracle.layOut(state)
        guard let first = pages.first else {
            failures.append("\(url.lastPathComponent): no pages laid out")
            continue
        }
        let lines = Oracle.lines(of: first, textFrame: rendered.textFrame)
        guard !lines.isEmpty else {
            failures.append("\(url.lastPathComponent): no line fragments on page 1")
            continue
        }
        // The grid's origin: where the first fragment must start for its baseline to land on
        // metrics.top. Taken from the first line's own measured baseline offset, so this checks
        // SPACING and placement rather than AppKit's internal ascent convention.
        // Job 425 (b26 round 26 wave 3, ctrl-kd's `pageStream`): the first baseline is
        // `top + THIS PAGE's own first line's lead`, not a flat `top + size` — see
        // `DocumentRenderer.renderPrinted`'s own `perPageFirstBaselines` citation. Re-derived
        // from `docToPagelines` directly, the same source the production fix reads, rather
        // than reused from `rendered` (`RenderedDocument` does not expose the raw per-page
        // `PageLine.lead` this needs).
        let docPages = docToPagelines(state.document, printed: true)
        let firstBaseline = CGFloat(metrics.top + (docPages.first?.first?.lead ?? metrics.lead))
        let gridTop = firstBaseline - (lines[0].baseline - lines[0].top)

        // `.lh` IS STATEFUL, so "line n belongs at top + n * lead" is only true of a document
        // whose lines all share the document default. A line set at its own leading carries
        // it in `PageLine.lead`, and `pageStream` advances by THAT (`y -= line[n].lead`) —
        // which is exactly what `DocumentRenderer.advanceLead` reproduces on the app side.
        //
        // LYING.WS, WARPRAYR.WS and DARKNESS.WS all open with a 16pt Title style over a 12pt
        // body, so every line after the title sat 4pt off a grid built from a flat 12. That
        // was the harness modelling the document wrong, not the app placing the line wrong:
        // the same 4.00pt appears on all three, and only on the documents with an oversized
        // opening style.
        //
        // Distances are accumulated from the engine's own per-line leads rather than
        // multiplied, so a document with several `.lh` changes is described correctly too.
        let docLines = docPages.first?.lines ?? []
        func lead(at index: Int) -> Double {
            (index >= 0 && index < docLines.count ? docLines[index].lead : nil) ?? metrics.lead
        }
        var offsetFromFirst: [CGFloat] = [0]
        if lines.count > 1 {
            for index in 1..<lines.count {
                offsetFromFirst.append(offsetFromFirst[index - 1] + CGFloat(lead(at: index)))
            }
        }
        func offset(forLineIndex index: Int) -> CGFloat {
            index >= 0 && index < offsetFromFirst.count
                ? offsetFromFirst[index]
                : CGFloat(Double(index) * metrics.lead)
        }

        // ONE `gridTop` FOR EVERY LINE IS THE DEFECT THIS ORACLE HAD, and it accounted for
        // 27 of its 71 rows plus 23 of the page-budget oracle's 28. Measured on DARKNESS.WS
        // line 1: `baseline=60.00 wanted=60.00 (off by 0.00) ascent=8.00`, where line 0's
        // ascent is 9.00 — the BASELINE IS EXACT and only the top differs, because this
        // renderer PINS baselines through its layout-manager delegate and a fragment's top is
        // its pinned baseline minus THAT FRAGMENT'S OWN ascent. WORDSTAR.WS says the same at a
        // 16pt lead: baseline exact, ascents 13.00 and 12.00, top 1.00 out.
        //
        // `gridTop` is derived from line 0's ascent alone and then compared against every
        // line's top, which is only sound if every line on the page has the same ascent.
        // Nothing guarantees that, and `pageStream` places BASELINES (`y -= line[n].lead`),
        // not tops. So the baseline is asserted, and the top is asserted only against what it
        // is actually made of — this line's own baseline and its own ascent — which catches a
        // fragment placed wrongly without assuming a uniform face.
        for line in lines {
            let wantedTop = gridTop + offset(forLineIndex: line.index)
            let wantedBaselineHere = firstBaseline + offset(forLineIndex: line.index)
            let topFollowsBaseline = abs(line.top - (wantedBaselineHere - (line.baseline - line.top))) <= 0.5
            if line.hasText, !topFollowsBaseline {
                // THE NUMBERS, not a theory (Athena, 2026-09-07). 28 rows of this oracle are
                // off by exactly +1.00 and 25 of the page-budget oracle's are over by exactly
                // 1.00pt, all on a page's FIRST fragment — one systematic cause. The
                // candidates are all about how AppKit's first line fragment relates to the
                // engine's first baseline (`printedTop`, `.mt` alone): the fragment's own
                // rect, the ascent inside it, and the grid anchor derived from them. Printing
                // all three together is what tells them apart, and none of them can be read
                // from "off by 1.00".
                let firstFragment = first.manager.lineFragmentRect(
                    forGlyphAt: first.glyphs.location, effectiveRange: nil)
                let firstUsed = first.manager.lineFragmentUsedRect(
                    forGlyphAt: first.glyphs.location, effectiveRange: nil)
                // AND THE FAILING FRAGMENT'S OWN RECT. Measured on DARKNESS: line 0's top is
                // 39.00 and fragment 0's height is 12.00, so line 1 should start at 51.00 —
                // and it starts at 52.00. The extra point is therefore BETWEEN the fragments,
                // not inside the first one, which the numbers above alone could not show.
                let thisFragment = first.manager.lineFragmentRect(
                    forGlyphAt: line.glyphs.location, effectiveRange: nil)
                failures.append(String(
                    format: "%@ line %d: fragment top y=%.2f, its own baseline minus its own "
                        + "ascent says %.2f (off by %.2f; lead=%.2f) [line0 top=%.2f baseline=%.2f ascent=%.2f; "
                        + "fragment0 rect y=%.2f h=%.2f, used y=%.2f h=%.2f; "
                        + "oldGridTop-based wanted=%.2f; "
                        + "gridTop=%.2f firstBaseline=%.2f metrics.top=%.2f "
                        + "textFrame.origin.y=%.2f lead(0)=%.2f lead(1)=%.2f; "
                        + "THIS fragment rect y=%.2f h=%.2f, gap after fragment0=%.2f; "
                        + "THIS baseline=%.2f wanted=%.2f (off by %.2f) ascent=%.2f]",
                    url.lastPathComponent, line.index, line.top,
                    Double(wantedBaselineHere - (line.baseline - line.top)),
                    Double(line.top - (wantedBaselineHere - (line.baseline - line.top))),
                    metrics.lead,
                    Double(lines[0].top), Double(lines[0].baseline),
                    Double(lines[0].baseline - lines[0].top),
                    Double(firstFragment.origin.y), Double(firstFragment.height),
                    Double(firstUsed.origin.y), Double(firstUsed.height),
                    Double(wantedTop), Double(gridTop), Double(firstBaseline), metrics.top,
                    Double(rendered.textFrame.origin.y), lead(at: 0), lead(at: 1),
                    Double(thisFragment.origin.y), Double(thisFragment.height),
                    Double(thisFragment.origin.y - (firstFragment.origin.y + firstFragment.height)),
                    // THE BASELINE, beside the top. `pageStream` places BASELINES
                    // (`y -= line[n].lead`); a fragment's TOP is that baseline minus whatever
                    // ascent the fragment's own content happens to have, and this renderer
                    // PINS baselines through its layout-manager delegate rather than letting
                    // fragments stack. So two lines with different ascents sit at correct
                    // baselines and different tops BY CONSTRUCTION — and this oracle builds
                    // one `gridTop` from line 0's ascent alone and then compares TOPS. If the
                    // baseline below is right while the top is 1.00 out, the oracle is
                    // measuring the wrong quantity and the 27 rows are not app defects.
                    Double(line.baseline),
                    Double(firstBaseline + offset(forLineIndex: line.index)),
                    Double(line.baseline - (firstBaseline + offset(forLineIndex: line.index))),
                    Double(line.baseline - line.top)))
                break
            }
            guard line.hasText else { continue }
            let wantedBaseline = firstBaseline + offset(forLineIndex: line.index)
            if abs(line.baseline - wantedBaseline) > 0.5 {
                failures.append(String(
                    format: "%@ line %d: baseline y=%.2f, library says %.2f (off by %.2f; lead=%.2f)",
                    url.lastPathComponent, line.index, line.baseline, wantedBaseline,
                    line.baseline - wantedBaseline, metrics.lead))
                break
            }
        }
    }

    #expect(failures.isEmpty, "baseline grid does not match the library: \(Oracle.summarize(failures))\(failures.joined(separator: "\n"))")
}

/// Every line of text starts at the left edge the library specifies (`.po`).
@Test @MainActor func everyLineStartsAtTheLibrarysLeftMargin() throws {
    var failures: [String] = []
    let fixtures = Oracle.fixtureURLs
    try #require(!fixtures.isEmpty, "no fixtures — this oracle would pass vacuously")

    for url in fixtures {
        let state = try Oracle.state(for: url)
        let metrics = printedMetrics(state.document)
        let (rendered, _, pages) = Oracle.layOut(state)
        guard let first = pages.first else { continue }

        // "Every line starts at the document's `.po`" is two assumptions, and the engine
        // holds neither unconditionally:
        //
        //  * `.po` IS STATEFUL. A line can carry its own (`PageLine.left`, already resolved
        //    to points by the engine), and REFORM.DOT does exactly that — its lines from 27
        //    on sit at 50.4 against a document default of 57.6.
        //  * A line's own TYPED INDENT moves its ink right of whatever margin is in force.
        //
        // BOTH OF THOSE WERE MODELLED, AND THE MODEL WAS THE PROBLEM. Deriving the engine's
        // ink as `(docLine.left ?? metrics.left) + leadingSpacesInSpans * size * 0.6` is a
        // reconstruction of what the engine WOULD draw, and it disagrees with what the
        // engine DOES draw wherever the engine resolves an indent into `left` rather than
        // into literal spans. Measured 2026-09-07: the span model failed 20 indented lines
        // when it under-counted the indent, and after being "fixed" failed a DIFFERENT set —
        // `report.ps line 2: left edge x=79.20, library says 72.00 (margin 72.00 + 0 typed
        // columns)`, the app one column RIGHT of a line the model says has no indent at all.
        // Trading one failing population for another is the signature of a wrong oracle, not
        // a half-fixed renderer.
        //
        // So this no longer models anything. It renders the ENGINE's own Printed PDF and
        // reads the first-ink x of every line out of the bytes, with the same extractor the
        // PCL tier uses on the app. Same correction as the mechanism-Y pin: the engine's
        // bytes are the oracle, and a quantity both sides can be asked for directly beats a
        // quantity only one side has.
        let enginePDF = try AppAnswerKeyParityTests.documentOperationsBytes(
            fixture: url, format: "pdf", mode: .printed,
            title: "", fontsTarget: .office, pictures: .embed)
        // First-ink x per baseline on page 1, from the engine's own output. Keyed by
        // baseline because that is what both sides agree on; the app's fragment ORDINAL and
        // the engine's page-line INDEX are not the same sequence, which is the pairing bug
        // the sibling grid oracle is still carrying.
        // First PAINTED glyph per baseline, not the first WORD's x: ctrl-kd's segmentation
        // keeps a leading tab inside its word, so RNFOREST's first word is `\tThe` at the
        // tab's own 72.00 rather than the "T" at 79.20. A tab paints nothing, and this
        // oracle asks where a line's INK starts.
        var engineInk = try AppPDFWords.firstInkByBaseline(from: enginePDF, page: 1)
        // Restrict to the band the app's own text frame actually occupies. The engine's PDF
        // also carries RUNNING lines — a footer page number sits at y_top 732 on a Letter
        // page — and the app draws those outside the text storage, so this oracle can never
        // see them. On a document that is almost all graphics (.BOX, .SHD) the footer is the
        // engine's ONLY baseline, and comparing against it made the counted-comparison guard
        // fire "matched NONE of the engine's 1 baselines" on six fixtures that have no body
        // text to disagree about. The guard was right that nothing matched; the mistake was
        // asking it to match a line the app never puts in the flow.
        let bodyBaselines = Oracle.lines(of: first, textFrame: rendered.textFrame)
            .filter(\.hasText).map { (Double($0.baseline) * 10).rounded() / 10 }
        if let lowest = bodyBaselines.min(), let highest = bodyBaselines.max() {
            engineInk = engineInk.filter { $0.key >= lowest - 1 && $0.key <= highest + 1 }
        }
        guard !engineInk.isEmpty else { continue }

        // AN OVERSIZED LINE HAS NO INK IN THE FLOW TO MEASURE.
        //
        // `renderPrinted` deliberately leaves such a line BLANK in the main text storage and
        // paints it through `RenderedDocument.oversizedSelfPasses` instead, so the fragment
        // this oracle can reach carries only `attributedLine`'s single-space filler. Reading
        // its x yields the filler's position — one space past the margin — for EVERY
        // oversized title in the corpus, which is precisely what this oracle was reporting:
        // DARKNESS, LYING and WARPRAYR each at 64.80 against engine titles at 126.60, 177.00
        // and 234.70, three different CENTRED positions and one identical wrong answer. The
        // register already records this blind spot as corrected for the pass's text, size
        // and gray "but not its X"; this is the X.
        //
        // The overlay's own position comes from an isolated layout inside the view, so
        // recomputing it here would be a THIRD copy of placement logic. Instead the app's
        // ink for those lines is read from the app's OWN Printed PDF — measured, not
        // reconstructed — which is sound because `theScreenMatchesWhatThePDFWouldPrint`
        // separately holds the view and that PDF to each other and passes.
        let selfPasses = rendered.oversizedSelfPasses.first ?? []
        var appInk: [Double: Double] = [:]
        if selfPasses.contains(where: { $0 != nil }) {
            let appPDF = try Oracle.appPrintedPDF(for: url, state: state)
            appInk = try AppPDFWords.firstInkByBaseline(from: appPDF, page: 1)
        }
        // Only for failure messages; built once per document rather than per failing row.
        let engineRuns = AppPDFWords.inkRunsByBaseline(from: enginePDF, page: 1)

        // A line the engine has no baseline for is SKIPPED — which is the dangerous part of
        // matching on a computed key, so it is counted. If the coordinate conversion below
        // is ever wrong, every line skips and this oracle passes having compared NOTHING.
        // That is the exact shape of failure this whole round has been about, so it is a
        // hard failure rather than a silent one.
        var compared = 0
        // Lines made ENTIRELY of characters the engine draws as geometry. Counted, not
        // ignored: this exclusion makes the oracle easier to pass, and one that swallowed
        // every line would leave it green having compared nothing — the same failure the
        // `compared == 0` guard below exists for. PAGE.RND and ROUNDED.BRD are mostly such
        // lines, so the number is expected to be large for them and zero for prose.
        var skippedAllGeometry = 0
        for line in Oracle.lines(of: first, textFrame: rendered.textFrame) where line.hasText {
            guard line.hasTextInk else { skippedAllGeometry += 1; continue }
            // The app's baseline is ALREADY in the extractor's terms — page-local, measured
            // down from the page's top edge — so it is the key as it stands.
            //
            // The first version of this "converted" it by `- textFrame.origin.y +
            // metrics.top`, on the assumption that `line.baseline` was relative to the text
            // frame. It is not. For report.ps that shifted every key by exactly the 3pt
            // between the two (textFrame.origin.y 39.0, metrics.top 36.0), producing app
            // keys [45.0, 57.0, 69.0, …] against engine baselines [48.0, 60.0, 84.0, …] —
            // nothing matched, and the guard below reported it instead of passing on zero
            // comparisons. The numbers in that message are what fixed this, which is why the
            // guard prints both sides rather than just complaining.
            let key = (Double(line.baseline) * 10).rounded() / 10
            guard let wanted = engineInk[key] else { continue }
            compared += 1
            // For an oversized line the flow holds only the filler, so take the app's real
            // ink from its own PDF at this baseline; everything else measures the fragment.
            let isOversized = line.index < selfPasses.count && selfPasses[line.index] != nil
            let measured = isOversized ? (appInk[key] ?? Double(line.left)) : Double(line.left)
            // A LICENSED row records itself and moves on — but only while it measures what
            // it was licensed at. Drift fails.
            if let licence = licensedLeftMarginRows[url.lastPathComponent]?[line.index],
               abs(measured - licence.app) <= 0.5, abs(wanted - licence.engine) <= 0.5 {
                print("LEFTMARGIN licensed \(url.lastPathComponent) line \(line.index): "
                      + "app \(measured), engine \(wanted) — \(licence.reason)")
                continue
            }
            if abs(measured - wanted) > 0.5 {
                // CARRY THE DIAGNOSIS, not just the complaint — the same reason the
                // zero-comparisons guard below prints both sides. Every row of this oracle
                // resolved on 2026-09-07 turned on WHICH CHARACTERS sit left of the app's
                // first text ink, and reading that took a separate dump each time. The line's
                // own text answers it in the failure itself.
                // BOTH SIDES, not just ours. Athena, 2026-09-07: before anyone is sent at
                // Sources/CtrlKD over a membership difference, the failure has to show the
                // ENGINE's own marks on the matched baseline and let a reader confirm the two
                // sides are the same line. The engine's text here is the confirmation; its
                // leftmost marks with their x are the evidence.
                let engineRun = engineRuns[key] ?? []
                failures.append(String(
                    format: "%@ line %d%@: first ink x=%.2f, the engine's own PDF puts it at "
                        + "%.2f (fragment starts at x=%.2f)\n      app    reads \"%@\"\n"
                        + "      engine reads %@",
                    url.lastPathComponent, line.index,
                    isOversized ? " (oversized, measured from the app's own PDF)" : "",
                    measured, wanted, Double(line.fragmentLeft),
                    Oracle.lineText(of: first, glyphs: line.glyphs)
                        + " " + Oracle.describeAppInkRun(of: first, glyphs: line.glyphs,
                                                         fragmentLeft: line.fragmentLeft),
                    AppPDFWords.describeInkRun(engineRun)))
                break
            }
        }
        // THE LICENCE IS DECIDED ONCE and covers BOTH guards below. The first version of it
        // covered only the all-geometry one, and the run still failed HP-LAB3.LST through the
        // second — "matched NONE of the engine's 6 baselines" — which is the same fact
        // reported by a guard that had not heard about the licence. A licence that silences
        // one of two guards is worse than none: it reads as though the exclusion is broken.
        let licensedNoTextInk = skippedAllGeometry > 0
            && noTextInkDocuments[url.lastPathComponent] != nil
        if compared == 0, licensedNoTextInk,
           let reason = noTextInkDocuments[url.lastPathComponent] {
            // RECORDED, not silent, and not a pass dressed as one: the run says by name which
            // document was not checked and why, every time.
            print("LEFTMARGIN skip \(url.lastPathComponent): \(reason) "
                  + "(\(skippedAllGeometry) all-geometry lines)")
        } else if compared == 0 {
            failures.append(String(
                format: "%@: every line was skipped as all-geometry (%d of them) or had no "
                    + "engine baseline — nothing was compared, so this document is UNCHECKED",
                url.lastPathComponent, skippedAllGeometry))
        }
        if compared == 0, !licensedNoTextInk {
            // Carry the DIAGNOSIS, not just the complaint. The first version of this guard
            // said only that nothing matched, which is enough to stop a vacuous pass but not
            // enough to fix it — and the fix is entirely a question of what the two sides'
            // y actually are. Printing both ends that question in one run instead of a guess
            // per run, the same reason the PCL tier prints its divergence lines.
            let appKeys = Oracle.lines(of: first, textFrame: rendered.textFrame)
                .filter(\.hasText)
                .map { (Double($0.baseline) * 10).rounded() / 10 }
            failures.append(String(
                format: "%@: matched NONE of the engine's %d baselines — the app/engine "
                    + "coordinate conversion is wrong, so this document was not checked. "
                    + "app keys %@ (raw baselines %@, textFrame.origin.y=%.2f, "
                    + "metrics.top=%.2f); engine baselines %@",
                url.lastPathComponent, engineInk.count,
                String(describing: Array(appKeys.prefix(6))),
                String(describing: Array(Oracle.lines(of: first, textFrame: rendered.textFrame)
                    .filter(\.hasText).map { (Double($0.baseline) * 10).rounded() / 10 }.prefix(6))),
                Double(rendered.textFrame.origin.y), Double(metrics.top),
                String(describing: Array(engineInk.keys.sorted().prefix(6)))))
        }
    }

    #expect(failures.isEmpty, "left margin does not match the library: \(Oracle.summarize(failures))\(failures.joined(separator: "\n"))")
}

/// A PAGE'S FIRST LINE CONSUMES ITS OWN LEAD, not the document default.
///
/// Job 427 established that a page's first line takes its POSITION from its own lead and
/// pinned `firstBaseline` to `page.first?.lead ?? metrics.lead` for that reason. Its HEIGHT
/// was the half of the rule that never got applied: `DocumentRenderer.advanceLead` answers
/// `metrics.lead` at index 0 — right for the GAP before line 0, which positions nothing
/// because nothing precedes it, and wrong for the fragment's own height, which is how much of
/// the page the line consumes.
///
/// This test exists because the failure that FOUND that bug can no longer see it. MARKUP.WS
/// was 13.00pt over its page budget entirely on this line; the budget oracle then turned out
/// to be measuring `usedRect`, a bounding box that also swallowed the gaps between pinned
/// fragments, and once it was corrected to assert the last BASELINE the whole family passed —
/// including MARKUP. So the renderer fix became unobservable to every test in the suite.
///
/// Athena's ruling, 2026-09-07: "correct in principle is not enough to land in a release".
/// A renderer change with no test that observes it is an untested renderer change, whatever
/// its reasoning. This asserts the behaviour directly against the engine's own numbers.
@Test @MainActor func aPagesFirstLineConsumesItsOwnLead() throws {
    let fixture = Oracle.fixtureURLs.first { $0.lastPathComponent == "MARKUP.WS" }
    let missing = "MARKUP.WS is not in the fixture set — this test needs a document whose "
        + "page 1 opens on its own `.lh`"
    let url = try #require(fixture, "\(missing)")
    let state = try Oracle.state(for: url)
    let metrics = printedMetrics(state.document)
    let (rendered, _, pages) = Oracle.layOut(state)
    let first = try #require(pages.first)
    let engineLines = docToPagelines(state.document, printed: true).first?.lines ?? []
    try #require(engineLines.count > 1, "MARKUP.WS page 1 has fewer than two lines")

    let ownLead = engineLines[0].lead ?? metrics.lead
    // THE PREMISE, checked rather than assumed: if this document ever stops opening on its
    // own lead, the test below would pass for the wrong reason — every line agreeing with the
    // default proves nothing about whether the first one is allowed its own.
    let premise = "MARKUP.WS page 1 line 0 no longer carries its own lead (own \(ownLead), "
        + "document default \(metrics.lead)) — this test can no longer observe the behaviour "
        + "it exists for and needs a different fixture"
    try #require(abs(ownLead - metrics.lead) > 0.5, "\(premise)")

    let fragment = first.manager.lineFragmentRect(
        forGlyphAt: first.glyphs.location, effectiveRange: nil)
    let heightMessage = "page 1's first fragment is \(fragment.height)pt tall; its own lead is "
        + "\(ownLead)pt and the document default is \(metrics.lead)pt. A `.lh` value is real "
        + "WordStar (1/48in units) and the facsimile must consume exactly it."
    #expect(abs(Double(fragment.height) - ownLead) < 0.5, "\(heightMessage)")

    // And the line after it sits where the engine puts it: `metrics.top + lead(0) + lead(1)`,
    // which is `pageStream`'s own `y -= line[n].lead` walk for the first two lines.
    let lines = Oracle.lines(of: first, textFrame: rendered.textFrame)
    try #require(lines.count > 1, "page 1 laid out fewer than two lines")
    let nextLead = engineLines[1].lead ?? metrics.lead
    let wantedBaseline = metrics.top + ownLead + nextLead
    let baselineMessage = "line 1's baseline is \(lines[1].baseline); the engine puts it at "
        + "\(wantedBaseline) (top \(metrics.top) + line 0's own lead \(ownLead) + line 1's "
        + "\(nextLead))"
    #expect(abs(Double(lines[1].baseline) - wantedBaseline) < 0.5, "\(baselineMessage)")
}

/// EVERY FRAGMENT IS EXACTLY ITS LEAD TALL, and a box-chart page holds the engine's own lines.
///
/// `paragraphStyle` pins `minimumLineHeight == maximumLineHeight == lead`, and AppKit does not
/// always honour it: a run set in a face whose natural line height exceeds the lead comes back
/// taller. WINGDING.CHT's lines read `76   L ✬` — Courier Prime, Helvetica Neue and Zapf
/// Dingbats, one homogeneous run each, every face the app's OWN correct choice — and the
/// fragment measured 14.34pt against a 14.00pt lead with the clamp verifiably set. Over 44
/// lines that is 14.96pt, more than a whole line, and page 5 held 44 of the engine's 45 lines
/// while the 45th was pushed onto page 6. Ten such boundaries across six Sawyer charts.
///
/// `PagedDocumentView`'s layout-manager delegate now pins the fragment HEIGHT alongside the
/// origin and baseline it already pinned (`PinnedBaseline.height`).
///
/// This asserts both halves, and it is negative-controlled: with the height pinning removed
/// it fails on the line count AND on the heights. No font change can substitute — coverage-
/// aware resolution was wired and measured, and made the fragment 14.39.
@Test @MainActor func everyFragmentIsExactlyItsLeadTall() throws {
    let fixture = Oracle.fixtureURLs.first { $0.lastPathComponent == "WINGDING.CHT" }
    let missing = "WINGDING.CHT is not in the fixture set — this test needs a document whose "
        + "pages are dense with runs in faces taller than the document lead"
    let url = try #require(fixture, "\(missing)")
    let state = try Oracle.state(for: url)
    let metrics = printedMetrics(state.document)
    let expected = docToPagelines(state.document, printed: true)
    let (rendered, _, pages) = Oracle.layOut(state)
    try #require(expected.count >= 5 && pages.count >= 5,
                 "WINGDING.CHT no longer has five pages")

    // Page 5 is where the shift landed. Its line count must match the engine's.
    let libraryPage = expected[4]
    let appLines = Oracle.lines(of: pages[4], textFrame: rendered.textFrame)
    let countMessage = "page 5 laid out \(appLines.count) lines; the engine puts "
        + "\(libraryPage.count) on it. A page that holds fewer than the engine assigned it has "
        + "pushed a line onto the next page, and Native and the export then disagree about "
        + "where the page ends."
    #expect(appLines.count == libraryPage.count, "\(countMessage)")

    // And the cause: every fragment is exactly the lead it was assigned.
    var wrong: [String] = []
    for index in 0..<min(appLines.count, libraryPage.count) {
        let rect = pages[4].manager.lineFragmentRect(
            forGlyphAt: appLines[index].glyphs.location, effectiveRange: nil)
        let lead = libraryPage[index].lead ?? metrics.lead
        if abs(Double(rect.height) - lead) > 0.01 {
            wrong.append(String(format: "line %d fragment %.2fpt against a lead of %.2fpt",
                                index, Double(rect.height), lead))
        }
    }
    let heightMessage = "fragments do not equal their leads: \(wrong.prefix(6).joined(separator: "; "))"
    #expect(wrong.isEmpty, "\(heightMessage)")
}

/// AN OVERPRINT CHAIN IS ONE FRAGMENT, and the harness must pair lines that way.
///
/// `DocumentRenderer` runs a group while each member is itself `overprint` and gives the
/// GROUP a single fragment carrying the base line's content; the chain's interior members are
/// drawn as overprint passes, never as lines in the flow. Sharing the base line's baseline is
/// what overprint means, and `advanceLead` charges those members a near-zero lead for exactly
/// the same reason.
///
/// So an engine page of N lines legitimately becomes fewer app fragments, and a harness that
/// pairs app line n against engine line n is misaligned for every line after the first chain.
/// FONTS.REF page 10 was the one chart the fragment-height fix did not close, and this is why:
/// 42 engine lines, 4 of them following an overprint predecessor, 38 app fragments. Charging
/// those 4 the way the renderer does, the engine's own leads sum to 741.04 against a usedRect
/// of 741.00 — four hundredths of a point. The app was right; the comparison was not.
@Test @MainActor func anOverprintChainIsOneFragment() throws {
    let fixture = Oracle.fixtureURLs.first { $0.lastPathComponent == "FONTS.REF" }
    let missing = "FONTS.REF is not in the fixture set — this test needs a document with an "
        + "overprint chain on a page"
    let url = try #require(fixture, "\(missing)")
    let state = try Oracle.state(for: url)
    let expected = docToPagelines(state.document, printed: true)
    let (rendered, _, pages) = Oracle.layOut(state)
    try #require(expected.count >= 10 && pages.count >= 10, "FONTS.REF no longer has ten pages")

    let libraryPage = expected[9]
    let collapsed = libraryPage.enumerated()
        .filter { $0.offset > 0 && libraryPage[$0.offset - 1].overprint }
        .count
    // THE PREMISE: this page must actually carry a chain, or the test proves nothing.
    let premise = "FONTS.REF page 10 no longer has any overprint-collapsed lines, so this "
        + "test can no longer observe the pairing it exists for and needs a different fixture"
    try #require(collapsed > 0, "\(premise)")

    let appLines = Oracle.lines(of: pages[9], textFrame: rendered.textFrame)
    let wanted = libraryPage.count - collapsed
    let message = "page 10 laid out \(appLines.count) fragments; the engine assigns "
        + "\(libraryPage.count) lines of which \(collapsed) follow an overprint predecessor "
        + "and therefore form no fragment of their own, so \(wanted) is correct"
    #expect(appLines.count == wanted, "\(message)")
}

/// Left-margin rows LICENSED as Native font-metric divergence, with their measured numbers.
///
/// Athena's ruling, 2026-09-07, under the 2026-08-11 MAC VIEWING RULING: Native is Mac fonts,
/// and a placement difference that comes from a Mac face's own advances is permanent and
/// named, not a defect to chase. ROUNDED.BRD line 1 is that: its `│` cell measures 15.00pt in
/// the app against the engine's 14.00, and its middle-dot run advances 4.17pt against the
/// engine's 4.32.
///
/// BOTH halves are face advances, which is a correction to an earlier split. `graphicCells`
/// takes a graphic character's cell width from `graphicAdvance`, which measures the distance
/// between consecutive AppKit GLYPH positions and falls back to `font.maximumAdvancement`
/// (`PrintedVectorGraphics.swift`) — the app lays box characters out as real glyphs in a Mac
/// face and draws its vectors at those positions, so the `│` cell has a face just as the dots
/// do. Whether the app SHOULD derive graphic cells from document pitch instead is planning
/// #216, deliberately after 4.0.3, and would close both at once.
///
/// The licence is NARROW: it names the document AND the line AND the two numbers, and holds
/// only while the measurement stays where it was recorded. A row that drifts fails, because a
/// licence that tolerates any value on a line stops being evidence of anything.
///
/// This is the mechanism `noTextInkDocuments` above already established for this oracle —
/// the Native gate's own `Fixtures/native-divergences.json` licenses GATE documents by
/// verdict, and ROUNDED.BRD is a geometry fixture that gate never sees.
struct LicensedLeftMargin {
    let app: Double
    let engine: Double
    let reason: String
}

let licensedLeftMarginRows: [String: [Int: LicensedLeftMargin]] = [
    "ROUNDED.BRD": [
        1: LicensedLeftMargin(
            app: 19.50, engine: 18.50,
            reason: "Native font-metric row (2026-08-11 MAC VIEWING RULING): the `│` cell "
                + "measures 15.00pt in the Mac face against the engine's 14.00pt cell, and "
                + "the middle-dot run advances 4.17pt against 4.32pt. Both are Mac-face "
                + "advances; deriving graphic cells from document pitch instead is "
                + "planning #216."),
    ],
]

/// Documents this oracle CANNOT apply to, with the reason, recorded rather than failed.
///
/// Athena's ruling, 2026-09-07. A left-MARGIN oracle needs text to measure the margin of.
/// These two are label sheets whose every line is box-drawing and nothing else, so there is
/// no text ink on any line and no honest number to assert — a property of the document, not
/// a defect in the app. Their box geometry is not unchecked: the fidelity gate compares it on
/// its vector/raster path.
///
/// Before today they were "compared", but on the x of the LINE TERMINATOR, because
/// `inkOffset` skipped every graphic and stopped on the newline. So this replaces a wrong
/// answer with an honest one rather than removing a real check.
///
/// The licence is NARROW on purpose. It applies only when the document was skipped BECAUSE
/// every line was geometry; a document that compares nothing for any OTHER reason — a broken
/// baseline conversion, the failure mode this whole round has been about — still fails loud
/// even if it is named here.
let noTextInkDocuments: [String: String] = [
    "HP-LAB3.LST": "no text ink on any line: a left-margin oracle cannot apply; box geometry "
        + "is compared by the gate's vector/raster path",
    "LSRLABL3.LST": "no text ink on any line: a left-margin oracle cannot apply; box geometry "
        + "is compared by the gate's vector/raster path",
]

/// A page's text occupies no more than `capacity * lead` points, and nothing spills off the
/// sheet. This is the 24pt overflow seen from the other end: if a page consumes more than the
/// library budgeted, the last line is off the paper when it prints.
@Test @MainActor func onePagesTextFitsTheLibrarysPageBudget() throws {
    var failures: [String] = []
    let fixtures = Oracle.fixtureURLs
    try #require(!fixtures.isEmpty, "no fixtures — this oracle would pass vacuously")

    for url in fixtures {
        let state = try Oracle.state(for: url)
        let metrics = printedMetrics(state.document)
        let (rendered, _, pages) = Oracle.layOut(state)
        guard let first = pages.first else { continue }

        // The sum of the ENGINE's own per-line leads for page 1, not `capacity * lead`.
        // `.lh` is stateful, so a flat lead describes only a document whose lines all sit at
        // the document default — the same correction this file's grid oracle already carries
        // for line POSITIONS, applied here to the page's total height. NOVEL.WS's page 1 is
        // 31 lines totalling 612pt where `capacity * lead` says 55 x 12 = 660.
        let engineLines = docToPagelines(state.document, printed: true).first?.lines ?? []
        let budget = engineLines.isEmpty
            ? CGFloat(Double(metrics.capacity) * metrics.lead)
            : CGFloat(engineLines.reduce(0.0) { $0 + ($1.lead ?? metrics.lead) })
        // `usedRect` IS A BOUNDING BOX, and this renderer pins baselines rather than
        // stacking fragments, so wherever two consecutive lines have different ascents their
        // fragments are not contiguous and the bounding box swallows the gap. Measured on
        // DARKNESS.WS: fragment 0 occupies 0.00–12.00, fragment 1 starts at 13.00 — a
        // 1.00pt gap, and every one of its baselines exact. That single point is the whole of
        // 23 of this oracle's 28 rows, and it is not page consumed by anything.
        //
        // What this test actually claims — its own doc comment — is "nothing spills off the
        // sheet". That is a claim about the LAST BASELINE, which is what `pageStream` places
        // and what determines whether the last line prints on the paper. `firstBaseline` is
        // `metrics.top + lead(0)` and the budget is the sum of every line's own lead, so the
        // last baseline belongs at `metrics.top + budget` and anything past that is a real
        // overflow. `usedRect` stays in the message as context.
        let used = first.manager.usedRect(for: first.container).height
        let lastBaseline = Oracle.lines(of: first, textFrame: rendered.textFrame)
            .last(where: \.hasText)?.baseline
        let sheetLimit = CGFloat(metrics.top) + budget
        if let lastBaseline, lastBaseline - sheetLimit > 0.5 {
            // CARRY THE DIAGNOSIS. Every residual in this family is 1 to 2pt — DARKNESS 1.00,
            // PS.TST 2.00, LYING 1.70 — and the app has exactly one mechanism that makes a
            // page taller than the sum of its lines' leads: `leadingHeadroom`, the space
            // `renderPrinted` reserves above a page whose first line is OVERSIZED, so the
            // glyph's real ascent is not clipped out of print, PDF and QuickLook. A line in
            // that pass is drawn at its own natural height (`naturalParagraphStyle`), not
            // clamped to any lead, so it is not in the engine's per-line lead sum at all.
            //
            // MEASURED AND RULED OUT, 2026-09-07: `leadingHeadroom` is 0.00pt on all three
            // of PS.TST, OLDTIMES.WS and MARKUP.WS, so it explains none of the residual. The
            // number is still printed because it is the cheap half of the question and a
            // future document may well be the case it does explain.
            let headroom = rendered.leadingHeadroom.first ?? 0

            // WHICH LINES are taller, and by how much. The residual is what it is because of
            // specific rows — PS.TST is 2.00pt over 15 lines, OLDTIMES 1.00pt over 42,
            // MARKUP.WS 13.00pt over 22 — and a total says nothing about whether that is one
            // line badly wrong or every line slightly wrong. Those are different bugs.
            //
            // The app's own per-line height is the gap between consecutive fragment tops;
            // the engine's is the line's own lead. Compared pairwise, first mismatches named.
            let appLines = Oracle.lines(of: first, textFrame: rendered.textFrame)
            // PAIRING BY INDEX IS ONLY VALID IF THE TWO SIDES HAVE THE SAME LINES. The app
            // WRAPS where the engine may not, so app line i and engine line i are the same
            // row only when the counts agree. Without this check the comparison below reads
            // like a per-line height bug when it is really an off-by-N alignment — OLDTIMES
            // shows the app at a constant 15.00 against engine leads of 12, 18 and 14, which
            // is exactly what a misalignment looks like and exactly what a real bug looks
            // like too. Say which it is rather than let the reader guess.
            let countsAgree = appLines.count == engineLines.count
            var perLine: [String] = []
            for index in 0..<min(appLines.count - 1, engineLines.count) where perLine.count < 4 {
                let appHeight = Double(appLines[index + 1].top - appLines[index].top)
                let engineLead = engineLines[index].lead ?? metrics.lead
                if abs(appHeight - engineLead) > 0.01 {
                    perLine.append(String(format: "line %d app %.2f vs lead %.2f (%+.2f)",
                                          index, appHeight, engineLead, appHeight - engineLead))
                }
            }
            failures.append(String(
                format: "%@: last baseline %.2f exceeds the sheet limit %.2f (metrics.top "
                    + "%.2f + budget %.2f, %d engine lines' own leads) by %.2fpt "
                    + "[usedRect height %.2f, leadingHeadroom %.2f, headroom %@ account for "
                    + "the usedRect excess]. First differing rows: %@",
                url.lastPathComponent, Double(lastBaseline), Double(sheetLimit),
                metrics.top, Double(budget), engineLines.count,
                Double(lastBaseline - sheetLimit), Double(used), Double(headroom),
                abs(Double(used - budget - headroom)) <= 0.5 ? "DOES" : "does NOT",
                perLine.isEmpty ? "NONE — every line matches its lead, so the excess is not "
                    + "in the line heights at all" : perLine.joined(separator: "; "))
                + String(format: " [app has %d lines, engine %d — pairing by index is %@]",
                         appLines.count, engineLines.count,
                         countsAgree ? "valid" : "NOT VALID, these rows may be misaligned"))
        }
        if let last = Oracle.lines(of: first, textFrame: rendered.textFrame)
                            .last(where: { $0.hasText })?.baseline,
           last > CGFloat(metrics.pageHeight) + 0.5 {
            failures.append(String(format: "%@: last baseline y=%.2f is past the paper's %.2fpt",
                                   url.lastPathComponent, last, metrics.pageHeight))
        }
    }

    #expect(failures.isEmpty, "page budget exceeded: \(Oracle.summarize(failures))\(failures.joined(separator: "\n"))")
}

/// THE INVARIANT JON STATED: what is on screen must be what comes out of the PDF, for the
/// same mode. Printed on screen == a Printed PDF. Modern on screen == a Modern PDF.
///
/// This is the test that was missing, and its absence is why three separate margin defects
/// shipped. The earlier geometry oracle asserted the app against `printedMetrics` and its
/// DOC COMMENT — "distance from the top of the paper down to the first text baseline" —
/// which is wrong. The emitter's arithmetic is the authority, and it is one line of
/// `PDFWriter.swift`:
///
///     var y = Double(pageHeight - top - size)
///
/// `top` is the top MARGIN; the first baseline lands `top + size` below the paper's edge.
/// Both the app AND the old oracle read that comment instead of the code, so the oracle
/// agreed with the bug — twice. A test written from the same misunderstanding as the code
/// cannot catch the code.
///
/// So this asserts against the FORMULA, per mode, for every fixture.
@Test @MainActor func theScreenMatchesWhatThePDFWouldPrint() throws {
    var failures: [String] = []
    let fixtures = Oracle.fixtureURLs
    try #require(!fixtures.isEmpty, "no fixtures — this oracle would pass vacuously")

    for url in fixtures {
        for style in [ViewStyle.native, .modern] {
            let state = try Oracle.state(for: url)
            state.style.setManually(style)
            let rendered = DocumentRenderer.render(state)

            // What emitPDF would do for this document in this mode. Modern has no
            // independent PDF baseline to check against — its own PDF export
            // (`ExportEngine.modernPDF`) draws this SAME `textFrame` via the native text
            // stack, so screen and export agree by construction. What Modern DOES owe the
            // façade is the 1in margin itself: the container's top edge, not a baseline
            // built from the library's Courier size and the app's own font mixed together
            // (that mismatch was the top/bottom margin bug — see `renderModern`).
            let metrics = style == .native
                ? printedMetrics(state.document)
                : modernMetrics(state.document)
            let expectedBaseline = CGFloat(metrics.top + Double(metrics.size))
            let expectedLeft = CGFloat(metrics.left)
            let expectedTopEdge = CGFloat(metrics.top)

            let view = PagedDocumentView()
            view.setContent(rendered, display: .continuousScroll)
            guard let tv = view.pageViews.first,
                  let manager = tv.layoutManager, let container = tv.textContainer else {
                failures.append("\(url.lastPathComponent) [\(style.displayName)]: no page laid out")
                continue
            }
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else { continue }

            // Find the first line that actually carries a glyph — a blank line has no
            // baseline worth comparing, and asserting one there is how this oracle was
            // wrong the first time.
            var index = glyphs.location
            var baseline: CGFloat?, left: CGFloat?
            while index < glyphs.location + glyphs.length {
                var effective = NSRange(location: 0, length: 0)
                let fragment = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
                let used = manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: nil)
                if used.width > 0 {
                    let loc = manager.location(forGlyphAt: index)
                    baseline = rendered.textFrame.origin.y + fragment.origin.y + loc.y
                    left = rendered.textFrame.origin.x + fragment.origin.x + loc.x
                    break
                }
                guard effective.length > 0 else { break }
                index = effective.location + effective.length
            }
            guard let baseline, let left else { continue }

            if style == .printed, abs(baseline - expectedBaseline) > 0.5 {
                failures.append(String(
                    format: "%@ [%@]: first baseline %.1fpt on screen, the PDF puts it at %.1fpt (top %.1f + size %d) — off by %.1f",
                    url.lastPathComponent, style.displayName, baseline, expectedBaseline,
                    metrics.top, metrics.size, baseline - expectedBaseline))
            }
            if style == .modern, abs(rendered.textFrame.origin.y - expectedTopEdge) > 0.5 {
                failures.append(String(
                    format: "%@ [%@]: text frame top %.1fpt on screen, the façade's margin is %.1fpt — off by %.1f",
                    url.lastPathComponent, style.displayName, rendered.textFrame.origin.y,
                    expectedTopEdge, rendered.textFrame.origin.y - expectedTopEdge))
            }
            // MODERN owes the façade its MARGIN, not its first glyph's position — exactly
            // the reasoning the top-edge check above already applies, and for the same
            // reason. Modern reflows and centres: DARKNESS.WS opens with a centred title and
            // PLAYBILL.DOC with a centred playbill line, so their first glyphs sit at 108.1
            // and 306.0 against a 72.0 margin. Both are correct Modern rendering; comparing
            // ink to a margin was asking the wrong question of the wrong mode.
            //
            // NATIVE keeps the first-glyph comparison, because there the facsimile really
            // does owe the library's own `.po` for an unindented opening line, and every
            // fixture in this corpus passes it.
            //
            // The asymmetry is deliberate and worth stating: a Native document whose first
            // text line carried a typed indent would fail this check today for the same
            // wrong reason. No fixture does, so it is latent rather than live — recorded
            // here instead of pre-emptively rewritten, since changing a green assertion on
            // no evidence is how the other direction of this mistake gets made.
            let leftOnScreen = style == .modern ? rendered.textFrame.origin.x : left
            if abs(leftOnScreen - expectedLeft) > 0.5 {
                failures.append(String(
                    format: "%@ [%@]: left edge %.1fpt on screen, the PDF puts it at %.1fpt",
                    url.lastPathComponent, style.displayName, leftOnScreen, expectedLeft))
            }
        }
    }

    #expect(failures.isEmpty, "the screen does not match what the PDF would print:\n\(failures.joined(separator: "\n"))")
}

// MARK: - Oracle 2 — pagination and content

/// The app puts the same lines on the same pages as the library does.
///
/// `docToPagelines(doc, printed: true)` is what the PDF emitter paginates against and what the
/// 2,119-file gauntlet validated. If the app's page assignment differs by one line, the screen
/// and the export disagree about where a page ends.
@Test @MainActor func theAppPaginatesExactlyLikeTheLibrary() throws {
    var failures: [String] = []
    let fixtures = Oracle.fixtureURLs
    try #require(!fixtures.isEmpty, "no fixtures — this oracle would pass vacuously")

    for url in fixtures {
        let state = try Oracle.state(for: url)
        let expected = docToPagelines(state.document, printed: true)
        let (rendered, _, pages) = Oracle.layOut(state)

        if pages.count < expected.count {
            failures.append("\(url.lastPathComponent): app laid out \(pages.count) pages, library says \(expected.count)")
            continue
        }
        for (index, libraryPage) in expected.enumerated() {
            // OVERPRINT CHAINS COLLAPSE, so pairing app line n against engine line n is
            // wrong on any page that has one. `DocumentRenderer` runs a group while each
            // member is itself `overprint` and gives the GROUP one fragment carrying the base
            // line's content; the chain's interior members are drawn as overprint passes, not
            // as lines in the flow. Sharing the base line's baseline is what overprint MEANS.
            //
            // Measured on FONTS.REF page 10: the engine assigns 42 lines, 4 of them following
            // an overprint predecessor, and the app lays out exactly 38. Charging those 4 the
            // near-zero lead `advanceLead` charges them, the engine's own leads sum to 741.04
            // against a usedRect of 741.00 — four hundredths of a point. The app was right and
            // this comparison was misaligned for every line after the first chain on the page,
            // which is why FONTS.REF was the one chart the fragment-height fix did not close.
            //
            // Same rule as `advanceLead`'s own: a line whose PREDECESSOR is overprint is not
            // a line of its own here either.
            let libraryText = libraryPage.enumerated()
                .filter { $0.offset == 0 || !libraryPage[$0.offset - 1].overprint }
                .map { $0.element.map(\.text).joined() }
            let appText = Oracle.pageTextIncludingOversizedPasses(
                of: pages[index], pageIndex: index, rendered: rendered)
            for (n, wanted) in libraryText.enumerated() where n < appText.count {
                let got = appText[n]
                if got.trimmingCharacters(in: .whitespaces) != wanted.trimmingCharacters(in: .whitespaces) {
                    failures.append("""
                        \(url.lastPathComponent) page \(index + 1) line \(n): \
                        app has \(got.prefix(40).debugDescription), library has \(wanted.prefix(40).debugDescription)
                        """)
                    break
                }
            }
        }
    }

    #expect(failures.isEmpty, "pagination differs from the library: \(Oracle.summarize(failures))\(failures.joined(separator: "\n"))")
}

}

/// DIAGNOSTIC, asserts nothing: why do six box-drawing charts push a line across a page break?
///
/// `theAppPaginatesExactlyLikeTheLibrary` reports the library's LAST line of page p as the
/// app's FIRST line of page p+1, on PRINTER.PS (3 boundaries), FONTCRIB.PS (3),
/// WINGDING.CHT, SYMBOL.CHT, FONTS.REF and fontcrib.ws — every one a character or font chart
/// made almost entirely of box-drawing glyphs.
///
/// Two mechanisms could do that and they need opposite fixes (Athena, 2026-09-07):
///
/// - VERTICAL: box glyphs in the Mac face carry an ascent/descent larger than the pinned
///   lead, the layout manager grows the fragment, and the page runs out of room. The app's
///   line COUNT would match the engine's while some fragment is taller than its own lead.
///   Fix: clamp graphic-glyph fragments to the lead the way text is clamped.
/// - HORIZONTAL: a line of box glyphs at Mac-face ADVANCES is wider than the engine's at
///   document pitch, so it WRAPS where the engine's did not. The app would have MORE lines
///   than the engine on that page. That is planning #216, and it would have to move into
///   4.0.3 rather than wait.
///
/// The line count tells them apart, so this prints both and lets the numbers choose.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct PaginationShiftProbe {
    @Test @MainActor func whyDoBoxChartsPushALineAcrossThePageBreak() throws {
        let wanted: Set<String> = ["WINGDING.CHT", "SYMBOL.CHT", "FONTS.REF",
                                   "PRINTER.PS", "FONTCRIB.PS", "fontcrib.ws"]
        for url in Oracle.fixtureURLs where wanted.contains(url.lastPathComponent) {
            let state = try Oracle.state(for: url)
            let metrics = printedMetrics(state.document)
            let expected = docToPagelines(state.document, printed: true)
            let (rendered, _, pages) = Oracle.layOut(state)

            for (index, libraryPage) in expected.enumerated() where index < pages.count {
                let libraryLines = libraryPage.map { $0.map(\.text).joined() }
                let appLines = Oracle.lines(of: pages[index], textFrame: rendered.textFrame)
                var tall: [String] = []
                for i in 0..<min(appLines.count - 1, libraryPage.count) {
                    // THE FRAGMENT'S OWN HEIGHT, not the gap between consecutive TOPS. The
                    // first version of this measured `appLines[i+1].top - appLines[i].top`,
                    // which is precisely the quantity the pinned-baseline artefact inflates:
                    // this renderer places a fragment's top at its pinned baseline minus that
                    // fragment's own ascent, so a 1pt ascent change between two lines shows up
                    // as a 1pt "tall fragment" when nothing grew at all. That is the same
                    // mistake the page-budget oracle was making with `usedRect`, made again by
                    // me, three hours after I fixed it there.
                    let rect = pages[index].manager.lineFragmentRect(
                        forGlyphAt: appLines[i].glyphs.location, effectiveRange: nil)
                    let height = Double(rect.height)
                    let gap = Double(appLines[i + 1].top - appLines[i].top)
                    let lead = libraryPage[i].lead ?? metrics.lead
                    if height - lead > 0.01 {
                        // AND WHAT IS ON THAT LINE. `paragraphStyle` pins
                        // `minimumLineHeight == maximumLineHeight == lead`, which clamps TEXT
                        // — so a fragment that grew past its lead has something in it AppKit
                        // does not clamp. An `NSTextAttachment` is exactly that, and the
                        // pagination oracle already shows the app carrying U+FFFC where the
                        // library has raw tag text. If the tall lines are the attachment
                        // lines, the vertical mechanism is proven rather than inferred.
                        // WHOLE LINE, not a prefix. The first version passed limit: 12 and
                        // found no attachments — from twelve characters of a line that can be
                        // eighty wide. That is the same truncation that had me report a
                        // 25-row family as four rows this afternoon.
                        let text = Oracle.lineText(of: pages[index], glyphs: appLines[i].glyphs,
                                                   limit: 4096)
                        let hasAttachment = text.unicodeScalars.contains { $0.value == 0xFFFC }
                        // OVERSIZED? `paragraphStyle` pins min == max line height to the lead,
                        // which clamps text — but `naturalParagraphStyle` leaves BOTH AT ZERO,
                        // which is AppKit's "unbounded", and `lineExceedsFragment` routes a
                        // line there when its tallest resolved glyph is far taller than the
                        // fragment its lead would give it. Box-drawing glyphs in a Mac face
                        // are exactly the candidates. Attachments are ruled out (measured:
                        // zero, over whole lines), so this is what is left.
                        let selfPasses = index < rendered.oversizedSelfPasses.count
                            ? rendered.oversizedSelfPasses[index] : []
                        let oversized = i < selfPasses.count && selfPasses[i] != nil
                        // IS THE CLAMP EVEN SET ON THIS LINE, and whose glyphs are these?
                        // `paragraphStyle` pins min == max == lead. If the style on this
                        // line's own storage says otherwise, the clamp never reached it; if
                        // it says 14.00 and the fragment is 14.34, AppKit is not honouring it
                        // — and the likeliest reason is a FALLBACK face, since job 442
                        // measured that Courier Prime constructs but does not COVER U+250C,
                        // so AppKit substitutes for exactly these glyphs.
                        let storage = pages[index].textView.textStorage
                        let charIndex = pages[index].manager.characterIndexForGlyph(
                            at: appLines[i].glyphs.location)
                        var faces: Set<String> = []
                        var minH = -1.0, maxH = -1.0
                        if let storage, charIndex < storage.length {
                            let range = pages[index].manager.characterRange(
                                forGlyphRange: appLines[i].glyphs, actualGlyphRange: nil)
                            storage.enumerateAttribute(.font, in: range) { value, _, _ in
                                if let font = value as? NSFont { faces.insert(font.fontName) }
                            }
                            if let style = storage.attribute(.paragraphStyle, at: charIndex,
                                                             effectiveRange: nil)
                                as? NSParagraphStyle {
                                minH = Double(style.minimumLineHeight)
                                maxH = Double(style.maximumLineHeight)
                            }
                        }
                        // WHICH RUN carries the substituted face, and what is IN that run.
                        // Per-span coverage-aware resolution was wired and MEASURED: it does
                        // not fix this (WINGDING p5 stayed 44 lines against 45, and the
                        // fragment went 14.34 -> 14.39). The reason would be a run whose own
                        // text MIXES characters the primary covers with ones it does not — no
                        // candidate covers the whole run, so the resolver falls back to the
                        // first that merely constructs, exactly as before. If instead each
                        // run is homogeneous, per-span resolution should have worked and
                        // something else is wrong. The runs decide it.
                        var runs: [String] = []
                        if let storage, charIndex < storage.length {
                            let range = pages[index].manager.characterRange(
                                forGlyphRange: appLines[i].glyphs, actualGlyphRange: nil)
                            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                                let name = (value as? NSFont)?.fontName ?? "nil"
                                let text = storage.attributedSubstring(from: sub).string
                                    .replacingOccurrences(of: "\n", with: "\\n")
                                runs.append("\(name):\(text.prefix(10).debugDescription)")
                            }
                        }
                        tall.append(String(
                            format: "l%d frag %.2f gap %.2f lead %.2f clamp[%.2f,%.2f] %@%@%@ RUNS{%@}",
                            i, height, gap, lead, minH, maxH,
                            faces.sorted().joined(separator: "+"),
                            hasAttachment ? " ATTACH" : "",
                            oversized ? " OVERSIZED" : "",
                            runs.prefix(6).joined(separator: " | ")))
                    }
                }
                guard appLines.count != libraryLines.count || !tall.isEmpty else { continue }
                // WHEN THE COUNTS DIFFER AND NO FRAGMENT IS TALL, the lines are not the
                // problem — the room they were given is. FONTS.REF page 10 is 4 lines short
                // with every fragment exactly its lead, so print the container against what
                // the engine's own leads add up to.
                if appLines.count != libraryLines.count && tall.isEmpty {
                    let container = pages[index].container.size
                    let used = pages[index].manager.usedRect(for: pages[index].container)
                    let leadSum = libraryPage.reduce(0.0) { $0 + ($1.lead ?? metrics.lead) }
                    // OVERPRINT CHAINS collapse: `DocumentRenderer.advanceLead` charges a line
                    // whose PREDECESSOR was `overprint` a near-zero lead, and the renderer
                    // gives a chain's interior members no fragment of their own at all — they
                    // share the base line's baseline, which is what overprint MEANS. So an
                    // engine page of 42 lines legitimately becomes fewer app fragments, and a
                    // naive lead sum legitimately overcounts. Count them before calling this a
                    // defect.
                    let overprints = libraryPage.filter(\.overprint).count
                    var chargedSum = 0.0
                    for (n, pageLine) in libraryPage.enumerated() {
                        let previousOverprints = n > 0 && libraryPage[n - 1].overprint
                        chargedSum += previousOverprints ? 0.01 : (pageLine.lead ?? metrics.lead)
                    }
                    print(String(
                        format: "SHIFTROOM %@ page %d: container %.2f x %.2f, usedRect h %.2f, "
                            + "engine leads sum %.2f (charged %.2f, %d overprint lines), "
                            + "app lines %d vs engine %d",
                        url.lastPathComponent, index + 1,
                        Double(container.width), Double(container.height),
                        Double(used.height), leadSum, chargedSum, overprints,
                        appLines.count, libraryLines.count))
                }
                print("""
                    SHIFTPROBE \(url.lastPathComponent) page \(index + 1): \
                    app \(appLines.count) lines, engine \(libraryLines.count) — \
                    \(appLines.count > libraryLines.count ? "APP HAS MORE (wrap: horizontal)"
                        : appLines.count < libraryLines.count ? "APP HAS FEWER" : "counts agree")\
                    ; fragments taller than their lead: \
                    \(tall.isEmpty ? "none (so not vertical)" : tall.prefix(6).joined(separator: " "))
                    """)
            }
        }
    }
}

/// DIAGNOSTIC, asserts nothing: where do the spaces after a graphic run go?
///
/// FONTS.REF page 10 line 9 and -LASERJE.FNT line 9 are the same line, and both show it: the
/// app lays out `░▒▓│┤╡╢╖╕╣║╗  Scalable` where the engine's pageline carries
/// `░▒▓│┤╡╢╖╕╣║╗     Scalable` — two spaces against five. The same shape appears on all five
/// of the corpus's internal-whitespace pagination rows, and every one follows a graphic run.
/// It is also the -LASERJE.FNT left-margin row: `Scalable` at 237.24 in the app against
/// 241.70 in the engine's PDF, and 3 missing spaces at 12cpi is 21.6pt, which is NOT 4.46pt,
/// so the two may or may not be one cause — that is exactly what this measures instead of
/// assuming (Athena, 2026-09-07).
///
/// Prints the ENGINE's own spans for the line with their exact texts, and the app's laid-out
/// storage, with space counts, so "the app drops three" and "the oracle collapses three" can
/// be told apart. The first is a Native defect; the second is the harness.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct GraphicRunSpaceProbe {
    @Test @MainActor func whereDoTheSpacesAfterAGraphicRunGo() throws {
        for name in ["FONTS.REF", "-LASERJE.FNT"] {
            guard let url = Oracle.fixtureURLs.first(where: { $0.lastPathComponent == name })
            else { continue }
            let state = try Oracle.state(for: url)
            let expected = docToPagelines(state.document, printed: true)
            let (rendered, _, pages) = Oracle.layOut(state)

            for (pageIndex, libraryPage) in expected.enumerated() where pageIndex < pages.count {
                for (lineIndex, pageLine) in libraryPage.enumerated() {
                    let engineText = pageLine.map(\.text).joined()
                    guard engineText.contains("Scalable"),
                          engineText.contains(where: { CtrlKD.graphicChars.contains($0) })
                    else { continue }
                    let appLines = Oracle.lines(of: pages[pageIndex], textFrame: rendered.textFrame)
                    guard lineIndex < appLines.count else { continue }
                    let appText = Oracle.lineText(of: pages[pageIndex],
                                                  glyphs: appLines[lineIndex].glyphs, limit: 4096)
                    func spaceRun(_ text: String) -> Int {
                        guard let mark = text.range(of: "Scalable") else { return -1 }
                        return text[text.startIndex..<mark.lowerBound].reversed()
                            .prefix { $0 == " " }.count
                    }
                    print("""
                        SPACEPROBE \(name) p\(pageIndex + 1) l\(lineIndex): \
                        engine spans=\(pageLine.count) \
                        engine spaces-before-Scalable=\(spaceRun(engineText)) \
                        app spaces-before-Scalable=\(spaceRun(appText))
                          engine text: \(engineText.debugDescription)
                          app text:    \(appText.debugDescription)
                          engine span texts: \(pageLine.map(\.text.debugDescription).joined(separator: " | "))
                        """)
                }
            }
        }
    }
}
