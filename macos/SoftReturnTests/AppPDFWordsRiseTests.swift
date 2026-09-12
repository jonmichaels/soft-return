import Foundation
import Testing
@testable import SoftReturn

/// A RAISED MARKER BELONGS TO THE LINE IT WAS RAISED FROM.
///
/// `AppPDFWords.snappedBaselines` is the rule (ported from ctrl-kd, 2026-09-07), and this
/// pins it directly rather than through a rendered document: the two producers disagree
/// about a superscript's baseline — the engine's schema never applies the rise to `y`, a
/// Quartz PDF bakes it into the text matrix — so read by exact baseline the app's footnote
/// marker became a line of its own.
@Suite struct AppPDFWordsRiseTests {

    /// The case that made this necessary: a line of prose with one raised marker two points
    /// above it. The marker joins the line; the line does not move.
    @Test func aRaisedMarkerJoinsItsOwnLine() {
        let mapping = AppPDFWords.snappedBaselines([100.0: 42, 98.0: 1])
        #expect(mapping[98.0] == 100.0, "the marker did not join its line, got \(mapping[98.0] ?? -1)")
        #expect(mapping[100.0] == 100.0, "the line itself moved, got \(mapping[100.0] ?? -1)")
    }

    /// TWO REAL LINES ARE NEVER MERGED at an ordinary lead, which is outside the window.
    @Test func twoRealLinesAreNeverMerged() {
        let mapping = AppPDFWords.snappedBaselines([100.0: 40, 112.0: 38])
        #expect(mapping[100.0] == 100.0, "a real line was pulled onto its neighbour")
        #expect(mapping[112.0] == 112.0, "a real line was pulled onto its neighbour")
    }

