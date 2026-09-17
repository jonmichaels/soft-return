/// E9 R2 (Jon's ruling 2026-09-17, the human-eye export audit section C): WordStar's
/// colour 15 is REVERSE VIDEO, not a colour, so RTF and HTML give it a ground. Port of
/// ctrl-kd's `tests/test_reverse_video_ground.py`.
///
/// THE DEFECT. The exporters kept the colour -- RTF `\cf16`, HTML `.ws-colour-15 {
/// color:#ffffff }` -- and never produced the black bar WordStar printed it in, so the
/// line was painted white on a white page and simply was not there. 19 runs in 3
/// documents (`LJ6DTP.WS` twice and `PSPRINT.TST`, whose own text reads "White Text on a
/// Black Background"); the Text export still carried the words, which is how the audit
/// could tell nothing was lost upstream.
///
/// `\chcbpat` is RTF's own character shading and `\highlight` is the same fact in the
/// vocabulary Word reads; `\cf1` is the colour table's Black. Every other palette index is
/// untouched -- white is the only one that vanishes.
///
/// Synthetic fixtures only.
import Testing
@testable import CtrlKD

private func colourDoc(_ index: UInt8, _ text: String) -> Document {
    var data = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    data += ws7Block(0x01, payload: [index, 0])      // current colour, previous Black
    data += Array((text + "\r\n").utf8)
    return parseWS(data)
}

private func whiteDoc() -> Document {
    colourDoc(15, "White Text on a Black Background")
}

private func cyanDoc() -> Document { colourDoc(3, "Cyan") }

@Test func rtfWhiteRunGetsABlackGround() {
    let rtf = emitRTF(whiteDoc(), mode: .printed)
    #expect(rtf.contains(#"\cf16 "#))                      // the white is still white
    #expect(rtf.contains(#"\chcbpat1 \highlight1 "#))      // on the table's Black
}

@Test func rtfOtherColoursGetNoGround() {
    let rtf = emitRTF(cyanDoc(), mode: .printed)
    #expect(rtf.contains(#"\cf4 "#))
    #expect(!rtf.contains(#"\chcbpat"#))
}

@Test func htmlWhiteRunGetsABlackGround() {
    #expect(emitHTML(whiteDoc(), mode: .printed)
        .contains(".ws-colour-15 { color:#ffffff; background:#000000 }"))
}

@Test func htmlOtherColoursGetNoGround() {
    let html = emitHTML(cyanDoc(), mode: .printed)
    #expect(html.contains(".ws-colour-3 { color:#00aaaa }"))
    #expect(!html.contains("background:#000000"))
}

@Test func reverseVideoRidesBothModes() {
    // A knockout banner is unreadable in either mode; nothing about the reverse-video
    // fact is Printed's alone.
    for mode in [EmitMode.printed, .modern] {
        #expect(emitRTF(whiteDoc(), mode: mode).contains(#"\chcbpat1 \highlight1 "#))
        #expect(emitHTML(whiteDoc(), mode: mode).contains("background:#000000"))
    }
}

@Test func inlineStylingOffStripsTheGroundToo() {
    // `--inline-styling off` strips the author's own colour choice; the ground rides
    // with it and never outlives it.
    var options = EmitOptions()
    options.inlineStyling = false
    let rtf = emitRTF(whiteDoc(), mode: .printed, options: options)
    #expect(!rtf.contains(#"\chcbpat"#) && !rtf.contains(#"\cf"#))
}
