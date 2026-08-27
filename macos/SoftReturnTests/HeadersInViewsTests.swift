import AppKit
import CtrlKD
import Foundation
import PDFKit
import Testing
@testable import SoftReturn

/// Job 371 item 3 (HEADERS IN VIEWS) shipped Modern's own running head/foot, but as ONE
/// inline body line at wherever the `.h1`/`.he`/`.fo`/`.f1` declaration sat in document
/// order — never repeated. Job 391 traced two live symptoms to that same design: OLDTIMES.WS
/// declares its `.h1` AFTER page 1's own title text (line 7 vs line 8 of the source file), so
/// WordStar's own rule (a running head applies from the page it's declared on ONLY IF no text
/// has printed there yet, else from the next page) says it should show from page 2 on — the
/// old inline placement put it on page 1 instead, and nowhere else. POWERUSE.WS's header
/// showed on whichever single page it happened to flow onto and nowhere else, when it should
/// show on every page from its own declaration point forward — the "paged views = paged
/// surfaces" doctrine `renderPrinted`'s own `runningLines` already honors, and the engine's
/// own Modern PDF (`PDFModernLayout.swift`'s `modernStreams`, ruling 2026-08-06 M5: "Modern
/// keeps headers") already replays correctly.
///
/// Job 393 fixed `renderModern` to record `HFEvent`s instead of flowing header text inline,
/// and `PagedDocumentView` to replay them against AppKit's own REAL pages once layout is
/// done (`DocumentRenderer.modernRunningLines`). These tests assert against that real paged
/// view (`PagedDocumentView.runningLines(atPageIndex:)`) — direction/page-position, not a
/// substring of the flattened body string, which no longer carries header text at all.
/// Job 535: every test in this suite reads `TestDocs/ws7` — gated at the suite level so a
/// bare stranger run (no `CTRLKD_PRIVATE_CORPUS`, no in-repo `TestDocs/`) skips all of it
/// cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct HeadersInViewsTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    @MainActor
    private static func state(fixture: String) throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "HeadersInViewsTests.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    /// Modern, laid out for real through `PagedDocumentView` — the same construction
    /// `ExportEngine.appKitRenderedPDF`/`PagePreviewRenderer` use, so what these tests check
    /// is what a reader (and Modern's own "Save as PDF") actually sees.
    @MainActor
    private static func pagedModernView(for state: DocumentState) -> PagedDocumentView {
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Which local pages of `view` carry a header line whose text contains `needle`.
    @MainActor
    private static func pagesWithHeader(_ view: PagedDocumentView, containing needle: String) -> Set<Int> {
        var pages: Set<Int> = []
        for index in 0..<view.pageCount {
            if view.runningLines(atPageIndex: index).contains(where: {
                $0.kind == .header && Self.collapsedSpaces($0.text.string).contains(needle)
            }) {
                pages.insert(index)
            }
        }
        return pages
    }

    /// Runs of the plain space character collapsed to one — PDFKit's own `PDFPage.string`
    /// text extraction does this to a running head's "baked spaces" (`modernHFOps`'s own doc
    /// comment: "the header keeps its own baked spaces"), so a needle built from the RAW
    /// `HFEvent.text` (which keeps them) needs the same collapse before `.contains` against
    /// extracted PDF text, or a genuinely-present header reads as a false negative — newlines
    /// are left alone, since a needle is always one line and should never bridge two.
    private static func collapsedSpaces(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for ch in text {
            if ch == " " {
                if !lastWasSpace { result.append(ch) }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        return result
    }

    // MARK: - OLDTIMES.WS: `.h1` declared AFTER page 1's own title (job 391)

    @Test @MainActor func oldtimesHeaderAbsentFromPageOnePresentFromPageTwo() throws {
        let state = try Self.state(fixture: "OLDTIMES.WS")
        let event = try #require(
            state.document.hfEvents.first { $0.kind == .header && !$0.text.isEmpty },
            "OLDTIMES.WS should declare a non-empty running head")
        // `#` is the page-number token (OLDTIMES' own `.h1` names it), never literal in what
        // a real page shows — matched on the fixed prefix instead.
        let needle = Self.collapsedSpaces(String(event.text.split(separator: "#").first ?? ""))
        #expect(!needle.isEmpty)

        let view = Self.pagedModernView(for: state)
        try #require(view.pageCount >= 2, "OLDTIMES.WS should flow past a single Modern page")

        let pages = Self.pagesWithHeader(view, containing: needle)
        #expect(!pages.contains(0),
                "the .h1 sits after page 1's own title text, so WordStar shows no head there")
        for page in 1..<view.pageCount {
            #expect(pages.contains(page), "page \(page + 1) should carry the running head declared on page 1")
        }
    }

    // MARK: - POWERUSE.WS: header repeats on every page, not just wherever it first flowed

    @Test @MainActor func poweruseHeaderRepeatsOnEveryPage() throws {
        let state = try Self.state(fixture: "POWERUSE.WS")
        let event = try #require(
            state.document.hfEvents.first { $0.kind == .header && !$0.text.isEmpty },
            "POWERUSE.WS should declare at least one non-empty running head")
        let needle = Self.collapsedSpaces(String(event.text.split(separator: "#").first ?? ""))
        #expect(!needle.isEmpty)

        let view = Self.pagedModernView(for: state)
        try #require(view.pageCount >= 1)

        let pages = Self.pagesWithHeader(view, containing: needle)
        for page in 0..<view.pageCount {
            #expect(pages.contains(page), "POWERUSE's own running head should repeat on every page, not just one")
        }
    }

    // MARK: - Engine-oracle cross-check: the view must agree with `emitPDF(mode: .modern)`

    /// The engine's own Modern PDF already replays `.hf` per real page (`PDFModernLayout
    /// .swift`'s `modernStreams`) — pull that PDF's own PAGE 1 text (PDFKit, not a second
    /// reimplementation of the replay rule) and check it agrees with the view on whether page
    /// 1 shows the head. This is the exact defect job 391 found (OLDTIMES's `.h1` wrongly
    /// showing on page 1; the app view now gets it right — `oldtimesHeaderAbsentFrom
    /// PageOnePresentFromPageTwo` above), so it is the sharpest single check available.
    ///
    /// Not a full per-page SET comparison: Modern PDF paginates in fixed base-14 Times
    /// (`modernTokFont`'s own "never Courier... the typescript aesthetic lives only in
    /// Printed now" rule) while the app view reflows in the user's own chosen Modern font
    /// (`renderModern`'s own `bodyFont`) — two different measures of the SAME text, so the
    /// two renderers do not, and are not expected to, land on the same page COUNT (this is
    /// exactly the documented, out-of-scope divergence `OutputParityTests` already excludes
    /// the `pdf.modern` cell for — see this job's own brief). A page-by-page SET comparison
    /// would fail on that pagination drift alone and prove nothing about the replay rule this
    /// job actually fixed.
    @Test @MainActor func viewAgreesWithEngineModernPDFOnPageOneHeaderPresence() throws {
        for fixture in ["OLDTIMES.WS", "POWERUSE.WS"] {
            let state = try Self.state(fixture: fixture)
            let event = try #require(
                state.document.hfEvents.first { $0.kind == .header && !$0.text.isEmpty },
                "\(fixture) should declare a non-empty running head")
            let needle = Self.collapsedSpaces(String(event.text.split(separator: "#").first ?? ""))
            try #require(!needle.isEmpty)

            let bytes = emitPDF(state.document, mode: .modern)
            let enginePDF = try #require(PDFDocument(data: Data(bytes)), "\(fixture): engine Modern PDF should parse")
            try #require(enginePDF.pageCount > 0)
            let engineHasHeaderOnPageOne = Self.collapsedSpaces(enginePDF.page(at: 0)?.string ?? "").contains(needle)

            let view = Self.pagedModernView(for: state)
            try #require(view.pageCount > 0)
            let viewHasHeaderOnPageOne = Self.pagesWithHeader(view, containing: needle).contains(0)

            #expect(viewHasHeaderOnPageOne == engineHasHeaderOnPageOne,
                    "\(fixture): engine Modern PDF page-1 header present=\(engineHasHeaderOnPageOne), app view page-1 header present=\(viewHasHeaderOnPageOne)")
        }
    }

    // MARK: - Show Invisibles: the "[header]"-tagged annotation view (job 294/371), unchanged

    @Test @MainActor func modernInvisiblesOnTagsTheHeaderLine() throws {
        let state = try Self.state(fixture: "POWERUSE.WS")
        let headerText = try #require(
            state.document.hfEvents.first { $0.kind == .header && !$0.text.isEmpty }?.text)
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.renderWithInvisibles(state)
        let text = rendered.text.string
        #expect(text.contains("[header] " + headerText),
                "Show Invisibles must tag the running-head line so it reads apart from body text")
    }

    // MARK: - Page-break-origin label parity, Native vs Modern

    /// FORMFEED.WS's own name is the citation: a real `\u{0C}` byte in the stream, which
    /// `AnnotatedLayout`'s `InkKind.pageBreakOrigin` (Native) and `SemanticItem.pageBreak`'s
    /// `origin` (Modern, round 20's own restoration) both carry verbatim.
    @Test @MainActor func formFeedOriginReadsTheSameLabelInBothViews() throws {
        let state = try Self.state(fixture: "FORMFEED.WS")

        state.style.setManually(.native)
        let native = DocumentRenderer.renderWithInvisibles(state).text.string

        state.style.setManually(.modern)
        let modern = DocumentRenderer.renderWithInvisibles(state).text.string

        #expect(native.contains("form feed"), "Native's own invisibles view should label a real form-feed break")
        #expect(modern.contains("— form feed —"),
                "Modern must show the SAME 'form feed' label, not a generic '.pa' one, for a real form-feed byte")
        #expect(!modern.contains("— .pa —") || modern.contains("— form feed —"),
                "if FORMFEED.WS also carries an ordinary .pa break, both labels may appear, but form feed must too")
    }
}
