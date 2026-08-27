/// A type-9 TAB block's own absolute stop, and the invariant that a tab is a HORIZONTAL
/// instruction. Port of ctrl-kd's `test_a_tab_never_moves_a_line_vertically` and
/// `test_a_font_change_at_a_tabs_own_offset_reaches_the_tabs_padding` (c3c35a5).
import Testing
@testable import CtrlKD

/// A tab is a HORIZONTAL instruction; it must not touch vertical layout.
///
/// THE DEFECT (OLDTIMES.WS, 236 type-9 blocks, the whole corpus's worst case): the
/// real-tab-position fix gave the tab's own padding run its own span, drained inside
/// `decodeSpans` BEFORE the font/colour queues at the same offset -- so a font change
/// landing exactly where a line's leading tab begins (WordStar's ordinary encoding for
/// "this line is set in face N and starts at stop M": the 0x02 font block, then the 0x09
/// tab block, then the text) no longer reached that padding. The padding kept the OUTGOING
/// font instead of the incoming one, and `fontLeadPt` -- which sizes a line's leading to
/// 1.2 x the LARGEST proportional font tagged ANYWHERE on it, and carries that size
/// forward through blank lines via `state` -- duly measured the line against the previous,
/// larger face. OLDTIMES's 18pt title bled onto its 14pt byline: 1.2 x (18 - 14) = 4.8pt
/// on the byline's own line, 4.8pt again on the blank after it (whose carried `state` was
/// raised the same way), 9.6pt cumulative for the rest of the document, which cost page 1
/// a line.
///
/// Pinned as the ARITHMETIC, not just "unchanged": the 14pt line's own
/// baseline-to-baseline advance must be 1.2 x 14 = 16.8pt whether its text is reached by a
/// tab or typed flush, never 1.2 x 18 = 21.6pt. The fixture's two documents differ ONLY in
/// the tab.
@Test func aTabNeverMovesALineVertically() {
    let helv = helvTypestyle()
    let tab = ws7Block(0x09, payload: le16(10) + le16(1000) + bytes(" \r"))

    func ys(leadIn: [UInt8]) -> [String: Double] {
        // staged: the one-expression form times out the 6.2.4 type-checker
        var data = ws7Block(0x00)
        data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
        data += fontBlock(helv, points: 18.0, styleBits: 0x8000, width: 250)
        data += bytes("Title") + HARD
        data += fontBlock(helv, points: 14.0, styleBits: 0x8000, width: 200)
        data += leadIn + bytes("Byline") + HARD
        data += fontBlock(helv, points: 14.0, styleBits: 0x8000, width: 200)
        data += bytes("Third") + HARD
        data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
        let spans = contentSpans(emitPDF(parseWS(data), mode: .printed))
        var out: [String: Double] = [:]
        for word in ["Title", "Byline", "Third"] {
            if let y = spans.first(where: { $0.text == word })?.y { out[word] = y }
        }
        return out
    }

    let typed = ys(leadIn: [])
    let tabbed = ys(leadIn: tab)
    #expect(typed.count == 3)
    // The tab moves the BYLINE sideways and nothing else: every y identical.
    #expect(tabbed == typed)
    // ...and the 14pt line's advance is its OWN font's 1.2x lead, not the 18pt title's,
    // in both spellings.
    for measured in [typed, tabbed] {
        let advance = tenth(measured["Byline"]! - measured["Third"]!)
        #expect(advance == 16.8)                      // 1.2 x 14
        #expect(advance != 21.6)                      // NOT 1.2 x 18
    }
}

/// The mechanism behind the test above, pinned at the parse layer: `decodeSpans` drains
/// its mark queues in a loop, and the BYTE-CONSUMING tab queue must fire AFTER the
/// state-only font/colour queues, so a mark sitting at the padding's own first offset is
/// in the active state before the padding span is built. WordStar writes exactly this
/// adjacency for a styled, tab-indented line, and before the fix the padding was cut with
/// the previous line's state still active.
@Test func aFontChangeAtATabsOwnOffsetReachesTheTabsPadding() throws {
    let helv = helvTypestyle()
    let tab = ws7Block(0x09, payload: le16(10) + le16(1000) + bytes(" \r"))
    // staged: the one-expression form times out the 6.2.4 type-checker
    var data = ws7Block(0x00)
    data += bytes("Prose padding so the detector reads this as a document, plainly.") + HARD
    data += fontBlock(helv, points: 18.0, styleBits: 0x8000, width: 250)
    data += bytes("Title") + HARD
    data += fontBlock(helv, points: 14.0, styleBits: 0x8000, width: 200)
    data += tab + bytes("Byline") + HARD
    data += bytes("A closing line of ordinary prose keeps the byte ratio honest.") + HARD
    let doc = parseWS(data)
    let line = try #require(doc.blocks.flatMap(\.lines)
        .first { $0.spans.contains { $0.text.trimmed() == "Byline" } })
    let pad = try #require(line.spans.first { $0.tabHMI != nil })
    let text = try #require(line.spans.first { $0.text.trimmed() == "Byline" })
    #expect(pad.font != nil)
    #expect(pad.font == text.font)      // the INCOMING face, not the title's
}
