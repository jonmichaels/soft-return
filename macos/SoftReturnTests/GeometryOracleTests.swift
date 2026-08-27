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
        // Optional extra corpus: the real WS5+ archive lives in the vault, not the repo.
        // Point CTRLKD_PRIVATE_CORPUS at a directory to widen the gauntlet locally without
        // committing anyone's documents (job 531: unified onto the engine repo's own name --
        // this app had SOFT_RETURN_EXTRA_FIXTURES/SOFTRETURN_ORACLE_CORPUS as two more names
        // for the same "point me at the private corpus" signal; one name now, everywhere).
        if let extra = ProcessInfo.processInfo.environment["CTRLKD_PRIVATE_CORPUS"],
           let found = try? FileManager.default.contentsOfDirectory(
               at: URL(fileURLWithPath: extra), includingPropertiesForKeys: nil) {
            urls += found.filter { !$0.lastPathComponent.hasPrefix(".")
                                && $0.pathExtension.lowercased() != "md" }
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
        /// Left edge of the first glyph. Only meaningful when `hasText`.
        let left: CGFloat
        /// Does this line carry a visible glyph?
        ///
        /// A blank line contains only its newline, which has no visible glyph and therefore no
        /// baseline worth asserting. Measuring one there reported this renderer as 3pt wrong on
        /// every fixture while its fragments sat exactly on the grid — an ORACLE defect, not an
        /// app defect, and the reason the fragment grid is checked separately below.
        let hasText: Bool
    }

    /// Every line of a page, read from the layout manager rather than recomputed.
    @MainActor
    static func lines(of page: LaidOutPage, textFrame: CGRect) -> [Line] {
        var result: [Line] = []
        guard page.glyphs.length > 0 else { return result }
        var index = page.glyphs.location
        let end = page.glyphs.location + page.glyphs.length
        var ordinal = 0
        while index < end {
            var effective = NSRange(location: 0, length: 0)
            let fragment = page.manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            let used = page.manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: nil)
            let location = page.manager.location(forGlyphAt: index)
            result.append(Line(
                index: ordinal,
                top: textFrame.origin.y + fragment.origin.y,
                baseline: textFrame.origin.y + fragment.origin.y + location.y,
                left: textFrame.origin.x + fragment.origin.x + location.x,
                hasText: used.width > 0))
            guard effective.length > 0 else { break }
            index = effective.location + effective.length
            ordinal += 1
        }
        return result
    }

    /// The text the app placed on one page, line by line.
    @MainActor
    static func pageText(of page: LaidOutPage) -> [String] {
        let text = (page.textView.string as NSString)
        let chars = page.manager.characterRange(forGlyphRange: page.glyphs, actualGlyphRange: nil)
        guard chars.length > 0, NSMaxRange(chars) <= text.length else { return [] }
        return text.substring(with: chars).components(separatedBy: "\n")
    }
}

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
        for line in lines {
            let wantedTop = gridTop + CGFloat(Double(line.index) * metrics.lead)
            if abs(line.top - wantedTop) > 0.5 {
                failures.append(String(
                    format: "%@ line %d: fragment top y=%.2f, grid says %.2f (off by %.2f; lead=%.2f)",
                    url.lastPathComponent, line.index, line.top, wantedTop,
                    line.top - wantedTop, metrics.lead))
                break
            }
            guard line.hasText else { continue }
            let wantedBaseline = firstBaseline + CGFloat(Double(line.index) * metrics.lead)
            if abs(line.baseline - wantedBaseline) > 0.5 {
                failures.append(String(
                    format: "%@ line %d: baseline y=%.2f, library says %.2f (off by %.2f; lead=%.2f)",
                    url.lastPathComponent, line.index, line.baseline, wantedBaseline,
                    line.baseline - wantedBaseline, metrics.lead))
                break
            }
        }
    }

    #expect(failures.isEmpty, "baseline grid does not match the library:\n\(failures.joined(separator: "\n"))")
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
        for line in Oracle.lines(of: first, textFrame: rendered.textFrame)
        where line.hasText && abs(line.left - CGFloat(metrics.left)) > 0.5 {
            failures.append(String(format: "%@ line %d: left edge x=%.2f, library says %.2f",
                                   url.lastPathComponent, line.index, line.left, metrics.left))
            break
        }
    }

    #expect(failures.isEmpty, "left margin does not match the library:\n\(failures.joined(separator: "\n"))")
}

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

        let budget = CGFloat(Double(metrics.capacity) * metrics.lead)
        let used = first.manager.usedRect(for: first.container).height
        if used - budget > 0.5 {
            failures.append(String(
                format: "%@: page uses %.2fpt, budget is %.2fpt (capacity %d x lead %.2f)",
                url.lastPathComponent, used, budget, metrics.capacity, metrics.lead))
        }
        if let last = Oracle.lines(of: first, textFrame: rendered.textFrame)
                            .last(where: { $0.hasText })?.baseline,
           last > CGFloat(metrics.pageHeight) + 0.5 {
            failures.append(String(format: "%@: last baseline y=%.2f is past the paper's %.2fpt",
                                   url.lastPathComponent, last, metrics.pageHeight))
        }
    }

    #expect(failures.isEmpty, "page budget exceeded:\n\(failures.joined(separator: "\n"))")
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
            if abs(left - expectedLeft) > 0.5 {
                failures.append(String(
                    format: "%@ [%@]: left edge %.1fpt on screen, the PDF puts it at %.1fpt",
                    url.lastPathComponent, style.displayName, left, expectedLeft))
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
        let (_, _, pages) = Oracle.layOut(state)

        if pages.count < expected.count {
            failures.append("\(url.lastPathComponent): app laid out \(pages.count) pages, library says \(expected.count)")
            continue
        }
        for (index, libraryPage) in expected.enumerated() {
            let libraryText = libraryPage.map { $0.map(\.text).joined() }
            let appText = Oracle.pageText(of: pages[index])
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

    #expect(failures.isEmpty, "pagination differs from the library:\n\(failures.joined(separator: "\n"))")
}
