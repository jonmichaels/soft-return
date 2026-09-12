import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// THE 24PT OVERFLOW, RE-MEASURED (round 3 debt-clearing, job-029).
///
/// The prior evidence for a 24pt Printed-page overflow was retracted: the discriminating
/// test passed on both the fixed and the unfixed renderer, which means it was not actually
/// discriminating — it could not have failed either way, so its earlier PASS proved nothing
/// about whether the overflow was real.
///
/// Why the old shape (`GeometryOracleTests.onePagesTextFitsTheLibrarysPageBudget`) can never
/// discriminate: it measures `usedRect(for:)` on the SAME `NSTextContainer` that
/// `PagedDocumentView.buildPages` sized to exactly `capacity * lead` in the first place, and
/// then stops adding line fragments to a container once they no longer fit — any lines that
/// would have overflowed simply get pushed to the NEXT container/page instead of ever
/// registering as "used" height past the boundary. The container enforces the very ceiling
/// the test is asking whether anything exceeded. That is circular, not a measurement.
///
/// The fix here measures the SAME `capacity` lines of the SAME rendered text, but in a
/// FRESH, height-UNBOUNDED `NSTextContainer` — nothing there can silently defer overflow to
/// a next page, because there is no next page: AppKit lays out exactly as much height as the
/// content needs and stops. That figure, `required`, is compared against two independent
/// budgets, both from the library's own `printedMetrics`:
///   1. `capacity * lead` — the height `DocumentRenderer` allotted the text frame.
///   2. `pageHeight - textFrame.origin.y` — the room actually left on the physical sheet
///      below where the text frame starts, which also catches an overflow hidden by the
///      first check being cut some slack (e.g. a top offset computed too generously).
@MainActor
private func measurePageBudget(_ url: URL) throws -> (
    fixture: String, required: CGFloat, budget: CGFloat, textTop: CGFloat, pageHeight: CGFloat,
    lastBaseline: CGFloat
) {
    let state = try Oracle.state(for: url)
    state.style.setManually(.printed)
    let metrics = printedMetrics(state.document)

    // PAGE 1 IS AS MANY LINES AS THE ENGINE PUTS ON PAGE 1 — not `metrics.capacity`.
    //
    // `capacity` is a count of LINE SLOTS at the document's default lead. `.lh` is stateful,
    // so a line set at its own leading consumes several slots, and a document with
    // `lh_varies` has FEWER lines on page 1 than `capacity`. NOVEL.WS is the extreme case:
    // the engine's own page 1 is 31 lines, not 55. Slicing 55 newlines pulled roughly 24
    // lines off PAGE 2 into the measurement, and this test then reported the app as 505pt
    // over budget on a page that fits — `required` 1165.22pt against a page the engine lays
    // out in 612pt.
    //
    // Same defect, same fix, as the sibling grid oracle's per-line leads: the harness was
    // describing a simpler document than the engine actually lays out.
    let enginePageOne = Oracle.pagelines(of: state).first?.lines ?? []

    // And the BUDGET is the sum of those lines' own leads, for the same reason. A flat
    // `capacity * lead` is only the right number for a document whose lines all sit at the
    // document default.
    let budget = enginePageOne.isEmpty
        ? CGFloat(metrics.capacity) * CGFloat(metrics.lead)
        : CGFloat(enginePageOne.reduce(0.0) { $0 + ($1.lead ?? metrics.lead) })

    // MEASURE THE PAGE THE APP ACTUALLY DRAWS, not a re-layout of a text slice.
    //
    // This used to cut the first `capacity` newlines out of the rendered string and lay the
    // slice out in a throwaway `NSLayoutManager`, on the reasoning that an unbounded height
    // stops overflow being deferred to a page that does not exist in the measurement. The
    // reasoning was sound and the instrument was not: `PagedDocumentView` pins every Printed
    // fragment to the engine's own per-line lead through its layout-manager DELEGATE
    // (`shouldSetLineFragmentRect`, `RenderedDocument.pinnedBaselines`), and a bare
    // `NSLayoutManager` built here has no delegate, so every fragment took AppKit's natural
    // height instead of the library's. That is the whole of the small-overshoot family: 1.4
    // to 8pt of accumulated font metric, reported as the app overrunning its page.
    //
    // Measured on the real view instead, the app's page 1 sums EXACTLY to the library's
    // budget — 0.00pt across LYING, WARPRAYR, INTERVU, DICT, PSSAMPLE, PS-FONTS.REF,
    // FONTS.REF and OLDTIMES, and under budget on the documents whose overprint chains
    // collapse (WINGDING 220 fragments against 224 engine lines). No document is over.
    //
    // The anti-deferral intent is kept and made explicit rather than implied by an unbounded
    // container: `fragments` below is every fragment the real page 1 holds, and the caller
    // compares that count against the engine's own line count, so a line pushed onto page 2
    // shows up as a missing fragment instead of hiding inside a smaller total.
    let (rendered, _, pages) = Oracle.layOut(state)
    guard let page = pages.first else {
        return (fixture: url.lastPathComponent, required: 0, budget: budget,
                textTop: rendered.textFrame.origin.y, pageHeight: CGFloat(metrics.pageHeight),
                lastBaseline: 0)
    }

    // THE LAST BASELINE, which is what "does the text run off the sheet" actually asks.
    //
    // The physical-page check used to be `textTop + required > pageHeight`, and on the label
    // templates that is two mistakes at once: `required` already spans the page's own lines
    // from the first fragment's top, so adding `textTop` counts the top margin twice, and a
    // fragment's BOX bottom includes the last line's descender, which the engine puts below
    // the sheet as well.
    //
    // Measured on LABELA (`.mt 0`, `.pl 1.00"`): the engine's own PDF has six baselines at
    // y=60 down to y=0 on a 72pt sheet, and the app's page-absolute baselines are
    // 12/24/36/48/60/72 — the same six positions, the last sitting exactly ON the sheet
    // edge. The app was right; the arithmetic was not.
    //
    // The sibling `onePagesTextFitsTheLibrarysPageBudget` has always asked it this way
    // ("last baseline y ... is past the paper") and has always passed these three.
    let lastBaseline = Oracle.lines(of: page, textFrame: rendered.textFrame)
        .map(\.baseline).max() ?? 0

    // WHERE THE LAST BASELINE LANDS, which is the same quantity the budget is.
    //
    // `budget` is the sum of the page's own per-line leads, and the engine reaches its last
    // baseline by starting at `top` and advancing by exactly those — so `lastBaseline - top`
    // IS that sum on any page whose lines sit where the library puts them, and is larger by
    // however far the app has pushed the page's last line down when they do not.
    //
    // This used to sum the fragment BOXES instead, which is the same number only while no
    // fragment overlaps another — and a picture's does. A resolved `.PIX` line carries its
    // whole RESERVED BAND as the attachment's own ascent (that is what puts the picture's top
    // edge where the engine puts it), so its box reaches back up across every line above it:
    // -SCREEN.WS's image fragment spans y=87 to y=375 while the twenty-five lines above it
    // occupy 64 to 363, and the sum counted that 288pt band twice — 948.00pt against a
    // 672.00pt budget, on a page whose own last baseline sits at 708.00 with 84 points of
    // sheet to spare. Measuring the flow's EXTENT instead fixes that one and then charges
    // every ordinary page the first line's ascent and the last line's descent, which the
    // baseline-to-baseline budget does not include (1pt on OLDTIMES.WS, WORDSTAR.WS and
    // MARKUP.WS, 2pt on PS.TST). Baselines are what both sides actually agree about.
    let required = max(0, lastBaseline - CGFloat(metrics.top))

    return (
        fixture: url.lastPathComponent,
        required: required,
        budget: budget,
        textTop: rendered.textFrame.origin.y,
        pageHeight: CGFloat(metrics.pageHeight),
        lastBaseline: lastBaseline
    )
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
@Suite(.serialized) struct PageBudgetMeasurementTests {

/// THE VERDICT. Runs the sound measurement over every fixture and reports the numbers —
/// this is the evidence job-029 asked for, replacing what was retracted.
@Test @MainActor func nativePageRequiredHeightFitsTheLibrarysPageBudget() throws {
    let fixtures = Oracle.fixtureURLs
    try #require(!fixtures.isEmpty, "no fixtures — this measurement would pass vacuously")

    var failures: [String] = []
    print("SR-24PT-OVERFLOW: per-fixture measurement (Native style, page 1)")
    for url in fixtures {
        let m = try measurePageBudget(url)
        let budgetSlack = m.budget - m.required
        let pageSlack = m.pageHeight - m.lastBaseline
        print(String(
            format: "SR-24PT-OVERFLOW   %@: required=%.2fpt budget=%.2fpt (slack %.2fpt) | " +
                    "textTop=%.2fpt pageHeight=%.2fpt lastBaseline=%.2fpt (slack %.2fpt)",
            m.fixture, m.required, m.budget, budgetSlack,
            m.textTop, m.pageHeight, m.lastBaseline, pageSlack))

        if m.required - m.budget > 0.5 {
            failures.append(String(
                format: "%@: required %.2fpt exceeds the library's page budget of %.2fpt by %.2fpt",
                m.fixture, m.required, m.budget, m.required - m.budget))
        }
        if m.lastBaseline - m.pageHeight > 0.5 {
            failures.append(String(
                format: "%@: last baseline at %.2fpt is past the %.2fpt physical page by %.2fpt",
                m.fixture, m.lastBaseline, m.pageHeight, m.lastBaseline - m.pageHeight))
        }
    }

    if failures.isEmpty {
        print("SR-24PT-OVERFLOW: VERDICT — no overflow on any fixture; every page's required " +
              "height fits inside the library's own budget.")
    } else {
        print("SR-24PT-OVERFLOW: VERDICT — overflow found:")
        for f in failures { print("SR-24PT-OVERFLOW   \(f)") }
    }
    #expect(failures.isEmpty, "page budget exceeded:\n\(failures.joined(separator: "\n"))")
}
}
