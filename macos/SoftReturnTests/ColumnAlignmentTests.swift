import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 490 item 2 (Jon: "Make sure that all columns in tables line up. They're all over the
/// place right now" — confirmed against real WS7's `LJ6DTP-p3.png`: the reference has every
/// column dead-aligned, ours drifts). See `DocumentRenderer.appendProportionalRun`'s own doc
/// comment for the root cause and fix (a WordStar column-filler run — 2+ spaces, or 2+
/// dot-leader periods — re-stamped onto the document's own fixed Courier grid instead of
/// laying out at a proportional Mac font's own, per-row-varying natural advance).
@Suite struct ColumnAlignmentTests {
    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    // MARK: - Unit coverage of the splitter itself

    @Test @MainActor func plainProseSentenceIsNotSplit() {
        let segments = DocumentRenderer.splitOnColumnSpaceRuns("a quick brown fox")
        #expect(segments.count == 1)
        #expect(segments.first?.isGrid == false)
    }

    @Test @MainActor func twoOrMoreSpacesBecomeAGridSegment() {
        let segments = DocumentRenderer.splitOnColumnSpaceRuns("You type          Shows on screen as")
        #expect(segments.map(\.isGrid) == [false, true, false])
        #expect(segments[1].text == String(repeating: " ", count: 10))
    }

    @Test @MainActor func dotLeaderRunsBecomeAGridSegment() {
        let segments = DocumentRenderer.splitOnColumnSpaceRuns("Shading 85%................")
        #expect(segments.map(\.isGrid) == [false, true])
        #expect(segments[1].text == String(repeating: ".", count: 16))
    }

    /// The regression this job caught building the fix: a sentence-ending period followed
    /// by the typewriter convention's own two spaces (`". "` × 2, common throughout this
    /// proportional-font corpus) must NOT merge into one three-character leader — that
    /// visibly distorted ordinary prose punctuation (measured directly: the period itself
    /// landed at the Courier grid's width instead of its own proportional face's). The
    /// period stays its own un-grid-stamped one-character segment; only the two spaces AFTER
    /// it form their own, separate grid run.
    @Test @MainActor func periodFollowedByDoubleSpaceStaysTwoSeparateRuns() {
        let segments = DocumentRenderer.splitOnColumnSpaceRuns("colors.  For the LaserJet")
        #expect(segments.map(\.isGrid) == [false, true, false])
        #expect(segments[0].text == "colors.")
        #expect(segments[1].text == "  ")
        #expect(segments[2].text == "For the LaserJet")
    }

    @Test @MainActor func singleInterWordSpaceIsNeverGridStamped() {
        // MAC VIEWING RULING (job 240): ordinary single-space-separated prose must lay out
        // at each word's own natural advance — this is the boundary that rule protects.
        let segments = DocumentRenderer.splitOnColumnSpaceRuns("a b c")
        #expect(segments.allSatisfy { !$0.isGrid })
    }

    @Test @MainActor func mixedDotsAndTrailingSpacesFormOneLeaderPerHomogeneousRun() {
        // A dot leader followed directly by plain padding spaces before the next column's
        // real text (not this corpus's exact shape, but a plausible one) — two ADJACENT but
        // DIFFERENT-CHARACTER grid runs, not merged into one (each still re-stamps to the
        // grid on its own, so correctness doesn't depend on merging them).
        let segments = DocumentRenderer.splitOnColumnSpaceRuns("Label....  Value")
        #expect(segments.map(\.isGrid) == [false, true, true, false])
        #expect(segments[1].text == "....")
        #expect(segments[2].text == "  ")
    }

    // MARK: - End-to-end: real columns in the real fixture land at the same real X

    /// LJ6DTP.WS p5's "Color Mappings" chart draws each bar as a run of real block(219)
    /// glyphs (`\u{2588}`, `PrintedVectorGraphics.swift`'s own `fullBlockChar`) immediately
    /// after that row's own label + filler run — so the bar's own FIRST glyph is real,
    /// measurable text, not a picture. Two rows use a plain-space label ("Black", no dots);
    /// two use a dot-leader label ("Shading 85%....", "Shading 50%...."). All four are typed
    /// in the source to reach the SAME declared column — this measures that they now land at
    /// the same real on-screen X, across both filler conventions.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func lj6dtpColorMappingBarsAlignAcrossSpaceAndDotLeaderRows() throws {
        let url = Self.ws7Directory.appendingPathComponent("LJ6DTP.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "ColumnAlignmentTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.native)
        let rendered = DocumentRenderer.render(state, style: .printed)

        let storage = NSTextStorage(attributedString: rendered.text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: rendered.textFrame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        let text = rendered.text.string
        func barStartX(afterLabel label: String) throws -> CGFloat {
            let labelRange = try #require(text.range(of: label),
                                          "\"\(label)\" not found in the rendered Native text at all")
            let searchStart = labelRange.upperBound
            let barRange = try #require(text.range(of: "\u{2588}", range: searchStart..<text.endIndex),
                                        "no block(219) glyph found after \"\(label)\"")
            let nsRange = NSRange(barRange, in: text)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            return layoutManager.location(forGlyphAt: glyphRange.location).x
        }

        let blackX = try barStartX(afterLabel: "Black")
        let shading85X = try barStartX(afterLabel: "Shading 85%")
        let shading50X = try barStartX(afterLabel: "Shading 50%")
        let shading25X = try barStartX(afterLabel: "Shading 25%")

        // All four rows' bars must reach the SAME declared column, within a fraction of a
        // point (float glyph-advance summation noise only) — not the tens-of-points drift
        // measured before this fix (`outbox/job490/evidence/before/lj6dtp-p5-native.png`).
        #expect(abs(blackX - shading85X) < 1.0,
                "'Black' (plain-space row) bar at \(blackX) vs 'Shading 85%' (dot-leader row) bar at \(shading85X)")
        #expect(abs(shading25X - shading50X) < 1.0,
                "'Shading 25%' (plain-space row) bar at \(shading25X) vs 'Shading 50%' (dot-leader row) bar at \(shading50X)")
        #expect(abs(blackX - shading25X) < 1.0,
                "'Black' bar at \(blackX) vs 'Shading 25%' bar at \(shading25X) — both plain-space rows")
    }
}
