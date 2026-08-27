import AppKit
import Testing
@testable import CtrlKD
@testable import SoftReturn

/// b27 item 3 — the cp437 0xFE square bullet (■, U+25A0, Sawyer's `-README.WS` list
/// markers) rendered visibly RECTANGULAR in Native while Printed (the real engine PDF)
/// was already correct. Root cause: `PrintedVectorGraphics.swift`'s `partBlocks`/
/// `graphicCells` — the app's OWN AppKit port of the engine's vector-graphics geometry —
/// never received half of engine commit 9a4dff2 (b24 round 20, slate item 8): the
/// re-derived TRUE-square ■ fractions (0.175, 0.175, 0.65, 0.65) landed, but the
/// `squarePartBlocks` cell-center/`sq = min(pitch, cellHeight)` scaling branch that makes
/// those fractions actually produce a square did not — so ■ kept stretching to the cell's
/// pitch (x) and height (y) independently, same defect shape as the old (0.12, 0.18, 0.72,
/// 0.55) fractions, just with different numbers.
///
/// Two views, two independent proofs (per this round's evidence law — a fix claim covering
/// more than one view needs a test PER view, not "should also cover"):
/// - NATIVE: `PrintedVectorGraphics.swift`'s own port, exercised via `graphicCells` exactly
///   like `PrintedStructuralParityTests`' existing `symbolShapesProduceRealGeometryNotAPlaceholder`.
/// - PRINTED: the real engine (`CtrlKD.graphicOps`) — a SEPARATE code path this job never
///   touches. Already correct as of the currently-vendored engine pin (commit 9a4dff2 is an
///   ancestor of the app's pinned `45b972663b2bae763e0d4751f93b1ae7e734c668`, confirmed via
///   `git merge-base --is-ancestor` against the engine checkout). This test has no
///   before/after delta from this job's own commit — it passed before this job touched
///   anything and continues to pass after, proving Printed was never broken and this job
///   did not regress it. Recorded honestly as a confirmation, not fabricated as a
///   fail-before/pass-after pair.
@Suite struct SquareBulletPortTests {

    // MARK: - Fractions match the engine's, on both sides of the port

