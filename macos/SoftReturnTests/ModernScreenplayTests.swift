import AppKit
import CoreText
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// b27 item 11: SCRIPT.WS's Modern view violated Jon's screenplay ruling — the page-number
/// marker rendered left-aligned instead of flush against the right margin, and a slugline's
/// own right-hand scene number word-wrapped onto its own (left-anchored) line instead of
/// holding the right margin on the SAME line as the slugline. Native/Printed already pass
/// this (ordinary fixed-pitch/overprint fidelity gets it for free — see
/// `NativeVsEngineGeometryTests`'s own SCRIPT.WS pages 10/11 tier and `OracleByteParityTests`'
/// Tier-1 SCRIPT.WS byte parity); Modern had no dedicated mechanism at all
/// (`ModernScreenplay.swift`'s own header has the full rule and the reason this is a PORT,
/// not a call into ctrl-kd's own internal-to-its-module detector).
///
/// These are MECHANISM-level (renderer, not screen/pixel) laws, same technique
/// `ModernTitleAscenderTests` (job 434, the architectural precedent this job's brief names)
/// already established: lay the REAL rendered `DocumentRenderer.render(_:style:.modern)`
/// output out with a real `NSLayoutManager` at the real measure width, and assert real,
/// numeric glyph positions — not just that some glyph is present somewhere.
/// Job 535: every test in this suite reads `TestDocs/ws7` (`FontsInViewsTests.ws7Directory`)
/// — gated at the suite level so a bare stranger run skips all of it cleanly.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct ModernScreenplayTests {

    static var ws7Directory: URL { FontsInViewsTests.ws7Directory }

    enum ProbeError: Error { case noContent, notFound, wrongLineCount }

    @MainActor
    private static func documentState(fixture: String) throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "ModernScreenplayTests.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    /// One line fragment's glyphs, laid out for real at `width` — same probe shape
    /// `ModernTitleAscenderTests.containerRelativeInkTop` already uses (a fresh
    /// `NSLayoutManager`/`NSTextContainer` pair standing in for the real text container).
    private struct LaidOutLine {
        // `storage` is never read again after construction, but MUST stay alive as long as
        // `layoutManager` does: `NSTextStorage` owns its layout managers, not the reverse,
        // so a `storage` local that goes out of scope after `layOut` returns gets
        // deallocated by ARC, leaving `layoutManager` backed by nothing — every query made
        // on it AFTER that (this struct's whole reason to exist) silently returns empty
        // results instead of throwing, which is what made this probe's first version look
        // like "no fragment ever matches" instead of the real, ordinary ownership bug it was.
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        let glyphRange: NSRange
    }

    private static func layOut(_ content: NSAttributedString, width: CGFloat) -> LaidOutLine {
        let storage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return LaidOutLine(storage: storage, layoutManager: layoutManager, container: container,
                            glyphRange: layoutManager.glyphRange(for: container))
    }

    /// The x-position (container-relative points) of the glyph at character `charIndex`
    /// within `content`, laid out alone at `width` — and which zero-based LINE FRAGMENT
    /// (0 = first) it landed on, so a caller can tell "wrapped onto its own line" apart from
    /// "same line, just far right."
    private static func glyphPosition(
        in content: NSAttributedString, charIndex: Int, width: CGFloat
    ) -> (x: Double, fragmentIndex: Int)? {
        let laid = Self.layOut(content, width: width)
        guard laid.glyphRange.length > 0, charIndex >= 0, charIndex < content.length else { return nil }
        let glyphIndex = laid.layoutManager.glyphIndexForCharacter(at: charIndex)
        guard glyphIndex != NSNotFound else { return nil }
        var fragmentIndex = -1
        var matchedFragmentIndex = -1
        var fragmentOrigin: CGPoint = .zero
        laid.layoutManager.enumerateLineFragments(forGlyphRange: laid.glyphRange) { rect, _, _, effectiveRange, stop in
            fragmentIndex += 1
            if NSLocationInRange(glyphIndex, effectiveRange) {
                fragmentOrigin = rect.origin
                matchedFragmentIndex = fragmentIndex
                stop.pointee = true
            }
        }
        guard matchedFragmentIndex >= 0 else { return nil }
        let localX = laid.layoutManager.location(forGlyphAt: glyphIndex).x
        return (Double(fragmentOrigin.x + localX), matchedFragmentIndex)
    }

    // MARK: - Rule (b): the page-number marker holds the right margin

    /// SCRIPT.WS's own Figure 2 transcript embeds a bare "1." page-number marker paragraph
    /// (WordStar body text, not a dot command) immediately before its first scene's slugline
    /// — `matchesScreenplayPageMarker`'s own exact subject. Before this job's fix the
    /// paragraph rendered at the document's default LEFT alignment; after, `renderModern`
    /// detects it (`ModernScreenplay.matchesPageMarker`, gated on
    /// `ModernScreenplay.detectBlocks`/`markerCandidateBlocks`) and right-aligns it.
    @Test @MainActor func pageNumberMarkerHoldsRightMarginInModern() throws {
        let state = try Self.documentState(fixture: "SCRIPT.WS")
        let rendered = DocumentRenderer.render(state, style: .modern)
        let haystack = rendered.text.string as NSString
        guard haystack.length > 0 else { throw ProbeError.noContent }

        // The marker paragraph is the WHOLE-PARAGRAPH bare "1." immediately before "INT.
        // WRITER'S OFFICE - DAY" — locate it by anchoring on the slugline (a unique needle
        // in this fixture, `FontsInViewsTests`' own citation) and walking BACK to the start
        // of its own preceding paragraph.
        // SCRIPT.WS's own text names this slugline TWICE — once in Figure 1's raw
        // (unexpanded, WordStar merge-var math is never evaluated by this parser)
        // `&n/s& INT. WRITER'S OFFICE - DAY` shorthand listing, and once in Figure 2's own
        // literal prose transcript of the printed result, `1     INT. WRITER'S OFFICE -
        // DAY`. Only the SECOND is a genuine screenplay slugline+scene-number pair (Figure
        // 1's line has no trailing digit at all) — anchoring on the leading digit+spacing
        // picks it out uniquely.
        let sluglineNeedle = "1     INT. WRITER'S OFFICE - DAY"
        let sluglineRange = haystack.range(of: sluglineNeedle)
        #expect(sluglineRange.location != NSNotFound, "slugline needle not found in Modern text")
        guard sluglineRange.location != NSNotFound else { return }

        let beforeSlugline = haystack.substring(to: sluglineRange.location) as NSString
        // Walk backward through paragraphs (a blank line/paragraph sits between the marker
        // and the slugline in the real render) to the nearest NON-blank one.
        var cursor = beforeSlugline.length
        var markerLineRange = NSRange(location: 0, length: 0)
        var markerParagraph = ""
        while cursor > 0 {
            markerLineRange = beforeSlugline.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
            markerParagraph = beforeSlugline.substring(with: markerLineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !markerParagraph.isEmpty { break }
            cursor = markerLineRange.location
        }
        #expect(markerParagraph == "1.", """
            expected the paragraph immediately before the slugline to be the bare page-number \
            marker "1." — found "\(markerParagraph)" instead; the fixture's own shape may have \
            moved.
            """)

        // Real position: right-align means the marker's own glyph ("1", the digit) lands
        // near the right edge of the container, not at x≈0.
        let digitRange = markerLineRange.location + markerLineRange.length > 0
            ? beforeSlugline.range(of: "1", options: .backwards, range: markerLineRange)
            : NSRange(location: NSNotFound, length: 0)
        #expect(digitRange.location != NSNotFound)
        guard digitRange.location != NSNotFound else { return }

        let markerLine = rendered.text.attributedSubstring(
            from: NSRange(location: markerLineRange.location, length: markerLineRange.length))
        let width = rendered.textFrame.width
        let localDigitIndex = digitRange.location - markerLineRange.location
        guard let pos = Self.glyphPosition(in: markerLine, charIndex: localDigitIndex, width: width)
        else { throw ProbeError.notFound }

        // Right-aligned means the digit's own glyph sits within the LAST 15% of the
        // measure, whichever line fragment it landed on (a right-aligned paragraph applies
        // per-fragment, so even a wrapped leading-space run doesn't change this).
        let threshold = Double(width) * 0.85
        #expect(pos.x > threshold, """
            page-number marker "1." digit x=\(pos.x)pt, container width \(width)pt — expected \
            it within the right-hand 15% of the measure (x > \(threshold)pt) for a \
            right-aligned screenplay page marker; a left-aligned rendering lands it near x=0.
            """)
    }

    // MARK: - Rule (c): a slugline's trailing scene number never wraps off the margin

    /// The scene number after "DAY" (the slugline's own right-hand repeat, real screenplay
    /// convention) must land on the SAME line fragment as "DAY" and near the right edge —
    /// not wrapped onto its own line at the left, which is what Modern's ordinary word-wrap
    /// did to the huge WordStar-overprint padding before this job's fix
    /// (`ModernScreenplay.collapseSceneNumberGap`).
    @Test @MainActor func slugLineTrailingSceneNumberHoldsRightMarginInModern() throws {
        let state = try Self.documentState(fixture: "SCRIPT.WS")
        let rendered = DocumentRenderer.render(state, style: .modern)
        let haystack = rendered.text.string as NSString
        guard haystack.length > 0 else { throw ProbeError.noContent }

        // SCRIPT.WS's own text names this slugline TWICE — once in Figure 1's raw
        // (unexpanded, WordStar merge-var math is never evaluated by this parser)
        // `&n/s& INT. WRITER'S OFFICE - DAY` shorthand listing, and once in Figure 2's own
        // literal prose transcript of the printed result, `1     INT. WRITER'S OFFICE -
        // DAY`. Only the SECOND is a genuine screenplay slugline+scene-number pair (Figure
        // 1's line has no trailing digit at all) — anchoring on the leading digit+spacing
        // picks it out uniquely.
        let sluglineNeedle = "1     INT. WRITER'S OFFICE - DAY"
        let sluglineRange = haystack.range(of: sluglineNeedle)
        #expect(sluglineRange.location != NSNotFound)
        guard sluglineRange.location != NSNotFound else { return }

        let paragraphRange = haystack.paragraphRange(for: sluglineRange)
        let paragraphText = haystack.substring(with: paragraphRange)
        // The trailing scene number is the last run of 1-4 digits in the paragraph,
        // preceded by whitespace (`matchesScreenplayTrailingSceneNumber`'s own shape) —
        // find it the same way, on the RENDERED text (post-fix this is "...DAY\t1", one tab
        // then the digit).
        var end = paragraphText.count
        let chars = Array(paragraphText)
        while end > 0, chars[end - 1] == " " || chars[end - 1] == "\t" || chars[end - 1] == "\n" { end -= 1 }
        var start = end
        while start > 0, chars[start - 1].isASCII, chars[start - 1].isNumber { start -= 1 }
        #expect(end - start >= 1, "no trailing scene number found in slugline paragraph \"\(paragraphText)\"")
        guard end - start >= 1, start > 0 else { return }

        let sluglineParagraphAttr = rendered.text.attributedSubstring(from: paragraphRange)
        let width = rendered.textFrame.width
        guard let numberPos = Self.glyphPosition(in: sluglineParagraphAttr, charIndex: start, width: width)
        else { throw ProbeError.notFound }
        guard let dayPos = Self.glyphPosition(
            in: sluglineParagraphAttr,
            charIndex: (paragraphText as NSString).range(of: "DAY").location,
            width: width)
        else { throw ProbeError.notFound }

        #expect(numberPos.fragmentIndex == dayPos.fragmentIndex, """
            trailing scene number landed on line fragment \(numberPos.fragmentIndex) but \
            "DAY" (the slugline's own text) is on fragment \(dayPos.fragmentIndex) — the \
            number wrapped onto its own line instead of holding the slugline's own right \
            margin.
            """)
        let threshold = Double(width) * 0.85
        #expect(numberPos.x > threshold, """
            trailing scene number x=\(numberPos.x)pt, container width \(width)pt — expected \
            it within the right-hand 15% of the measure (x > \(threshold)pt); a wrapped or \
            left-anchored rendering lands it far short of that.
            """)
    }
}
