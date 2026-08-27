import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 224 (b12 leg, branch `native-overprint`): `.overprint` `PageLine` chains (LJ6DTP's
/// white-on-black knockouts, two-pass flush-right bars, banner strikeovers) now composite
/// onto ONE fragment's baseline (`DocumentRenderer.renderPrinted`'s `overprintPasses`,
/// `PagedDocumentView.swift`'s `PageTextView.drawOverprintPasses`) instead of each chain
/// member getting its own separate (if `nearZeroLead`-tall) fragment. See this job's report
/// for the full before/after — this file is the PERMANENT regression coverage, not the
/// throwaway probe that first found the fixture's own chain structure.
@MainActor
/// Job 535: every test in this suite reads `TestDocs/ws7` (`OracleByteParityTests.ws7Directory`)
/// — gated at the suite level so a bare stranger run skips all of it cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct OverprintCompositingTests {
    static var lj6dtpDoc: Document {
        get throws {
            let url = OracleByteParityTests.ws7Directory.appendingPathComponent("LJ6DTP.WS")
            return try parse([UInt8](try Data(contentsOf: url)), variant: nil)
        }
    }

    /// LJ6DTP.WS is real field evidence, not a synthetic fixture: pages 1 and 6 each carry
    /// `.overprint` chains up to 3 deep (two flush-right bar passes, then the knockout text).
    /// If this ever reports zero, either the fixture changed or the engine's own bare-CR
    /// parsing (`ParseWS.swift:783-785`) regressed — either way this suite's other
    /// assertions below would be vacuous, so it is checked explicitly.
    @Test func fixtureActuallyHasOverprintChains() throws {
        let pages = docToPagelines(try Self.lj6dtpDoc, printed: true)
        let chainCount = pages.reduce(0) { total, page in
            total + (0..<page.count).filter { page[$0].overprint }.count
        }
        #expect(chainCount > 0, "vacuity guard: LJ6DTP.WS has no .overprint PageLines any more")
    }

    /// Every `.overprint`-chained line beyond the first member of its chain must be captured
    /// as a composited PASS, not given its own line fragment — the whole point of this job.
    /// Structural proxy for "no separate fragment": the number of REAL (pre-padding)
    /// fragments `DocumentRenderer` emits for a page must be STRICTLY LESS than the engine's
    /// own `PageLine` count whenever that page has a chain, and `overprintPasses` must
    /// account for exactly the difference.
    ///
    /// Job 227 added a SECOND, entirely separate pass mechanism for a different reason
    /// (`RenderedDocument.oversizedSelfPasses` — a chain base's own glyph too tall for its
    /// fragment, LJ6DTP.WS's 72pt banner chief among them) that does NOT touch
    /// `overprintPasses` at all (`renderPrinted`'s own call site: the self-pass goes into a
    /// SEPARATE array precisely so this invariant — unrelated to job 227 — never has to
    /// know it exists). `oversizedSelfPassesMatchLineExceedsFragment` below is that job's own
    /// permanent coverage.
    @Test func chainedLinesCollapseToOneFragmentEach() throws {
        let doc = try Self.lj6dtpDoc
        let enginePages = docToPagelines(doc, printed: true)
        let state = try Oracle.state(for: OracleByteParityTests.ws7Directory
            .appendingPathComponent("LJ6DTP.WS"))
        let rendered = DocumentRenderer.render(state)

        var sawAChain = false
        for (pageIndex, page) in enginePages.enumerated() {
            let chainedLineCount = (0..<page.count).filter { page[$0].overprint }.count
            guard chainedLineCount > 0 else { continue }
            sawAChain = true

            // Real (non-padding) fragments on this page: every entry in `overprintPasses`
            // up to the first one belonging to an all-blank padding run. Padding lines never
            // carry passes, so counting entries with either real content or a non-empty
            // pass list undercounts nothing real.
            let passes = rendered.overprintPasses[pageIndex]
            let totalPassedLines = passes.reduce(0) { $0 + $1.count }
            // Every chained line (every `.overprint == true` PageLine) is EITHER the first
            // member of its own chain (never true — the first member's OWN flag can be true
            // too, if the chain is 3+ deep) or captured in some fragment's pass list. The
            // exact invariant `DocumentRenderer.renderPrinted` establishes: real fragments
            // emitted for this page's REAL content == number of chains (maximal overprint
            // runs) on it, and every chain member from the 2nd on is a pass — i.e.
            // `page.count == realFragments + totalPassedLines`.
            var i = 0
            var realFragments = 0
            while i < page.count {
                var j = i
                while page[j].overprint, j + 1 < page.count { j += 1 }
                realFragments += 1
                i = j + 1
            }
            #expect(realFragments + totalPassedLines == page.count, Comment(rawValue:
                    "page \(pageIndex + 1): \(realFragments) real fragments + " +
                    "\(totalPassedLines) passed lines != \(page.count) engine PageLines"))
            #expect(realFragments < page.count,
                    "page \(pageIndex + 1) has a chain but collapsed to zero fewer fragments")
            #expect(totalPassedLines == chainedLineCount, Comment(rawValue:
                    "page \(pageIndex + 1): passed-line count should equal the number of " +
                    "`.overprint`-flagged PageLines feeding a successor"))
        }
        #expect(sawAChain, "vacuity guard: no page in the rendered output had a chain to collapse")
    }

    /// Job 227's own permanent regression coverage: `RenderedDocument.oversizedSelfPasses`
    /// carries a self-pass for a chain base EXACTLY where `DocumentRenderer
    /// .lineExceedsFragment` — the SAME predicate `renderPrinted` itself calls — says that
    /// base's own tallest glyph is too tall for its fragment, nowhere else. Re-derives
    /// `advanceLead`'s own tiny formula the same deliberate way the test above duplicates
    /// the chain-walk itself, rather than trusting `renderPrinted`'s internal bookkeeping
    /// against itself.
    @Test func oversizedSelfPassesMatchLineExceedsFragment() throws {
        let doc = try Self.lj6dtpDoc
        let metrics = printedMetrics(doc)
        let fallback = NSFont(name: "Courier", size: CGFloat(metrics.size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(metrics.size), weight: .regular)
        let enginePages = docToPagelines(doc, printed: true)
        let state = try Oracle.state(for: OracleByteParityTests.ws7Directory
            .appendingPathComponent("LJ6DTP.WS"))
        let rendered = DocumentRenderer.render(state)

        // `DocumentRenderer.renderPrinted`'s own `nearZeroLead`/`advanceLead` — a line's
        // fragment height is the gap BEFORE THE NEXT GROUP, not its own lead.
        let nearZeroLead = 0.01
        func advanceLead(_ page: Page, after i: Int) -> Double {
            guard i < page.count - 1 else { return metrics.lead }
            return page[i].overprint ? nearZeroLead : (page[i + 1].lead ?? metrics.lead)
        }

        var sawAnOversizedBase = false
        for (pageIndex, page) in enginePages.enumerated() {
            let selfPasses = rendered.oversizedSelfPasses[pageIndex]
            var i = 0
            var fragmentIndex = 0
            while i < page.count {
                var j = i
                while page[j].overprint, j + 1 < page.count { j += 1 }
                let oversized = DocumentRenderer.lineExceedsFragment(
                    page[i], assignedLead: advanceLead(page, after: j),
                    fallback: fallback, fonts: doc.fonts, defaultSize: metrics.size)
                if oversized { sawAnOversizedBase = true }
                #expect((selfPasses[fragmentIndex] != nil) == oversized, Comment(rawValue:
                        "page \(pageIndex + 1) fragment \(fragmentIndex): self-pass present=" +
                        "\(selfPasses[fragmentIndex] != nil) but lineExceedsFragment=\(oversized)"))
                i = j + 1
                fragmentIndex += 1
            }
        }
        #expect(sawAnOversizedBase,
                "vacuity guard: no page had a base line lineExceedsFragment called oversized")
    }

    /// LJ6DTP.WS's page count STILL does not match the engine after this job — see this
    /// job's report. The overprint chains this fix collapses (pages 1 and 6, up to 3 deep)
    /// turned out NOT to be the page-count desync's cause: `DocumentRenderer`'s own
    /// `measuredHeight`-based padding is SELF-COMPENSATING (it pads a page's real content up
    /// to `capacity * metrics.lead` regardless of how many real fragments make up that
    /// content), so removing near-zero overprint-pass fragments simply shifts MORE blank
    /// padding lines into their place — verified directly (A/B via `git stash`): every
    /// container's `usedRect` height is unchanged to the point before/after this fix, and
    /// the same single glyph still overflows page 8 into a 9th container. The real cause is
    /// the SAME pre-existing "isolated probe measurably disagrees with the real embedded
    /// chain" residual `DocumentRenderer.renderPrinted`'s own doc comment on `measuredHeight`
    /// already documents for this fixture (job 202) — a different, still-open follow-up.
    /// Job 224 found this was NOT an overprint-compositing regression (verified A/B); the
    /// actual root cause — job 202's isolated-vs-embedded AppKit measurement residual — is
    /// FIXED as of job 225 (`PagedDocumentView.buildExplicitPages`: page containers are now
    /// sized from a probe of the real embedded flow, not padded to `capacity` from an
    /// isolated one). Permanent regression coverage now that it is closed, not a
    /// `withKnownIssue`.
    @Test func pageCountMatchesEngine() throws {
        let state = try Oracle.state(for: OracleByteParityTests.ws7Directory
            .appendingPathComponent("LJ6DTP.WS"))
        let (_, _, pages) = Oracle.layOut(state)
        let engineCount = docToPagelines(try Self.lj6dtpDoc, printed: true).count
        #expect(pages.count == engineCount,
                "LJ6DTP.WS paginates to \(pages.count) app pages vs \(engineCount) engine pages")
    }
}