    @Test func appPartBlockFractionsMatchEngineForSquareBullet() throws {
        let appFrac = try #require(SoftReturn.partBlocks["\u{25A0}"],
                                    "app's partBlocks has no U+25A0 entry")
        let engineFrac = try #require(CtrlKD.partBlocks["\u{25A0}"],
                                       "engine's partBlocks has no U+25A0 entry")
        #expect(appFrac.x == engineFrac.x)
        #expect(appFrac.y == engineFrac.y)
        #expect(appFrac.w == engineFrac.w)
        #expect(appFrac.h == engineFrac.h)
        #expect(appFrac.w == appFrac.h,
                "■'s own fraction pair isn't square: w=\(appFrac.w) h=\(appFrac.h)")
        #expect(SoftReturn.squarePartBlocks.contains("\u{25A0}"),
                "app's squarePartBlocks is missing U+25A0 — the scaling branch this job ports won't fire")
        #expect(CtrlKD.squarePartBlocks.contains("\u{25A0}"))
    }

    // MARK: - NATIVE: the app's own AppKit vector-graphics port

    /// Fails before this job's fix: the old code scaled ■'s fractions by `pitch` (x) and
    /// `cellHeight` (y) independently, which are NOT equal on a real Courier cell
    /// (12pt Courier: pitch ~7.2pt, cellHeight 1.1*12 = 13.2pt) — a taller-than-wide rect,
    /// not a square, regardless of which fraction pair is in the table.
    @Test @MainActor func nativeSquareBulletRendersSquareInIsolatedLayout() throws {
        let font = NSFont(name: "Courier", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = NSAttributedString(string: "\u{25A0}", attributes: attrs)
        let isolated = try #require(isolatedLineLayout(text, width: 100), "no isolated layout produced")
        let cells = graphicCells(manager: isolated.manager, storage: isolated.storage,
                                  glyphRange: isolated.glyphRange, fragment: isolated.fragmentRect)
        let cell = try #require(cells.first, "■ produced no GraphicCell at all")
        let fill = try #require(cell.fills.first, "■ produced no fill")
        #expect(cell.fills.count == 1, "■ should produce exactly one fill, got \(cell.fills.count)")
        guard case .rect(let r) = fill.shape else {
            Issue.record("■ produced a non-rect fill shape: \(fill.shape)")
            return
        }
        #expect(r.width > 0 && r.height > 0, "■ fill has zero area: \(r)")
        #expect(abs(r.width - r.height) < 0.01,
                "■ fill is not square: \(r.width)pt wide x \(r.height)pt tall")
    }

    /// Same law, real fixture: `-README.WS` (Sawyer's list markers, WP0's `TestDocs/ws7`
    /// fixture) is where Jon actually saw this. Renders the Native (`.native` view style —
    /// `DocumentRenderer.renderPrinted`) layout for the document's own text and finds at
    /// least one real ■ fill, asserting it too is square — proof the law above isn't an
    /// artifact of the synthetic single-character isolation.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func nativeSquareBulletRendersSquareInReadmeFixture() throws {
        let url = OracleByteParityTests.ws7Directory.appendingPathComponent("-README.WS")
        let state = try Oracle.state(for: url)
        // `Oracle.layOut` builds the SAME multi-container-per-page `PagedDocumentView`
        // the real app uses (`buildPages`) — a single fixed-height `NSTextContainer`
        // (tried first) silently truncates layout past page 1, since AppKit has nowhere
        // to flow the overflow without a second container to hand it to.
        let (_, _, pages) = Oracle.layOut(state)

        var squareFills: [CGRect] = []
        for page in pages {
            let text = page.textView.string as NSString
            page.manager.enumerateLineFragments(forGlyphRange: page.glyphs) { fragRect, _, _, glyphRange, _ in
                for g in glyphRange.location..<(glyphRange.location + glyphRange.length) {
                    let charIndex = page.manager.characterIndexForGlyph(at: g)
                    guard charIndex < text.length, text.character(at: charIndex) == 0x25A0 else { continue }
                    guard let storage = page.textView.textStorage else { continue }
                    let cells = graphicCells(manager: page.manager, storage: storage,
                                              glyphRange: NSRange(location: g, length: 1), fragment: fragRect)
                    for cell in cells {
                        for fill in cell.fills {
                            if case .rect(let r) = fill.shape { squareFills.append(r) }
                        }
                    }
                }
            }
        }
        #expect(!squareFills.isEmpty, "-README.WS produced no ■ fills at all — fixture no longer contains U+25A0?")
        for r in squareFills {
            #expect(abs(r.width - r.height) < 0.01,
                    "-README.WS ■ fill is not square: \(r.width)pt wide x \(r.height)pt tall")
        }
    }

    // MARK: - PRINTED: the real engine PDF (confirmation, not a before/after delta)

    /// `CtrlKD.graphicOps` is a SEPARATE implementation from the app's own port above (the
    /// engine's real PDF operator emitter) — this job never touches it. Confirms it already
    /// produces a square ■ fill, on a deliberately asymmetric pitch/pt pair (pitch 7.2 !=
    /// cellHeight 1.1*12=13.2) so a non-square result could not hide behind pitch == height.
    @Test func printedSquareBulletFillIsSquareInRealEngineOps() throws {
        let pitch = 7.2
        let pt = 12
        let ops = CtrlKD.graphicOps("\u{25A0}", x: 0, y: 100, pitch: pitch, pt: pt)
        let rectOps = ops.compactMap { op -> (x: Double, y: Double, w: Double, h: Double)? in
            let line = String(decoding: op, as: UTF8.self)
            let tokens = line.split(separator: " ")
            guard tokens.count == 6, tokens[4] == "re", tokens[5] == "f",
                  let x = Double(tokens[0]), let y = Double(tokens[1]),
                  let w = Double(tokens[2]), let h = Double(tokens[3])
            else { return nil }
            return (x, y, w, h)
        }
        let rect = try #require(rectOps.first, "■ produced no `re f` rect op at all")
        #expect(rectOps.count == 1, "■ should produce exactly one rect fill, got \(rectOps.count)")
        #expect(rect.w > 0 && rect.h > 0, "■ fill has zero area: \(rect)")
        #expect(abs(rect.w - rect.h) < 0.01,
                "■ fill is not square in the real engine PDF: \(rect.w)pt wide x \(rect.h)pt tall")
    }
}