    /// NOR AT A LEAD SMALLER THAN THE WINDOW, which is the case the window alone cannot
    /// answer. MARKUP.WS sets its whole page at a 2pt lead, so every line on it sits inside a
    /// 6pt window of three others and every one of them is strictly heavier than some
    /// neighbour. Weight against the PAGE's own typical line is what separates them: these are
    /// all ordinary lines, so none is a fragment of another.
    @Test func linesTwoPointsApartAreStillLines() {
        let weights = [38.0: 48, 40.0: 50, 42.0: 50, 44.0: 49, 46.0: 47]
        let mapping = AppPDFWords.snappedBaselines(weights)
        for baseline in weights.keys {
            #expect(mapping[baseline] == baseline,
                    "a 2pt-lead line at \(baseline) was pulled onto \(mapping[baseline] ?? -1)")
        }
    }

    /// AND A RAISED RUN IS STILL SNAPPED at that lead, however long it is — SUB-SUPE.TST's
    /// own 22-character raised runs against 40-character lines, which is not a several-fold
    /// minority and IS a fragment of this page's own typical line.
    @Test func aLongRaisedRunStillJoinsItsLine() {
        let weights = [60.0: 55, 72.0: 40, 74.0: 22, 84.0: 58, 96.0: 60, 108.0: 57]
        let mapping = AppPDFWords.snappedBaselines(weights)
        #expect(mapping[74.0] == 72.0,
                "the raised run did not join its line, got \(mapping[74.0] ?? -1)")
        #expect(mapping[72.0] == 72.0, "the line itself moved, got \(mapping[72.0] ?? -1)")
    }

    /// A RUN CAN BE HALF ITS LINE and still be a run. SUB-SUPE.TST page 2's lowered
    /// "smallest possible bit of time." is 29 characters against a page whose typical line is
    /// nearer 56 — outside the light-piece share by one character, and plainly a piece of the
    /// 60-character line the engine draws it on. What settles it is what the two make
    /// TOGETHER: one line's worth.
    @Test func twoPiecesThatMakeOneLineAreOneLine() {
        let weights = [60.0: 55, 72.0: 30, 74.0: 29, 84.0: 58, 96.0: 60, 108.0: 57]
        let mapping = AppPDFWords.snappedBaselines(weights)
        #expect(mapping[74.0] == 72.0,
                "the lowered run did not join its line, got \(mapping[74.0] ?? -1)")
    }

    /// AND TWO PIECES THAT MAKE TWO LINES ARE TWO LINES, at any spacing. This is MARKUP.WS's
    /// own page read the other way round: 50 and 50 add up to twice its typical line.
    @Test func twoPiecesThatMakeTwoLinesStayTwoLines() {
        let weights = [38.0: 50, 40.0: 50, 42.0: 49, 44.0: 48, 46.0: 47]
        let mapping = AppPDFWords.snappedBaselines(weights)
        for baseline in weights.keys {
            #expect(mapping[baseline] == baseline,
                    "a real line at \(baseline) was pulled onto \(mapping[baseline] ?? -1)")
        }
    }

    /// A TIE IS A MERGE, NOT A SWAP. SUB-SUPE.TST page 2 draws one line as a 9pt lowered run
    /// and a 12pt one 0.74pt apart, 26 characters each: under a plain "heavier or equal" rule
    /// each chose the other and the pair came back as two lines in swapped order. Both have
    /// to land on the same baseline for a merge to be a merge.
    @Test func anEqualPairMergesRatherThanSwapping() {
        let weights = [683.3: 26, 684.0: 26, 660.0: 58, 672.0: 57, 696.0: 60, 708.0: 55]
        let mapping = AppPDFWords.snappedBaselines(weights)
        #expect(mapping[684.0] == 683.3, "got \(mapping[684.0] ?? -1)")
        #expect(mapping[683.3] == 683.3, "got \(mapping[683.3] ?? -1)")
    }

    /// A REDUCED RUN JOINS ITS LINE ON THE STRENGTH OF ITS SIZE ALONE, which is what a
    /// sup/sub run actually is. -README.WS's tag page is why weight cannot carry this: forty
    /// rows of "CLARIFY [Clarify]" make its TYPICAL line nine characters long, so seven
    /// characters against nine says nothing at all — while 12pt against 9pt says everything.
    @Test func smallerTypeJoinsTheFullSizeLineBesideIt() {
        let weights = [228.0: 7, 225.7: 9, 240.0: 7, 237.7: 7]
        let sizes = [228.0: 12.0, 225.7: 9.0, 240.0: 12.0, 237.7: 9.0]
        let mapping = AppPDFWords.snappedBaselines(weights, sizes: sizes)
        #expect(mapping[225.7] == 228.0, "got \(mapping[225.7] ?? -1)")
        #expect(mapping[228.0] == 228.0, "the full-size line moved, got \(mapping[228.0] ?? -1)")
    }

    /// AND ONE SIZE IS STILL WEIGHT'S QUESTION. MARKUP.WS's 2pt-lead page is all one size, so
    /// nothing on it may merge on size and the weight rules decide — as they already do.
    @Test func oneSizeLeavesTheDecisionToWeight() {
        let weights = [38.0: 50, 40.0: 50, 42.0: 49]
        let sizes = [38.0: 2.0, 40.0: 2.0, 42.0: 2.0]
        let mapping = AppPDFWords.snappedBaselines(weights, sizes: sizes)
        for baseline in weights.keys {
            #expect(mapping[baseline] == baseline,
                    "a 2pt-lead line at \(baseline) was pulled onto \(mapping[baseline] ?? -1)")
        }
    }

    /// AND THE WINDOW IS A WINDOW. A lone character a whole line away is its own line, not a
    /// marker: the rule may absorb a rise, never a lead.
    @Test func aDistantLoneCharacterKeepsItsOwnLine() {
        let mapping = AppPDFWords.snappedBaselines([100.0: 42, 108.0: 1])
        #expect(mapping[108.0] == 108.0,
                "a character 8pt away was snapped, which is past the window")
    }

    /// The engine's own side is unaffected by construction — every baseline it reports is a
    /// real line, so nothing is a minority near anything.
    @Test func aPageOfOrdinaryLinesIsUntouched() {
        let weights = [60.0: 30, 72.0: 28, 84.0: 31, 96.0: 27]
        let mapping = AppPDFWords.snappedBaselines(weights)
        for baseline in weights.keys {
            #expect(mapping[baseline] == baseline,
                    "ordinary line \(baseline) was snapped to \(mapping[baseline] ?? -1)")
        }
    }
}
