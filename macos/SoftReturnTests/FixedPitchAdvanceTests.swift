import AppKit
import CoreText
import CtrlKD
import Testing
@testable import SoftReturn

/// A Native line advances on the LIBRARY's grid, not on the substituted face's own.
///
/// Native draws the document's Courier with the bundled Courier Prime
/// (`CourierPrimeFontRegistration`). That face's own advance is 1228/2048 em = 0.599609375,
/// not the 0.6 em Courier is built on and the engine's column grid assumes — so left
/// uncorrected, every character lands 0.0046875pt short at a 12pt type size and the error
/// accumulates along the line. It was invisible near the left margin and worth a quarter of a
/// point by column 50, which is exactly where the Native gate's named rows sat.
///
/// This suite is the mechanism's own gate, separate from `AppNativeFidelityTests`, which can
/// only run against the private captures. Everything here is measurable on any machine.
@Suite struct FixedPitchAdvanceTests {

    /// The substitution really is short. If this ever stops being true — a different bundled
    /// face, or an upstream Courier Prime that re-metrics to 0.6 em — the correction below
    /// becomes a no-op and the reader should be told why rather than left with a test that
    /// silently proves nothing.
    @Test @MainActor func theSubstitutedFaceIsNarrowerThanTheLibrarysGrid() throws {
        let font = try #require(NSFont(name: "Courier Prime", size: 12),
                                "Courier Prime must be registered for Native rendering")
        var characters: [UniChar] = Array("0".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        try #require(CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count),
                     "the face must have a glyph for \"0\"")
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyphs, &advance, 1)

        // The library's own pitch for a 12pt fixed-pitch run, from the emitter's own
        // function rather than a constant written down here.
        // Compared with a tolerance, not `== 7.2`: `spanPitch`'s fontless branch is
        // `Double(pt) * 0.6`, and 12 * 0.6 is 7.199999999999999 in binary64. The engine's own
        // `spanTarget` comment documents that exact hazard — asserting exact equality here
        // was this test failing on arithmetic rather than on the thing it measures.
        let pitch = spanPitch(nil, 12)
        #expect(abs(pitch - 7.2) < 1e-9, "the library's 12pt pitch must be 7.2pt, got \(pitch)")

        let natural = Double(advance.width)
        let deficit = pitch - natural
        #expect(deficit > 0, """
            Courier Prime at 12pt advances \(natural)pt against the library's \(pitch)pt. If \
            this is no longer short, the fixed-pitch correction has nothing to correct and \
            this suite's remaining tests are measuring nothing
            """)
        // Named so the number is in the record rather than only in a commit message.
        #expect(abs(deficit - 0.0046875) < 1e-9,
                "expected a deficit of 0.0046875pt per character at 12pt, measured \(deficit)")
    }

    /// THE FIX, measured where it matters: at the far end of a long line.
    ///
    /// A run of 70 fixed-pitch characters must occupy exactly 70 library columns. 70 is not
    /// arbitrary — it is column 70, x=504pt, where the Native gate's worst named rows sat.
    @Test @MainActor func aLongFixedPitchRunLandsOnTheLibrarysColumn() throws {
        let font = try #require(NSFont(name: "Courier Prime", size: 12))
        let paragraph = NSParagraphStyle()
        let text = String(repeating: "n", count: 70)
        let line = DocumentRenderer.attributedLine(
            [Span(text: text, styles: [], font: nil, colour: nil, pctlHMI: nil)],
            font: font, paragraph: paragraph, fonts: [], defaultSize: 12,
            disableKerning: true, useCourierPrime: true)

        // Measured through a real layout manager, never `NSAttributedString.size()` — this
        // renderer already records that legacy string drawing disagrees with what TextKit
        // actually lays out, and a correction to layout has to be checked against layout.
        let storage = NSTextStorage(attributedString: line)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 10_000, height: 10_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        let glyphs = manager.glyphRange(for: container)
        try #require(glyphs.length >= 70, "expected 70 laid-out glyphs, got \(glyphs.length)")
        // Where the pen sits after 70 characters: the origin of the glyph that would follow.
        let end = manager.location(forGlyphAt: glyphs.location + 69).x
            + CGFloat(spanPitch(nil, 12))
        let wanted = CGFloat(spanPitch(nil, 12)) * 70

        #expect(abs(end - wanted) < 0.01, """
            70 fixed-pitch characters occupy \(end)pt; the library's grid puts column 70 at \
            \(wanted)pt — off by \(end - wanted)pt. Uncorrected, the substituted face lands \
            this run about 0.33pt short
            """)
    }

    /// The correction must not touch a PROPORTIONAL run. There is no per-character grid for
    /// one to land on — the engine advances it by its own widths — so a run in a substituted
    /// proportional face keeps that face's natural advances, exactly as before.
    @Test @MainActor func aProportionalRunKeepsItsOwnAdvances() throws {
        let candidate = NSFont(name: "Times New Roman", size: 12) ?? NSFont(name: "Times-Roman", size: 12)
        let proportional = try #require(candidate, "a proportional face must be available")
        try #require(!proportional.isFixedPitch, "the control face must be proportional")

        let text = "The quick brown fox jumps over the lazy dog"
        let plain = NSAttributedString(string: text, attributes: [.font: proportional])
        let line = DocumentRenderer.attributedLine(
            [Span(text: text, styles: [], font: nil, colour: nil, pctlHMI: nil)],
            font: proportional, paragraph: NSParagraphStyle(), fonts: [], defaultSize: 12,
            disableKerning: true, useCourierPrime: false)

        let kern = line.attribute(.kern, at: 0, effectiveRange: nil) as? Float
        let reported: String = kern.map { "\($0)" } ?? "none"
        let message = "a proportional run must carry no advance correction (kern 0), got "
            + "\(reported) — correcting one toward a per-character pitch would be wrong, "
            + "not merely unnecessary"
        #expect(kern == 0, "\(message)")
        // And the run still measures as the face itself does.
        #expect(abs(line.size().width - plain.size().width) < 0.01,
                "the proportional run's width must be unchanged by the fixed-pitch correction")
    }
}
