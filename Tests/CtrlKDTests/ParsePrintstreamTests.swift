import Testing
@testable import CtrlKD

/// Named-test port for `parse_printstream`, plus coverage for the one `parse` front-door
/// branch the vectors don't reach.

@Test func printstreamSuperscriptAndFormFeed() {
    // Mirrors test_printstream_superscript_and_ff. The Python test also asserts against
    // emit.emit_text(doc, 'printed') output; no emitter is ported yet (job-008), so the
    // two text assertions are made against joined span text instead — same intent, one
    // layer lower. Revisit once emit_text exists.
    var data: [UInt8] = bytes("treaties with Indians.")
    data += [0x18] + bytes("1") + [0x12] + bytes("  More text") + HARD
    data += [0x14] + bytes("page one") + HARD
    data += [0x0c] + bytes("page two") + HARD

    let doc = parsePrintstream(data)
    let spans = doc.blocks[0].lines[0].spans
    #expect(spans.contains { $0.text == "1" && $0.styles.contains(.sup) })
    #expect(doc.blocks.contains { $0.kind == .pagebreak })

    // stood in for emit_text: the superscript joins onto the preceding sentence, and the
    // 0x14 printer-housekeeping byte never reaches the text.
    let joined = doc.blocks
        .flatMap(\.lines)
        .map { $0.text() }
        .joined(separator: " ")
    #expect(joined.contains("treaties with Indians.1"))
    #expect(!joined.contains("\u{14}"))
}

// MARK: - gap-closing tests (mutation-proven necessary; not covered by the vectors)

@Test func printCodesSetAndClearRatherThanToggle() {
    // Every vector pairs its style codes properly (on ... off), which makes set/clear and
    // toggle indistinguishable — swapping to toggle passes the whole suite. Printer codes
    // are directional though: an OFF code with the style not active is a no-op
    // (Python uses set.discard), whereas a toggle would switch the style ON. Expectation
    // from the real Python parse_printstream.
    let data = bytes("plain") + [0x12] + bytes("still plain") + HARD   // 0x12 = sup OFF
    let doc = parsePrintstream(data)
    let spans = doc.blocks[0].lines[0].spans
    #expect(spans.map(\.text) == ["plain", "still plain"])
    #expect(spans.allSatisfy { $0.styles == [] })
}

@Test func printCodesDispatchAfterHighBitMasking() {
    // No vector carries a style code with bit 7 set, so looking the code up on the
    // unmasked byte passes the whole suite. Python masks first (core.py:363), so
    // 0x98 (= 0x18 | 0x80) is still superscript-on and 0x92 is superscript-off — on the
    // unmasked byte both would fall through and be dropped as sub-0x20 noise... except
    // they aren't sub-0x20 once high, so they'd land in the text instead. Expectation
    // from the real Python parse_printstream.
    let supOnHigh: [UInt8] = [0x98]      // 0x18 | 0x80
    let supOffHigh: [UInt8] = [0x92]     // 0x12 | 0x80
    var data: [UInt8] = bytes("note") + supOnHigh + bytes("1")
    data += supOffHigh + bytes(" after") + HARD
    let doc = parsePrintstream(data)
    let spans = doc.blocks[0].lines[0].spans
    #expect(spans.map(\.text) == ["note", "1", " after"])
    #expect(spans[1].styles == .sup)
    #expect(spans[0].styles == [])
    #expect(spans[2].styles == [])
}

@Test func frontDoorRoutesPlainTextToPrintstream() {
    // The vectors cover printstream-routes and binary-refuses, but not the `.text` branch:
    // a file detected as `text` (mostly-text, fewer than 2 hard returns) also routes to
    // parsePrintstream, and the resulting Document reports variant `printstream` because
    // parsePrintstream asserts its own meta. Confirmed against the real Python parse().
    let doc = try? parse(bytes("just one line") + HARD)
    #expect(doc?.detection?.variant == .printstream)
    #expect(doc?.columnar == true)
    #expect(doc?.blocks.count == 1)
    #expect(doc?.blocks[0].lines.map { $0.text() } == ["just one line", ""])
}

@Test func frontDoorRefusesBinaryWithDetectedVariant() {
    // Python raises ValueError('not a convertible file (detected: binary)'); the Swift
    // analog carries the variant on the error so a GUI can explain the refusal.
    let byteRange = (0...255).map { UInt8($0) }
    let binary = byteRange + byteRange + byteRange + byteRange
    #expect(throws: ParseError.notConvertible(variant: .binary)) {
        _ = try parse(binary)
    }
}

@Test func frontDoorHonoursVariantOverride() {
    // Python's `variant` argument bypasses detection entirely (core.py:387). A ws4 file
    // forced to printstream parses as a printed page instead: no wrap test runs, so no
    // margin is reported, and the meta reflects the forced route rather than the content.
    let data = ws4Text("forced routing") + HARD
    let doc = try? parse(data, variant: .printstream)
    #expect(doc?.detection?.variant == .printstream)
    #expect(doc?.marginEstimate == nil)
}
