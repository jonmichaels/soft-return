import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// A PAGE'S NEWSPAPER COLUMNS ARE TEXT, and this is what that has to mean.
///
/// Item 19 (Jon's ruling, 2026-09-10) put every column back into AppKit's flow with its own
/// text container, after a period of painting them (ac1835e) that made the geometry right
/// and the text unreachable. "Real text" is not a property of the renderer, though — it is a
/// property of what a reader can DO — so these assert the four things a reader would notice
/// and nothing about how the columns are drawn.
///
/// FORMFEED.WS page 7 is the two-column case (three lines each) and WINGDING.CHT page 1 the
/// five-column one (46/46/46/46/36 fragments), so the same rules are checked where the
/// second column is one of two and where it is one of five.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct ColumnsAreTextTests {

    /// One page's columns: the text view AppKit gave each, and the character range each holds.
    @MainActor
    private static func columns(of fixture: String, page: Int)
        throws -> (rendered: RenderedDocument, views: [NSTextView], ranges: [NSRange])
    {
        let url = try #require(Oracle.fixtureURLs.first { $0.lastPathComponent == fixture },
                               "\(fixture) is not in the fixture set")
        let state = try Oracle.state(for: url)
        let (rendered, view, _) = Oracle.layOut(state)
        try #require(view.pageViews.indices.contains(page), "\(fixture) has no page \(page + 1)")
        let views = [view.pageViews[page]] + view.columnTextViews(atPage: page)
        let ranges: [NSRange] = views.compactMap { textView in
            guard let manager = textView.layoutManager, let container = textView.textContainer
            else { return nil }
            manager.ensureLayout(for: container)
            return manager.characterRange(forGlyphRange: manager.glyphRange(for: container),
                                          actualGlyphRange: nil)
        }
        return (rendered, views, ranges)
    }

    /// THE COLUMNS ARE ONE DOCUMENT, IN THE MODEL'S ORDER.
    ///
    /// Every column's characters are a contiguous run of the same text storage, and they
    /// follow one another in the order the engine states them (`applyColumns` concatenates
    /// column 0's lines, then column 1's). That is what makes everything below possible:
    /// Speech, VoiceOver and a copied selection all read the storage, and they read it in
    /// this order.
    @Test @MainActor func everyColumnIsPartOfTheSameDocumentInOrder() throws {
        for (fixture, page, expected) in [("FORMFEED.WS", 6, 2), ("WINGDING.CHT", 0, 5)] {
            let (_, views, ranges) = try Self.columns(of: fixture, page: page)
            #expect(views.count == expected,
                    "\(fixture) page \(page + 1): \(views.count) column view(s), expected \(expected)")
            #expect(ranges.count == views.count,
                    "\(fixture) page \(page + 1): a column view has no laid-out range")
            for (index, range) in ranges.enumerated() {
                #expect(range.length > 0,
                        "\(fixture) page \(page + 1) column \(index) holds no characters at all")
            }
            for (earlier, later) in zip(ranges, ranges.dropFirst()) {
                #expect(NSMaxRange(earlier) == later.location, """
                    \(fixture) page \(page + 1): column ranges are not contiguous in the \
                    model's order — \(earlier) then \(later)
                    """)
            }
        }
    }

    /// A SELECTION CROSSES A COLUMN BOUNDARY, and copying it yields the model's order.
    ///
    /// The columns are separate text VIEWS, which is the thing worth checking rather than
    /// assuming: AppKit shares one selection across every view on a layout manager, so a
    /// range that starts in column 0 and ends in column 1 is one selection and the text it
    /// yields is the two columns' text in order — which is exactly what lands on the
    /// pasteboard.
    @Test @MainActor func aSelectionSpansTwoColumnsAndCopiesInOrder() throws {
        let (rendered, views, ranges) = try Self.columns(of: "FORMFEED.WS", page: 6)
        try #require(views.count >= 2 && ranges.count >= 2, "FORMFEED.WS page 7 lost its second column")
        let boundary = NSMaxRange(ranges[0])
        let across = NSRange(location: boundary - 6, length: 12)
        views[0].setSelectedRange(across)
        #expect(views[0].selectedRange() == across, "the first column did not take the selection")
        #expect(views[1].selectedRange() == across, """
            the second column does not share the selection — a drag from one column into the \
            next would not be one selection, got \(views[1].selectedRange())
            """)
        let copied = (rendered.text.string as NSString).substring(with: across)
        let tail = (rendered.text.string as NSString).substring(with: NSRange(location: across.location, length: 6))
        let head = (rendered.text.string as NSString).substring(with: NSRange(location: boundary, length: 6))
        #expect(copied == tail + head, """
            a selection across the boundary does not read as column 0's tail then column 1's \
            head: \(copied.debugDescription)
            """)
    }

    /// FIND REACHES A WORD THAT ONLY EXISTS IN A LATER COLUMN.
    ///
    /// Find searches the text storage, so the question is whether a later column's words are
    /// IN it and land in that column's own container — which is what a found range being
    /// highlighted in the right place depends on.
    @Test @MainActor func findLocatesAWordInALaterColumn() throws {
        let (rendered, views, ranges) = try Self.columns(of: "FORMFEED.WS", page: 6)
        try #require(views.count >= 2 && ranges.count >= 2, "FORMFEED.WS page 7 lost its second column")
        let manager = try #require(views[1].layoutManager)
        let secondColumn = (rendered.text.string as NSString).substring(with: ranges[1])
        // A word of the second column's own text, taken from the column itself rather than
        // written down here, so this cannot go stale against the fixture.
        let word = try #require(secondColumn.split(whereSeparator: { $0.isWhitespace })
                                    .first(where: { $0.count >= 5 }).map(String.init),
                                "the second column has no word to search for")
        // Searched FORWARD FROM the column's own start, not from the document's: a word of
        // ordinary prose usually occurs earlier too, and the first hit in the whole storage
        // says nothing about whether this column's copy is reachable.
        let found = (rendered.text.string as NSString).range(
            of: word, options: [],
            range: NSRange(location: ranges[1].location,
                           length: rendered.text.length - ranges[1].location))
        #expect(found.location != NSNotFound, "Find could not reach \(word.debugDescription) in the storage")
        let glyph = manager.glyphIndexForCharacter(at: found.location)
        let container = manager.textContainer(forGlyphAt: glyph, effectiveRange: nil)
        #expect(container === views[1].textContainer, """
            \(word.debugDescription) is in the storage but not laid out in the column that \
            shows it, so a found range would highlight in the wrong place
            """)
    }

    /// SHOW INVISIBLES MARKS A LATER COLUMN'S LINES TOO.
    ///
    /// The annotated render is its own `RenderedDocument` (`renderNativeAnnotated`), so the
    /// question is whether a later column's text is in it at all — a column that never
    /// reached the annotated flow would show no marks however the toggle is set.
    @Test @MainActor func showInvisiblesReachesALaterColumn() throws {
        let (rendered, _, ranges) = try Self.columns(of: "FORMFEED.WS", page: 6)
        try #require(ranges.count >= 2, "FORMFEED.WS page 7 lost its second column")
        let url = try #require(Oracle.fixtureURLs.first { $0.lastPathComponent == "FORMFEED.WS" })
        let state = try Oracle.state(for: url)
        let annotated = DocumentRenderer.renderWithInvisibles(state)
        let secondColumn = (rendered.text.string as NSString).substring(with: ranges[1])
        let firstLine = try #require(secondColumn.split(separator: "\n").first.map(String.init),
                                     "the second column has no line")
        #expect(annotated.text.string.contains(firstLine.trimmingCharacters(in: .whitespaces)), """
            the second column's own text is absent from the Show Invisibles render, so no \
            mark of any kind could appear beside it
            """)
    }
}
