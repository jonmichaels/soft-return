import AppKit
import CoreText
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 434 (b27 items 1/9): Jon's b26 field review found "Four Yorkshiremen" (a WS4 doc, a
/// private document not in this repo — `OCAPTAIN.ws` is its in-repo stand-in) with its
/// title's ascenders clipped at the top in MODERN view, and LJ6DTP's shadow-title first line
/// still top-clipped in MODERN. `TitleAscenderTests` (this file's own sibling/precedent)
/// proved and fixed the SAME class of bug for Native/Printed (job 396/422) — but Native's own
/// `oversizedSelfPasses`/`leadingHeadroom` machinery (`DocumentRenderer.swift:903-1263`,
/// `PagedDocumentView.swift:37`) has no Modern counterpart at all:
/// `DocumentRenderer.renderModern` returned `oversizedSelfPasses: []`/`leadingHeadroom: []` as
/// literals before this job. No Modern title test existed anywhere in this repo before this
/// file, so nothing ever caught it.
///
/// ## Root cause
/// `modernParagraphStyle` makes a centered/verse paragraph "tight"
/// (`modernVerseTightLineHeightMultiple`, 0.71875) — a RELATIVE multiplier on AppKit's own
/// NATURAL line height. For an ordinary body-sized line this only tightens verse the way job
/// 395 intended; for an oversized title run inside a tight paragraph, the SAME compression
/// shrinks the line box below that font's own real ascender. Since this is the first
/// paragraph in Modern's one continuous flow, there is no earlier content for the excess
/// ascent to bleed into — it clips against the text container's own top edge.
///
/// ## Why the mechanism-level test measures CONTAINER-relative ink, not a flat page-margin
/// constant, and not fragment-LOCAL geometry either
/// Two naive checks both fail to catch this bug. (1) "measured pixel ink should land near the
/// 72pt margin" cannot tell a clipped render from a correctly-fitting one: a hard clip against
/// the container's own top edge pins the first VISIBLE pixel at exactly the container top —
/// the SAME reading a perfectly natural, unclipped line produces (confirmed empirically: both
/// LJ6DTP.WS and OCAPTAIN.ws measured pixel `topInk == 72.0` under the OLD, unfixed
/// `renderModern`). (2) A FRAGMENT-LOCAL geometry check (`NSLayoutManager.location
/// (forGlyphAt:)`'s own baseline-within-fragment offset vs. real ink) is blind to this job's
/// actual fix: `DocumentRenderer.modernLeadingSpacer` reserves room via a preceding invisible
/// SPACER PARAGRAPH, which moves the FRAGMENT's own absolute position within the container,
/// never the fragment-local baseline offset within it — a fragment-local-only probe kept
/// reporting the identical pre-fix deficit even after the real fix landed (confirmed
/// empirically while building this test — `paragraphSpacingBefore` on the affected paragraph
/// itself was tried FIRST and also failed, for a different reason: AppKit suppresses
/// `paragraphSpacingBefore` entirely for whichever paragraph is the very first one in a text
/// container, exactly the case that matters most here). The correct, CONTAINER-relative
/// ground truth `containerRelativeInkTop` below uses instead: real ink top = fragment's own
/// absolute origin (which DOES move with a preceding spacer paragraph) plus its fragment-local
/// baseline offset, minus real ink-above-baseline — literally "is the glyph's own top at or
/// below this container's local y=0," this job's own brief, phrased as geometry instead of a
/// pixel scan.
/// Job 535: every test in this suite reads `TestDocs/ws7` (`TitleAscenderTests.ws7Directory`)
/// — gated at the suite level so a bare stranger run skips all of it cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct ModernTitleAscenderTests {

    static var ws7Directory: URL { TitleAscenderTests.ws7Directory }

    enum ProbeError: Error { case noBitmap, noInk, noContent }

    /// The paper margin `DocumentRenderer.renderModern` places the text container at.
    static let modernMargin: Double = 72

    // MARK: - Mechanism-level law (fast, no view/pixel dependency)

    /// Lays `content` out ALONE, at `width`, in a fresh probe container whose local origin
    /// (0,0) stands in for the real text container's own top-left corner, and returns the
    /// real ink's top position in that CONTAINER-relative coordinate space — i.e. `fragment
    /// Rect.origin.y + baselineFromFragmentTop - inkAboveBaseline`, NOT the fragment-local
    /// `baselineFromFragmentTop - inkAboveBaseline` alone. The distinction matters: this
    /// job's own fix (`DocumentRenderer.modernLeadingSpacer`) reserves room via a preceding
    /// invisible SPACER PARAGRAPH, which shifts the FRAGMENT's own absolute position within
    /// the container (`lineFragmentRect.origin.y`) but leaves `NSLayoutManager.location
    /// (forGlyphAt:)`'s fragment-LOCAL baseline offset untouched — a fragment-local-only
    /// measurement is blind to the fix entirely (confirmed empirically while building this
    /// test: it kept reporting the SAME pre-fix deficit even after the production fix
    /// landed). A NEGATIVE result means the real ink wants to draw ABOVE this container's own
    /// top edge — i.e. it will clip.
    private static func containerRelativeInkTop(_ content: NSAttributedString, width: CGFloat) -> CGFloat? {
        guard content.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return nil }
        let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let baselineFromFragmentTop = layoutManager.location(forGlyphAt: glyphRange.location).y
        let baselineAbsolute = fragmentRect.origin.y + baselineFromFragmentTop
        let ctLine = CTLineCreateWithAttributedString(content)
        let bounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
        let inkAboveBaseline = bounds.origin.y + bounds.height
        return baselineAbsolute - inkAboveBaseline
    }

    /// The full law: render `fixture` for real (Modern style, `DocumentRenderer.render`, this
    /// job's fix included), find its first physical line, and require that line's real ink
    /// top sits AT OR BELOW this container's own local top edge (`containerRelativeInkTop >=
    /// -tolerance`) — literally "the rendered glyph top is inside the text container," this
    /// job's own brief. Renderer-level only (no `PagedDocumentView`, no screen), so it
    /// catches a regression in the DECISION independent of whatever the screen pipeline later
    /// does with it — the same class of coverage gap job 422's own history
    /// (`TitleAscenderTests.assertTitleRoutesThroughOversizedPass`) exists to close.
    @MainActor
    private static func assertFirstLineInsideContainer(fixture: String, tolerance: Double = 0.5) throws {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "ModernTitleAscenderTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        let rendered = DocumentRenderer.render(state, style: .modern)

        let full = rendered.text.string as NSString
        guard full.length > 0 else { throw ProbeError.noContent }
        let firstLineRange = full.lineRange(for: NSRange(location: 0, length: 0))
        let firstLine = rendered.text.attributedSubstring(from: firstLineRange)
        let width = rendered.textFrame.width

        guard let inkTop = Self.containerRelativeInkTop(firstLine, width: width)
        else { throw ProbeError.noInk }

        #expect(inkTop > -tolerance, """
            \(fixture)'s Modern first line's real ink top sits \(inkTop)pt from this text \
            container's own top edge (negative means ABOVE it) — a negative value beyond \
            \(tolerance)pt of float slop means the real glyph clips against the container's \
            own top edge, since there is no earlier content on this, the document's first \
            line, for the excess ascent to bleed into.
            """)
    }

    /// WS4 case (`OCAPTAIN.ws`, this repo's in-repo stand-in for the private "Four
    /// Yorkshiremen" fixture Jon's field review actually caught — see this file's own header).
    @Test @MainActor func ocaptainTitleInsideContainerInModern() throws {
        try Self.assertFirstLineInsideContainer(fixture: "OCAPTAIN.ws")
    }

    /// WS5+/shadow-title case: LJ6DTP.WS's own banner title, whose first line Jon's field
    /// review separately caught still clipped in Modern.
    @Test @MainActor func lj6dtpShadowTitleInsideContainerInModern() throws {
        try Self.assertFirstLineInsideContainer(fixture: "LJ6DTP.WS")
    }

    // MARK: - Real-pixel law (LJ6DTP only — its ~7pt deficit is large enough to be a
    // meaningful, non-antialiasing-noise pixel delta; OCAPTAIN's ~1.5pt deficit is real but
    // too small for a screen-capture margin scan to reliably resolve, the same class of gap
    // `TitleAscenderTests`' own job 422 history documents for a pixel-margin-only law).

    @MainActor
    private static func realPixelTopInk(fixture: String) throws -> Double {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "ModernTitleAscenderTests.pixel.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        state.style.setManually(.modern)

        let controller = DocumentWindowController(state: state)
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.showWindow(nil)
        controller.pagedView.showPage(0)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        guard let bitmap = controller.pagedView.bitmapImageRepForCachingDisplay(in: controller.pagedView.bounds)
        else { throw ProbeError.noBitmap }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            controller.pagedView.cacheDisplay(in: controller.pagedView.bounds, to: bitmap)
        }
        guard let margins = RenderProbeKit.inkMargins(
            in: bitmap, background: .white, viewSize: controller.pagedView.bounds.size)
        else { throw ProbeError.noInk }
        return margins.top
    }

    /// Real, on-screen proof (not just the renderer-level model) that LJ6DTP's shadow-title
    /// first line is no longer clipped: before this job's fix, the reserved room did not
    /// exist, so the real ink's top ~7.2pt of ascent drew above the text container's own top
    /// edge and the view's hard clip (`clipsToBounds`) cut it off — the visible ink's own top
    /// pixel landed AT the margin (72pt), same as a normal unclipped line would (this file's
    /// own header explains why that reading alone cannot distinguish clipped from fine).
    /// After the fix, the invisible spacer paragraph pushes the title paragraph's own fragment
    /// down by (deficit + 2)pt, so its real ink now draws ENTIRELY inside the container and
    /// the visible top pixel lands measurably BELOW the margin — measured ~73.5pt (margin +
    /// spacer height(9.2) − deficit(7.2) ≈ margin + 2), a clear, reproducible delta from the
    /// pre-fix 72.0pt reading (`> margin + 1` below leaves comfortable room on both sides).
    @Test @MainActor func lj6dtpShadowTitleNotClippedOnScreenInModern() throws {
        let topInk = try Self.realPixelTopInk(fixture: "LJ6DTP.WS")
        #expect(topInk > Self.modernMargin + 1, """
            LJ6DTP.WS's Modern first line ink should now draw measurably BELOW the \
            \(Self.modernMargin)pt margin (real ascent no longer clipped against the text \
            container's own top edge) — measured \(topInk)pt. A reading at/very near the \
            margin itself is the signature of the pre-fix hard clip, not a correctly-fitting \
            line (see this file's own header on why a bare "close to the margin" check cannot \
            tell the two apart).
            """)
    }
}
