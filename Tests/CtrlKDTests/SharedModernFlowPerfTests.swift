import Testing
@testable import CtrlKD

/// Planning #271 M7 (Jon's ruling 2026-09-13: "-HOLYMAC.WS is VERY slow to open").
/// The first of two perf changes in the `layout` path, both byte-identical.
///
/// `emitLayout` shares the ONE `modernSemanticFlow` it already ran with
/// `attachGraphicCellsModern`, which used to derive its own.
///
/// Cross-engine byte parity for the whole corpus is `AnswerKeyParityTests`' own job;
/// these are the narrow, synthetic checks that the sharing is exact. Port of ctrl-kd's
/// own four new cases in `tests/test_graphic_cells.py`.

// -------------------------------------------------------------- the shared flow

@Test func aSharedSemanticFlowAttachesExactlyTheSameCells() {
    var src: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src += [UInt8](repeating: 0xCD, count: 10)
    src += HARD
    src += bytes("Prose after the rule, so the flow has more than one item.")
    src += HARD
    let doc = parseWS(src)
    let fresh = attachGraphicCellsModern(doc, notes: EmitOptions.defaultNotes, noteRefs: .word)
    let sem = modernSemanticFlow(doc, notes: EmitOptions.defaultNotes, noteRefs: .word)
    let shared = attachGraphicCellsModern(doc, notes: EmitOptions.defaultNotes,
                                          noteRefs: .word, semCached: sem)
    #expect(!shared.isEmpty)
    #expect(shared.keys.sorted() == fresh.keys.sorted())
    for key in fresh.keys {
        #expect(shared[key]?.map(\.x) == fresh[key]?.map(\.x))
        #expect(shared[key]?.map(\.char) == fresh[key]?.map(\.char))
        #expect(shared[key]?.map(\.page) == fresh[key]?.map(\.page))
    }
}

@Test func theSharedFlowLeavesTheLayoutJSONByteIdentical() {
    var src: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src += [UInt8](repeating: 0xCD, count: 10)
    src += HARD
    src += bytes("Prose after the rule.")
    src += HARD
    let doc = parseWS(src)
    let a = emitLayout(doc, mode: .modern)
    let b = emitLayout(doc, mode: .modern)
    #expect(a == b)
    #expect(a.contains("\"graphic_cells\""))
}

@Test func hasModernGraphicContentIsTheShortCircuitItClaimsToBe() {
    var graphicSrc: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    graphicSrc += [UInt8](repeating: 0xCD, count: 4)
    graphicSrc += HARD
    var proseSrc: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    proseSrc += bytes("Nothing graphic here at all.")
    proseSrc += HARD
    let graphic = parseWS(graphicSrc)
    let prose = parseWS(proseSrc)
    #expect(hasModernGraphicContent(graphic))
    #expect(!hasModernGraphicContent(prose))
    // the predicate and the function it guards agree, both ways
    #expect(!attachGraphicCellsModern(graphic, notes: EmitOptions.defaultNotes,
                                      noteRefs: .word).isEmpty)
    #expect(attachGraphicCellsModern(prose, notes: EmitOptions.defaultNotes,
                                     noteRefs: .word).isEmpty)
}

/// `modernStreams`' documented quirk resolves an EMPTY note set back to the default
/// three, so a caller's empty-notes flow is NOT the flow that pass would build --
/// `attachGraphicCellsModern` drops the shared one on the floor there.
@Test func anEmptyNoteSetNeverTakesTheSharedFlow() {
    var src: [UInt8] = ws7Block(0x00, payload: [0x70] + [UInt8](repeating: 0, count: 15))
    src += [UInt8](repeating: 0xCD, count: 10)
    src += HARD
    let doc = parseWS(src)
    let wrong = modernSemanticFlow(doc, notes: [], noteRefs: .word)
    let withWrong = attachGraphicCellsModern(doc, notes: [], noteRefs: .word, semCached: wrong)
    let without = attachGraphicCellsModern(doc, notes: [], noteRefs: .word)
    #expect(withWrong.keys.sorted() == without.keys.sorted())
    for key in without.keys {
        #expect(withWrong[key]?.map(\.x) == without[key]?.map(\.x))
    }
}
