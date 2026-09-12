import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// NOTHING FROM ONE PAGE IS EXPORTED ONTO ANOTHER.
///
/// `dataWithPDF(inside:)` re-bases the coordinate system so the captured rect's origin
/// becomes (0, 0), and this view's overlays — the oversized self-passes, the overprint
/// passes, the PCL programs — walk EVERY page and draw at document coordinates. On screen
/// that is right, because the view is the whole document. In a per-page capture it means
/// page one's ink is drawn into page two's file, at page two's origin less a page height and
/// the gap between sheets.
///
/// Measured on DARKNESS.WS before the fix: its oversized title, painted by
/// `drawOversizedSelfPasses`, reported a page-local y of -764.0 on page 2 and -1576.0 on
/// page 3 against the 48.0 it has on page 1 — off the top of its own sheet, which is why
/// looking at the export never showed it. 54 words across the document sat at a negative y.
///
/// A negative page-local y is the general form of that bug, so that is what this asserts,
/// over the whole corpus rather than the one document that exposed it.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct ExportPageBleedTests {

    /// THE CORPUS-WIDE FORM, over every fixture rather than the one document that exposed
    /// it. A negative page-local y is the general shape of the bug: ink drawn at another
    /// page's coordinates lands above its own sheet, where nobody looking at the export will
    /// ever see it.
    @Test @MainActor func noExportedWordSitsAboveItsOwnPage() throws {
        var offenders: [String] = []
        var checked = 0
        for url in Oracle.fixtureURLs {
            guard let state = try? Oracle.state(for: url),
                  let pdf = try? Oracle.appNativePDF(for: url, state: state),
                  let words = try? AppPDFWords.payload(from: pdf).words
            else { continue }
            checked += 1
            let above = words.filter { $0.y_top_pt < 0 }
            guard !above.isEmpty else { continue }
            // `-PATCHES.WS` used to need its own skip here and no longer reaches this loop
            // at all: `Oracle.degenerateDocuments` excludes it by name for the whole test
            // target (Jon's ruling 2026-09-10, planning #261). The measurement that made the
            // skip necessary is worth keeping written down — it declares `.pl 0`, a page
            // length of ZERO, so the engine's own footer row (`pl - mb + fm`) goes negative,
            // its model puts the automatic page number at y=852.0 on a 792pt sheet and its
            // own writer draws it (the guard is `y >= 0`, and 852 passes); the app
            // reproduced that faithfully at `baselineFromTop` -60.0 on all 22 pages. Both
            // renderers agreed, and what they agreed on was off the sheet.
            let worst = above.min { $0.y_top_pt < $1.y_top_pt }!
            offenders.append("""
                \(url.lastPathComponent): \(above.count) word(s) above their own page, \
                worst \(worst.text.debugDescription) at y=\(worst.y_top_pt) on page \(worst.page)
                """)
        }
        try #require(checked > 0, "no fixture exported a Printed PDF — this would pass vacuously")
        #expect(offenders.isEmpty, """
            \(offenders.count) document(s) export ink from one page onto another: \
            \(offenders.prefix(6).joined(separator: "; "))
            """)
    }

    /// AND THE PAGE THAT OWNS THE INK STILL HAS IT. Clipping a capture to its own page must
    /// not lose the page's own overlay content — DARKNESS.WS's title belongs on page 1 and
    /// is drawn there by the same overlay this fix constrains.
    @Test @MainActor func thePageThatOwnsTheInkKeepsIt() throws {
        let url = try #require(Oracle.fixtureURLs.first { $0.lastPathComponent == "DARKNESS.WS" })
        let state = try Oracle.state(for: url)
        let pdf = try Oracle.appNativePDF(for: url, state: state)
        let words = try AppPDFWords.payload(from: pdf).words
        let title = words.first { $0.page == 1 && $0.text.contains("PERSON") }
        #expect(title != nil, "DARKNESS.WS lost its own oversized title from page 1")
        #expect(title.map { abs($0.y_top_pt - 48.0) < 0.5 } ?? false,
                "the title moved: y=\(title?.y_top_pt ?? -1), expected 48.0")
    }
}
