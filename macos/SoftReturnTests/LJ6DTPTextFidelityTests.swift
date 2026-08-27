import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 226 probe: `DocumentRenderer.attributedLine` built directly against real `Span`/
/// `FontChange` values (same technique `UIRound4ARulingTests`/`PixelTruthMarginTests` already
/// use), isolating the LJ6DTP character-substitution/PDF-encoding-fidelity port from the rest
/// of the pixel-oracle pipeline.
@Suite struct LJ6DTPTextFidelityTests {
    @Test @MainActor func driverSubstitutionAppliesOnProportionalRuns() throws {
        let font = NSFont(name: "Times-Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        let proportional = FontChange(offset: 0, width1800: 900, height1440: 240, typestyle: 0x8000)
        let colourMap: [Int: Double] = [15: 1.0]   // any non-empty map is the LJ6DTP gate

        let line = DocumentRenderer.attributedLine(
            [Span(text: "Copyright \u{263B} 1990", font: 0)],
            font: font, paragraph: paragraph, fonts: [proportional], defaultSize: 12,
            colourMap: colourMap)

        #expect(line.string == "Copyright \u{00A9} 1990",
                "expected LJ6DTP's ☻->© driver substitution, got: \(line.string)")
    }

    /// Job 240 (b13, Part 1) RENAMED and RE-ASSERTED — MAC VIEWING RULING (decision register
    /// 2026-08-11; skill registry #25): the cp1252 esc-degradation this test used to assert
    /// (`printedEscFallback`/`printedEscDegrade`) is REMOVED from this native path. That
    /// degradation existed only because `emitPDF` hand-encodes Printed-mode text as a
    /// `/WinAnsiEncoding` PDF string literal, which has no slot for the raised bullet — a
    /// PDF-EXPORT constraint this native viewer no longer inherits: every Mac face
    /// `printedMacFontName` now resolves carries `∙` natively. The character now passes
    /// through UNCHANGED, the opposite of this test's old assertion.
    @Test @MainActor func escDegradationNoLongerAppliesNatively() throws {
        let font = NSFont(name: "Times-Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()

        let line = DocumentRenderer.attributedLine(
            [Span(text: "PDF \u{2219} 2")], font: font, paragraph: paragraph)

        #expect(line.string == "PDF \u{2219} 2",
                "expected the raised-bullet character to pass through unchanged (no cp1252 esc degradation on the native path), got: \(line.string)")
    }
}
