import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Planning #221, the app's half — Jon's ruling 2026-09-07, verbatim: "endnotes go right at
/// the end of text / image on the last page unless there are footnotes on that page. Then
/// the endnotes start on a new page."
///
/// ## Why one rule needs two different tests
///
/// The NATIVE view implements no pagination of its own: it places the engine's own
/// `docToPagelines(doc, printed: true)` pages, container for container
/// (`PagedDocumentView.buildExplicitPages`). So the trailing-`.pa` rule (#228) and the
/// engine's endnote placement reach the screen by construction, and what is worth pinning is
/// exactly that — that the app builds as many real page containers as the library
/// paginated. It is a cheap assertion and a real one: it is what breaks the day somebody
/// gives the Native view a paginator of its own, and it cannot go stale as the engine's page
/// breaks move, because it asks the engine for the answer on every run.
///
/// The MODERN view is the opposite case. It reflows through AppKit, so no engine page break
/// reaches it at all, and the rule above had to be implemented a second time — see
/// `PagedDocumentView.buildPages`' own citation, and `RenderedDocument
/// .modernEndnoteAppendixStart` for why the app can only apply it one real page at a time
/// where the engine applies it up front.
@Suite struct Planning221NotePaginationTests {

    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    @MainActor
    private static func modernView(for url: URL) throws -> (PagedDocumentView, RenderedDocument) {
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "Planning221.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults),
                                      docPath: url.path)
        state.style.setManually(.modern)
        let rendered = DocumentRenderer.render(state, style: .modern)
        let view = PagedDocumentView()
        view.setContent(rendered, display: .continuousScroll)
        view.setFrameSize(view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        return (view, rendered)
    }

    /// The character range AppKit actually placed in one real page — read per CONTAINER,
    /// never from `textStorage`, which is the same shared storage for every page and would
    /// prove nothing about which page anything landed on (`Job439ModernAppendixLiveTests
    /// .reallyPlacedText`'s own citation).
    @MainActor
    private static func placedRange(_ view: PagedDocumentView, page index: Int) -> NSRange? {
        guard let lm = view.primaryTextView?.layoutManager,
              index < view.pageViews.count,
              let container = view.pageViews[index].textContainer else { return nil }
        let range = lm.characterRange(forGlyphRange: lm.glyphRange(for: container), actualGlyphRange: nil)
        return range.location == NSNotFound ? nil : range
    }

    // MARK: - Modern

    /// THE RULE. `BOTHNOTE.WS` carries one footnote and one endnote and is a few lines long,
    /// so both used to sit on page 1 together, the endnote appendix tucked under the footnote
    /// block. Jon's ruling says the appendix opens a page of its own instead.
    ///
    /// A synthetic fixture is the right instrument rather than a real document: it is the
    /// only fixture in this tree carrying both note kinds at once (that is what it was built
    /// for, b27 item 6), and it needs no private corpus, so this rule stays pinned on every
    /// machine rather than only on an armed one.
    @Test @MainActor func modernEndnoteAppendixOpensItsOwnPageWhenThePageHasAFootnote() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("BOTHNOTE.WS")
        let (view, rendered) = try Self.modernView(for: url)

