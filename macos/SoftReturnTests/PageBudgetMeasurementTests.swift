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
    fixture: String, required: CGFloat, budget: CGFloat, textTop: CGFloat, pageHeight: CGFloat
) {
    let state = try Oracle.state(for: url)
    state.style.setManually(.printed)
    let metrics = printedMetrics(state.document)
    let rendered = DocumentRenderer.render(state)
    let capacity = metrics.capacity

    // Exactly the first `capacity` lines: locate the capacity-th newline and cut BEFORE it,
    // so the slice carries `capacity` lines joined by `capacity - 1` newlines — the same
    // shape a from-scratch page 1 has, with no trailing blank line the cut itself would add.
    let full = rendered.text.string as NSString
    var newlinesSeen = 0
    var cut = full.length
    var searchFrom = 0
    while searchFrom < full.length, newlinesSeen < capacity {
        let range = full.range(of: "\n", range: NSRange(location: searchFrom, length: full.length - searchFrom))
        guard range.location != NSNotFound else { break }
        newlinesSeen += 1
        if newlinesSeen == capacity {
            cut = range.location
            break
        }
        searchFrom = range.location + 1
    }
    let pageOneText = rendered.text.attributedSubstring(from: NSRange(location: 0, length: cut))

    // A fresh, independent layout chain — NOT `PagedDocumentView`'s — with an unbounded
    // height, so nothing here can defer overflow to a page that does not exist in this
    // measurement at all.
    let storage = NSTextStorage(attributedString: pageOneText)
    let manager = NSLayoutManager()
    manager.allowsNonContiguousLayout = false
    storage.addLayoutManager(manager)
    let container = NSTextContainer(
        size: CGSize(width: rendered.textFrame.width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
    container.heightTracksTextView = false
    manager.addTextContainer(container)
    manager.ensureLayout(for: container)

    let required = manager.usedRect(for: container).height

    return (
        fixture: url.lastPathComponent,
        required: required,
        budget: CGFloat(capacity) * CGFloat(metrics.lead),
        textTop: rendered.textFrame.origin.y,
        pageHeight: CGFloat(metrics.pageHeight)
    )
}

/// THE VERDICT. Runs the sound measurement over every fixture and reports the numbers —
/// this is the evidence job-029 asked for, replacing what was retracted.
@Test @MainActor func printedPageRequiredHeightFitsTheLibrarysPageBudget() throws {
    let fixtures = Oracle.fixtureURLs
    try #require(!fixtures.isEmpty, "no fixtures — this measurement would pass vacuously")

    var failures: [String] = []
    print("SR-24PT-OVERFLOW: per-fixture measurement (Printed style, page 1)")
    for url in fixtures {
        let m = try measurePageBudget(url)
        let budgetSlack = m.budget - m.required
        let pageSlack = m.pageHeight - (m.textTop + m.required)
        print(String(
            format: "SR-24PT-OVERFLOW   %@: required=%.2fpt budget=%.2fpt (slack %.2fpt) | " +
                    "textTop=%.2fpt pageHeight=%.2fpt bottom=%.2fpt (slack %.2fpt)",
            m.fixture, m.required, m.budget, budgetSlack,
            m.textTop, m.pageHeight, m.textTop + m.required, pageSlack))

        if m.required - m.budget > 0.5 {
            failures.append(String(
                format: "%@: required %.2fpt exceeds the library's page budget of %.2fpt by %.2fpt",
                m.fixture, m.required, m.budget, m.required - m.budget))
        }
        if m.textTop + m.required - m.pageHeight > 0.5 {
            failures.append(String(
                format: "%@: text bottom at %.2fpt runs %.2fpt past the %.2fpt physical page",
                m.fixture, m.textTop + m.required, m.textTop + m.required - m.pageHeight, m.pageHeight))
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
