import Testing
@testable import CtrlKD

/// Mechanism Q (ctrl-kd 605e27b, planning #202 residuals round): a `.h#`/`.f#` line's own
/// right-align tab (WSFORMAT type-9 symmetric sequence) gets its padding BAKED to literal
/// spaces at PARSE time, sized for whatever the eventual `#` page-number substitution was
/// assumed to be wide THEN -- always 1 digit (WordStar's own screen shows the literal '#'
/// token, never the printed page number). Once parsed this padding is a flat, permanent
/// string; nothing downstream used to revisit it per page. Real WS7 re-evaluates the tab
/// at PRINT TIME against each page's own actual substituted width instead: measured on
/// -README.WS pages 9->10 (ws7-prints/v2), the running head's own "WordStar" moves 7.2pt
/// (one Courier column) LEFT the instant the page number grows from 1 digit to 2, while the
/// number's own right edge never moves. Direct port of ctrl-kd's
/// `test_running_head_right_tab_repositions_when_the_page_number_widens` and
/// `test_running_head_right_tab_leaves_a_fonted_header_alone`.

/// A right/center/decimal-align tab (WSFORMAT type-9): word tab size in HMIs, word
/// absolute tab size in HMIs, byte tab type, byte tab size in tenths. Mirrors ctrl-kd's
/// `tab_block` test helper -- `cols` is chosen so `cols * 180` (`tabHMIPerCol`) is the
/// tab's own baked size.
private func tabBlock(cols: Int, absHMI: Int, tabType: UInt8 = 0x5D) -> [UInt8] {
    let size = cols * 180
    return ws7Block(0x09, payload: le16(size) + le16(absHMI) + [tabType, 0x20])
}

@Test func runningHeadRightTabRepositionsWhenThePageNumberWidens() throws {
    // `absHMI` (2340 HMI = 13 cols) + len("TEST / #") (8, un-substituted) recovers
    // targetCol = 21.
    //
    // UPDATED 2026-09-07 (mechanism X, PCL-DIVERGENCE-TRIAGE.md): the target-column
    // arithmetic used to subtract an extra constant 1 ("WS7's own suffix-final print
    // column is exclusive of the tab's own SIZE-convention column") -- fit only against
    // the 2-digit case while `-README`'s own header row was still 24pt too low
    // (mechanism W's own bug), which masked this exact off-by-one behind a much bigger
    // vertical one. `-README`'s `ws7-prints/v3` PRISTINE.EXE recapture, taken AFTER
    // mechanism W's own fix, shows both digit-width buckets uniformly ONE COLUMN
    // (7.2pt) further right than the old `-1` formula ever produced -- the `-1` is
    // gone; see `hfLineOps`'s own doc comment.
    let tab = tabBlock(cols: 13, absHMI: 2340)
    let data = bytes(".pn 9") + HARD
        + bytes(".h1 ") + tab + bytes("TEST / #") + HARD
        + bytes("Page one prose, plain and ordinary and long enough here.") + HARD
        + bytes(".pa") + HARD
        + bytes("Page two prose, also plain, ordinary, long enough here.") + HARD
    let doc = parseWS(data)
    #expect(doc.headerTabs[1] == HFTabMark(charIdx: 0, cols: 13, absHMI: 2340))
    let pdf = emitPDF(doc, mode: .printed)
    let spans = contentSpans(pdf)
    // No font block on this `.h1` -> a fontless header with no toggle bytes of its own
    // takes `hfLineOps`'s single-Tj fast path: padding and text ride in ONE Tj string, at
    // the SAME `left` x on every page -- the repositioning shows up as a shorter
    // leading-space RUN, not a different Td x. targetCol 21: page 9's 8-char suffix
    // ("TEST / 9") pads to 13 cols, page 10's 9-char suffix ("TEST / 10") pads to 12 --
    // ONE column (7.2pt) narrower, the exact -README shape (its own header shifts 7.2pt
    // LEFT the same way).
    let heads = spans.filter { $0.text.contains("TEST") && ($0.y ?? 0) > 720 }.map(\.text)
    #expect(heads == [String(repeating: " ", count: 13) + "TEST / 9",
                      String(repeating: " ", count: 12) + "TEST / 10"])
}

@Test func runningHeadRightTabLeavesAFontedHeaderAlone() throws {
    // `hfLineOps`'s tab_rec branch is gated on `entry == nil` (no `.h#`/`.f#` font block
    // -- Courier, the SAME condition the fast single-Tj path already keys on) -- a `.h1`
    // that opens its OWN type-2 Font block is left at its baked, page-1-shaped padding
    // column count regardless: this branch's own column-width arithmetic is 10cpi
    // Courier's fixed 7.2pt, which a DIFFERENT resolved face's own per-character advance
    // (even a fixed-pitch one, let alone a proportional one) has no reason to share, and
    // no oracle in the corpus combines the two. Same baked 13-column padding on both
    // pages, unchanged.
    let fontBlock = ws7Block(0x02, payload: le16(200) + le16(240) + le16(0)
        + [UInt8](repeating: 0, count: 6))
    let tab = tabBlock(cols: 13, absHMI: 2340)
    let data = bytes(".pn 9") + HARD
        + bytes(".h1 ") + fontBlock + tab + bytes("TEST / #") + HARD
        + bytes("Page one prose, plain and ordinary and long enough here.") + HARD
        + bytes(".pa") + HARD
        + bytes("Page two prose, also plain, ordinary, long enough here.") + HARD
    let doc = parseWS(data)
    let pdf = emitPDF(doc, mode: .printed)
    let spans = contentSpans(pdf)
    let heads = spans.filter { $0.text.contains("TEST") && ($0.y ?? 0) > 700 }.map(\.text)
    #expect(heads == [String(repeating: " ", count: 13) + "TEST / 9",
                      String(repeating: " ", count: 13) + "TEST / 10"])
}
