import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// THE PESETA IS A GLYPH IN NATIVE, NOT A DRAWING.
///
/// Planning #266 put U+20A7 PESETA SIGN (cp437 code 158) on the engine's `symbolShapes`, and
/// therefore into `CtrlKD.graphicChars`, for the reason that table exists: no base-14 face
/// carries the character and cp1252 has no slot for it, so the engine's text path could only
/// ever degrade it to `?`. Drawing it is the honest answer THERE.
///
/// Native is not there. It sets real Mac faces — job 240's MAC VIEWING RULING, "we don't have
/// to fool around with making sure we only use native-to-PDF fonts" — and a Mac face has a
/// real peseta. So Native draws the glyph, and `nativeGeometryChars` is where that is said
/// once for the whole renderer.
///
/// The witness is `REF/ASCIITAB.WS`, whose own driver field reads `PRINTER`: not one of
/// `euroPatchedDrivers`, so its code 158 still MEANS a peseta (`pesetaMeansEuro` is false for
/// it) and survives the semantic flow as U+20A7 rather than becoming a euro. A document
/// printed through LASERJET, LJ6DTP or HP4 never reaches this question at all — the flow has
/// already turned its code 158 into U+20AC.
@Suite(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct NativePesetaGlyphTests {

    /// THE RULE, stated against both sets so neither can drift without this failing: the
    /// engine draws the peseta, Native does not, and Native draws everything else the engine
    /// draws.
    @Test func nativeDrawsEveryEngineGraphicExceptThePeseta() {
        #expect(CtrlKD.graphicChars.contains("\u{20A7}"),
                "planning #266 put the peseta on the engine's own graphic table; if it left, this rule has no subject")
        #expect(!nativeGeometryChars.contains("\u{20A7}"),
                "Native must draw the peseta as a real glyph, not as a vector cell")
        #expect(nativeGeometryChars == CtrlKD.graphicChars.subtracting(["\u{20A7}"]),
                "Native's geometry set must differ from the engine's by the peseta and nothing else")
        // A real member of the engine's set is still Native's: a box-drawing rule has no
        // glyph worth drawing with, in any face, and stays geometry.
        #expect(nativeGeometryChars.contains("\u{2550}"))
    }

    /// AND IT REACHES THE PAGE. The character survives into the Native render's own text as
    /// U+20A7 — not dropped, not a `?`, not consumed by the graphic-cell walk — on a document
    /// that also carries real box-drawing characters, so one render witnesses both halves.
    @Test @MainActor func asciitabsNativeRenderCarriesThePesetaAsText() throws {
        let root = try #require(PrivateCorpusSupport.sawyerArchiveRoot,
                                "the sawyer archive is what holds REF/ASCIITAB.WS")
        let url = root.appendingPathComponent("REF/ASCIITAB.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "NativePeseta.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults),
                                       docPath: url.path)
        #expect(!pesetaMeansEuro(state.document),
                "ASCIITAB's driver field is PRINTER, so its code 158 must still mean a peseta")
        let rendered = DocumentRenderer.render(state, style: .native)
        let text = rendered.text.string
        #expect(text.contains("\u{20A7}"),
                "the peseta is missing from Native's own text — it is being drawn, degraded or dropped")
        #expect(text.contains(where: { nativeGeometryChars.contains($0) }),
                "this fixture should also carry real geometry characters, or it witnesses only half the rule")
    }
}
