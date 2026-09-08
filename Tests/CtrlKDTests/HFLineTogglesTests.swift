import Testing
@testable import CtrlKD

/// Mechanism M (ctrl-kd 74acc60, residuals round 2026-09-06): a fontless `.h#`/`.f#` line's
/// own inline style toggle (e.g. WordStar's `^Y` italic) used to leak into the Printed PDF
/// as a literal control byte instead of being interpreted -- `AFM.swift`'s Courier table
/// gives EVERY byte value a full 7.2pt advance, so the phantom glyph shifted every word
/// after it on the header line. Real, broad-support engine bug (any fontless header/footer
/// with an inline toggle). Direct port of ctrl-kd's
/// `test_hf_line_toggle_bytes_never_reach_the_pdf_as_literal_control_chars` and
/// `test_hf_line_with_no_toggle_bytes_is_unaffected_by_mechanism_l` (Python names it
/// "mechanism L" in that test file's own comment, but ctrl-kd's commit message and
/// `pdf.py`'s own doc comment name the `_hf_line_ops` fix mechanism M -- the commit
/// message is authoritative; this file follows it).

private let hfItalic: [UInt8] = [0x19]   // hfToggles[0x19] == .italic

/// Mirrors ctrl-kd's `_headed_doc` test helper: a real WS7-shaped document (header byte
/// 0x70) with a `.h1` running head and one body paragraph.
private func headedDoc(h1: [UInt8] = bytes("Sawyer / Old Times / #")) -> Document {
    parseWS(ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
        + bytes(".h1 ") + h1 + HARD
        + bytes("Body text of the document, long enough to paginate sensibly.") + HARD)
}

@Test func hfLineToggleBytesNeverReachThePDFAsLiteralControlChars() throws {
    let doc = headedDoc(h1: hfItalic + bytes("WordStar 7.0 Archive / #") + hfItalic)
    let out = emitPDF(doc, mode: .printed)
    #expect(!contains(out, hfItalic))

    let spans = contentSpans(out)
    let span = try #require(spans.first { $0.text == "WordStar 7.0 Archive / 1" })
    #expect(span.x == 57.6)     // this doc's own left margin -- no phantom glyph ahead of it

    // italic (hfToggles[0x19] == .italic) resolves to Courier's own oblique variant, not a
    // hardcoded plain Courier -- the toggle really was read, not merely stripped.
    let fonts = baseFonts(out)
    #expect(fonts[span.font] == "Courier-Oblique")
}

/// The overwhelmingly common case (a plain `.h1`/`.f1` with no inline style toggle at all)
/// must stay on the exact prior single-Tj path -- mechanism M only changes behaviour for a
/// line that actually has a toggle byte to interpret.
@Test func hfLineWithNoToggleBytesIsUnaffectedByMechanismM() throws {
    let doc = headedDoc()   // "Sawyer / Old Times / #", no toggle bytes
    let out = emitPDF(doc, mode: .printed)
    let spans = contentSpans(out)
    #expect(spans.contains { $0.text == "Sawyer / Old Times / 1" && $0.font == "F1" })
}