        let appendixStart = try #require(
            rendered.modernEndnoteAppendixStart,
            "BOTHNOTE.WS carries an endnote, so renderModern must record where its appendix starts")

        // The footnote has to actually be ON page 1, or this document is not exercising the
        // rule at all and a pass below would mean nothing.
        try #require(!view.footnoteBlock(atPageIndex: 0).isEmpty,
                     "BOTHNOTE.WS's footnote must land on page 1 for this rule to be under test")

        #expect(view.pageCount >= 2, """
            the endnote appendix must open a new page when its page already carries footnotes \
            (Jon's ruling 2026-09-07), but the whole document laid out on \(view.pageCount) page(s)
            """)

        // Not merely "a second page exists" — the appendix itself has to be what page 2
        // begins with, and page 1 must no longer hold any part of it.
        let first = try #require(Self.placedRange(view, page: 0), "no real first page")
        let second = try #require(Self.placedRange(view, page: 1), "no real second page")
        #expect(first.location + first.length <= appendixStart, """
            page 1 ends at character \(first.location + first.length) but the endnote appendix \
            starts at \(appendixStart) — page 1 still carries part of the appendix
            """)
        #expect(second.location == appendixStart, """
            page 2 starts at character \(second.location); the appendix starts at \
            \(appendixStart) — the appendix must BEGIN the new page, not merely appear on it
            """)
        // The 20-dash separator is the appendix's own first line; seeing it open page 2 is
        // the reader's version of the two offsets above.
        let placed = (rendered.text.string as NSString).substring(with: second)
        #expect(placed.hasPrefix(String(repeating: "-", count: 20)),
                "page 2 must open with the note appendix's own 20-dash separator, got \"\(placed.prefix(24))\"")
    }

    /// The other half of the same ruling, and the guard against "fixing" it by always
    /// breaking: with no footnote on the page, nothing moves. The engine pins this case too
    /// (`modernPDFEndnoteAppendixContinuesLastPageWithNoFootnotes`).
    ///
    /// Written to a temporary file rather than committed because what it needs is a document
    /// with an endnote and NO footnote anywhere — the one shape no committed fixture has, and
    /// not worth a new permanent fixture for a single negative case.
    @Test @MainActor func modernShortDocumentWithNoFootnoteKeepsItsSinglePage() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planning221-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("NOFOOT.WS")
        try Data(Array("""
            An Endnote With No Footnote\r
            \r
            One short paragraph, well clear of the bottom of its own page, carrying no note\r
            of any kind at all.\r
            """.utf8)).write(to: url)

        let (view, _) = try Self.modernView(for: url)
        #expect(view.footnoteBlock(atPageIndex: 0).isEmpty,
                "this document has no footnote, so page 1 must reserve no footnote block")
        #expect(view.pageCount == 1,
                "a short document with no footnote must not gain a page — got \(view.pageCount)")
    }

    /// The rule must not leave an empty page behind it. A forced break placed at or past the
    /// end of the text is exactly how an off-by-one here would show up, and it would show up
    /// on Jon's screen as a blank final page rather than as any failing measurement.
    @Test @MainActor func modernNeverEndsOnAnEmptyPage() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("BOTHNOTE.WS")
        let (view, rendered) = try Self.modernView(for: url)
        let last = view.pageCount - 1
        try #require(last >= 0, "no pages at all")
        let range = try #require(Self.placedRange(view, page: last),
                                 "the last Modern page (index \(last)) placed no characters at all")
        let text = (rendered.text.string as NSString).substring(with: range)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, """
            the last Modern page (index \(last) of \(view.pageCount)) carries no visible text — \
            an empty trailing page
            """)
    }

    // MARK: - Native

    /// Native builds one real page container per library page — including for the documents
    /// the trailing-`.pa` rule (#228) and today's endnote-placement rules changed.
    ///
    /// The expectation comes from `docToPagelines` on every run rather than from a recorded
    /// number, so this cannot go stale the next time those rules move; what it pins is that
    /// the VIEW honours whatever the library decided, which `buildExplicitPages` could
    /// silently stop doing.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    @MainActor func nativeBuildsOnePageContainerPerLibraryPage() throws {
        var failures: [String] = []
        var checked = 0
        for url in Oracle.fixtureURLs {
            guard let state = try? Oracle.state(for: url) else { continue }
            let libraryPages = Oracle.pagelines(of: state).count
            let (_, _, pages) = Oracle.layOut(state)
            checked += 1
            if pages.count != libraryPages {
                failures.append("\(url.lastPathComponent): the app built \(pages.count) Native page(s), "
                                + "the library paginates it into \(libraryPages)")
            }
        }
        try #require(checked > 0, "no fixtures — this oracle would pass vacuously")
        let summary = "Native page count does not match the library: "
            + "\(failures.count) document(s) of \(checked)\n" + failures.joined(separator: "\n")
        #expect(failures.isEmpty, "\(summary)")
    }
}
