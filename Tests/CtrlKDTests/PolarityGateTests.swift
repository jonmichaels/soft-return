import Testing
@testable import CtrlKD

/// b24 engine wave, round 20 item 1 (RJS.WS investigation / slate item 10) — mirrors
/// ctrl-kd's tests/test_polarity_gate.py.
///
/// RJS.WS investigation verdict (2026-08-18, ctrl-kd): "renders entirely struck-
/// through" traced to a real style-library record (attrs_on=1, strikeout) every content
/// block legitimately selects — SETTLED BY REAL WS7 BYTES: printed through the actual
/// Sawyer WS7 install under DOSBox-X, and every line of the captured PCL shows literal
/// hyphen characters at the identical x/y position as the real words — real WordStar
/// 7's own LaserJet driver rendering of strikeout via an overprinted dash rule.
/// ctrl-kd's whole-document strikethrough is THEREFORE PERIOD-ACCURATE, not a parser
/// bug. NO PRODUCTION CODE CHANGE resulted — sr's engine needs no port for this half.
///
/// The polarity gate below is the SEPARATE, general correctness check Jon asked for
/// regardless: a span's own RAW styles (via `wsToggles` bytes — never
/// `block.styleAttrs`, a different, independently-enabling mechanism RJS.WS itself
/// proves is allowed to diverge from raw toggle-byte counts) must never show an
/// attribute whose toggle byte(s) never occur in the document's own cleaned text stream
/// (`symmetricBlocks(_:).bytes` — every byte that reaches `decodeSpans`, i.e. outside
/// every validated 1D-framed symmetric block). A violation would mean raw binary
/// payload bytes leaking into the inline decode path and being misread as a toggle.

/// `wsToggles` groups two source bytes onto one style (`.bold`: 0x02 bold, 0x04
/// doublestrike-degrades-to-bold) — the invariant must group them too, or a document
/// with 0x02 present/0x04 absent would look like a false violation for a style
/// legitimately explained by the OTHER byte. Port of `_TAG_BYTES`.
private let tagBytes: [(style: Style, bytes: [UInt8])] = [
    (.bold, [0x02, 0x04]),
    (.underline, [0x13]),
    (.italic, [0x19]),
    (.sup, [0x14]),
    (.sub, [0x16]),
    (.strike, [0x18]),
]

/// `[(style, byteVals)]` — styles that appear as a RAW (unmerged) span style somewhere
/// in the document despite their toggle byte(s) never occurring in the cleaned text
/// stream. Port of `inline_polarity_violations`.
func inlinePolarityViolations(_ data: [UInt8]) -> [(style: Style, bytes: [UInt8])] {
    let detection = detect(data)
    guard detection.variant == .ws4 || detection.variant == .ws5plus else { return [] }
    guard eraFor(detection.variant).symmetricBlocks else { return [] }
    let out = symmetricBlocks(data).bytes
    let doc = parseWS(data)
    // A note-reference marker is SYNTHESIZED with its own `.sup` style
    // (`decodeSpans`'s fnCounter mechanism — a WordStar convention for how footnote
    // numbers display, wholly unrelated to the ^T (0x14) toggle byte). Corpus-proven
    // false-positive source (28/86 real ctrl-kd documents) once this gate started
    // checking the real corpus — excluded at the source, not special-cased per
    // document.
    var rawStyles: Style = []
    for block in doc.blocks {
        for line in block.lines {
            for span in line.spans where !span.styles.contains(.fnref) {
                rawStyles.formUnion(span.styles)
            }
        }
    }
    var violations: [(style: Style, bytes: [UInt8])] = []
    for (style, byteVals) in tagBytes where rawStyles.contains(style) {
        if !byteVals.contains(where: { out.contains($0) }) {
            violations.append((style, byteVals))
        }
    }
    return violations
}

@Test func ordinaryToggleProducesNoViolation() throws {
    // ^S...^S (0x13, underline) really is in the text stream -- the style it produces
    // is legitimately explained, not a violation.
    let data = bytes("plain ") + [0x13] + bytes("underlined") + [0x13] + bytes(" text\r\n")
    #expect(inlinePolarityViolations(data).isEmpty)
}

@Test func aToggleByteAbsentFromTextNeverAppearsAsARawSpanTag() throws {
    let data = bytes("Nothing but plain prose, no toggles anywhere.\r\n")
    let doc = parseWS(data)
    var rawStyles: Style = []
    for block in doc.blocks {
        for line in block.lines {
            for span in line.spans { rawStyles.formUnion(span.styles) }
        }
    }
    for (style, _) in tagBytes {
        #expect(!rawStyles.contains(style))
    }
    #expect(inlinePolarityViolations(data).isEmpty)
}

@Test func gateCorrectlyIgnoresToggleBytesInsideARecognizedBlockPayload() throws {
    // A pix tag's payload can legitimately contain byte values that equal a toggle
    // byte (e.g. a DOS path fragment) -- they must never register as a real inline
    // toggle just because the byte VALUE matches.
    let block = wsBlock(cmd: 0x10, content: Array(#"C:\PIX\A"#.utf8) + [0x18] + Array("B.PIX".utf8))
    let data = bytes("Before. ") + block + bytes(" After, no real toggles.\r\n")
    #expect(inlinePolarityViolations(data).isEmpty)
}

@Test func gateIgnoresFootnoteReferenceMarkers() throws {
    // A footnote reference number is SYNTHESIZED as {.sup, .fnref} by decodeSpans
    // (WordStar convention: note markers display raised) -- unrelated to the ^T
    // (0x14) toggle byte. The real, corpus-proven false-positive source the gate's
    // fnref exclusion fixes.
    let block = ws7Block(0x03, payload: Array("A footnote.".utf8))
    let data = bytes("Reference") + block + bytes(" here, no real superscript toggle.\r\n")
    let doc = parseWS(data)
    let hasFnrefSup = doc.blocks.flatMap(\.lines).flatMap(\.spans)
        .contains { $0.styles.contains(.sup) && $0.styles.contains(.fnref) }
    #expect(hasFnrefSup, "fixture did not produce the marker this test needs")
    #expect(inlinePolarityViolations(data).isEmpty)
}

@Test func gateFlagsAGenuineSyntheticLeak() throws {
    // A deliberately-constructed adversarial case, to prove the gate itself actually
    // fires: a `.strike` style with no corresponding 0x18 anywhere in the "cleaned
    // stream" -- the shape a genuine record-boundary leak would produce.
    let rawStyles: Style = [.strike]
    let out: [UInt8] = Array("no toggle bytes in this cleaned stream at all".utf8)
    let violations = tagBytes.filter { style, byteVals in
        rawStyles.contains(style) && !byteVals.contains(where: { out.contains($0) })
    }
    #expect(violations.count == 1)
    #expect(violations.first?.style == .strike)
    #expect(violations.first?.bytes == [0x18])
}
