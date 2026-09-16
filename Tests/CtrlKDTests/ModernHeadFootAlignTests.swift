import Testing
@testable import CtrlKD

/// MODERN RUNNING HEADS HONOUR THEIR OWN ALIGNMENT (2026-09-15).
///
/// M5 ruled that Modern keeps the running heads; nothing ever ruled that it flattens
/// them. Every head and foot line was drawn left at Modern's own left margin whatever
/// its `.h#`/`.f#` style declared, so `sawyer/REF/BOOKLET.WS`'s right-aligned "Header
/// Odd" sat on top of its left-aligned "Header Even" at the same x — while its own
/// Modern RTF has carried `\qr` since planning #264 item 4 (row A4). Modern PDF is
/// ruled to be that RTF's printed form (2026-08-05), so the two have to agree.
///
/// The DECISION is the document's (`headerAlign`/`footerAlign`, the same field Printed
/// and the RTF read); the GEOMETRY is Modern's own measure, never M16's `.po` plus a
/// style right margin, which is a Printed-fidelity rule about a page Modern does not
/// draw. Swift port of ctrl-kd's own `test_modern_draws_a_right_aligned_head_*` cases.
///
/// Synthetic fixtures only.

/// A minimal WS5+ document whose `.h1` opens with a 0x11 style-select at slot 2 —
/// `Planning255StyleAlignTests`' own `hfStyleDoc` shape, with a plain (unstyled) `.h1`
/// tag so the flat `headerAlign` every non-Printed surface reads carries the answer.
private func modernHeadDoc(just: Int, secondLine: Bool = false) -> [UInt8] {
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil),
        (name: "WordStar Defaults", record: nil),
        (name: "Header Style", record: styleRecord(just: just)),
    ])
    var body = bytes(".h1 ")
    body += styleRef(2)
    body += bytes("ODD #")
    body += HARD
    if secondLine {
        body += bytes(".h2 EVEN #")
        body += HARD
    }
    body += bytes("Body text follows.")
    body += HARD
    return documentWithStyleLibrary(body: body, library: lib)
}

/// Every drawn (x, text) on the topmost row of Modern page 1.
private func topRow(_ doc: Document) -> [(x: Double, text: String)] {
    let pdf = emitPDF(doc, mode: .modern, options: EmitOptions())
    let text = String(decoding: pdf, as: UTF8.self)
    let stream = text.components(separatedBy: ">>\nstream\n")[1]
        .components(separatedBy: "\nendstream")[0]
    var drawn: [(x: Double, y: Double, text: String)] = []
    var search = stream.startIndex..<stream.endIndex
    let pattern = #"Ts ([\d.]+) ([\d.]+) Td \(([^)]*)\) Tj"#
    while let range = stream.range(of: pattern, options: .regularExpression,
                                   range: search) {
        let body = stream[range]
        let fields = body.components(separatedBy: " ")
        if fields.count >= 4, let x = Double(fields[1]), let y = Double(fields[2]) {
            let open = body.range(of: "(")!
            let close = body.range(of: ") Tj")!
            drawn.append((x: x, y: y,
                          text: String(body[open.upperBound..<close.lowerBound])))
        }
        search = range.upperBound..<stream.endIndex
    }
    guard let top = drawn.map(\.y).max() else { return [] }
    return drawn.filter { abs($0.y - top) < 0.05 }.map { (x: $0.x, text: $0.text) }
}

@Test func modernDrawsARightAlignedHeadAtItsOwnRightMargin() {
    let doc = parseWS(modernHeadDoc(just: -3))              // -3: flush right
    #expect(doc.headerAlign == [1: .right])
    let (margl, _, _, width) = modernGeometry(doc)
    let row = topRow(doc)
    #expect(!row.isEmpty)
    let lastX = row.map(\.x).max() ?? 0
    #expect(lastX > margl + width / 2)
    let insideLeftMargin = margl + 1.0
    #expect((row.map(\.x).min() ?? 0) > insideLeftMargin)
}

@Test func modernCentresACentreAlignedHead() {
    let doc = parseWS(modernHeadDoc(just: -2))              // -2: centre
    #expect(doc.headerAlign == [1: .center])
    let (margl, _, _, width) = modernGeometry(doc)
    let xs = topRow(doc).map(\.x)
    let insideLeftMargin = margl + 1.0
    let measureMidpoint = margl + width / 2
    #expect((xs.min() ?? 0) > insideLeftMargin)
    #expect((xs.min() ?? 0) < measureMidpoint)
}

@Test func modernLeavesAnUnalignedHeadExactlyWhereItWas() {
    // Every head and foot in the corpus but a handful declares no alignment at all, and
    // each of those is drawn at `margl` to the byte, exactly as before alignment was
    // read here.
    let doc = parseWS(modernHeadDoc(just: 0))               // 0: left
    #expect(doc.headerAlign == [:])
    let (margl, _, _, _) = modernGeometry(doc)
    let leftmost = topRow(doc).map(\.x).min() ?? 0
    #expect(abs(leftmost - margl) < 0.01)
}

@Test func modernHeadLinesThatDisagreeGetAParagraphEachInRTF() {
    // RTF's `\line` is a break INSIDE a paragraph and cannot carry a second alignment,
    // so a head whose lines disagree (BOOKLET.WS: a right-aligned "Header Odd" over a
    // left-aligned "Header Even") is written as one paragraph per line. A head whose
    // lines AGREE keeps the single `\line`-joined paragraph RTF has always written.
    let doc = parseWS(modernHeadDoc(just: -3, secondLine: true))
    #expect(doc.headerAlign == [1: .right])
    for mode in [EmitMode.modern, EmitMode.printed] {
        let rtf = emitRTF(doc, mode: mode)
        var group = rtf.components(separatedBy: #"{\header"#)[1]
        group = group.components(separatedBy: #"\par}"#)[0]
        #expect(!group.contains(#"\line"#))
        let halves = group.components(separatedBy: #"\par\pard\plain "#)
        #expect(halves.count == 2)
        #expect(halves[0].contains(#"\qr"#))
        #expect(!(halves.last ?? "").contains(#"\qr"#))
    }
    // Two lines that AGREE stay one paragraph, joined by `\line` — the group RTF has
    // always written, byte for byte.
    let plain = parseWS(modernHeadDoc(just: 0, secondLine: true))
    #expect(plain.headerAlign == [:])
    let rtf = emitRTF(plain, mode: .modern)
    let group = rtf.components(separatedBy: #"{\header"#)[1]
        .components(separatedBy: #"\par}"#)[0]
    #expect(group.contains(#"\line"#))
    #expect(group.components(separatedBy: #"\pard\plain"#).count == 2)
}
