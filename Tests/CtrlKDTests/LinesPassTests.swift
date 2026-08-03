import Testing
@testable import CtrlKD

/// Ports of the Python `lines_pass` unit tests. The vector suite proves byte-for-byte
/// equivalence; these document what each rule is FOR.

@Test func wrapJoinsProse() {
    // Mirrors test_wrap_joins_prose.
    let result = linesPass(makeProse())
    // 2026-08-03: blank lines are CONTENT now and are emitted with their own
    // terminator kind, after the line they follow. The text lines' own
    // classification is unchanged — assert that separately from the blanks.
    let seps = result.lines.map(\.separator)
    #expect(seps.filter { $0 != .blankSoft && $0 != .blankHard }
            == [.wrap, .wrap, .para, .eof])
    #expect(seps.filter { $0 == .blankSoft || $0 == .blankHard }.count == 2)
}

@Test func poemLinesKept() {
    // Mirrors test_poem_lines_kept: short lines ending in SOFT returns where the next
    // word would have fit are deliberate breaks (the wrap test); the stanza gap is a
    // soft+hard run -> para.
    let poem = bytes("     A short poem line,") + SOFT +
               bytes("     another short line.") + SOFT + HARD + SOFT +
               bytes("     Second stanza opens,") + SOFT +
               bytes("     and closes.") + HARD
    let seps = linesPass(poem).lines.map(\.separator)
    #expect(seps.filter { $0 != .blankSoft && $0 != .blankHard }
            == [.line, .para, .line, .eof])
    // the stanza gap is SOFT+HARD+SOFT = two real blank lines on paper, and both
    // survive with their own terminator kinds
    #expect(seps.filter { $0 == .blankSoft || $0 == .blankHard }
            == [.blankHard, .blankSoft])
}

@Test func wrapBoundaryIsStrict() {
    // Mirrors test_wrap_boundary_is_strict: a word landing EXACTLY at the margin means
    // WS4 still wrapped -> join, not break. 57 + 1 + 7 == 65, which is not < 65.
    let l1 = bytes(String(repeating: " ", count: 5) + String(repeating: "a", count: 52)) // len 57
    let result = linesPass(l1 + SOFT + bytes("mother.") + HARD)
    #expect(result.margin == 65)
    #expect(result.lines[0].separator == .wrap)
}

@Test func singleHardIsLineBreak() {
    // Mirrors test_single_hard_is_line_break.
    let data = bytes("Jon Michaels") + SOFT + bytes("March 6, 1992") + SOFT + HARD + SOFT +
               bytes("Body text.") + HARD
    let seps = linesPass(data).lines.map(\.separator)
    #expect(seps.filter { $0 != .blankSoft && $0 != .blankHard }
            == [.line, .para, .eof])
    #expect(seps.filter { $0 == .blankSoft || $0 == .blankHard }
            == [.blankHard, .blankSoft])
}

@Test func doubleSpacedWrapCollapses() {
    // Mirrors test_double_spaced_wrap_collapses: double-spaced files put a blank soft
    // line between every wrapped line.
    let l1 = bytes(String(repeating: "z", count: 58) + " filler")
    let data = l1 + SOFT + SOFT + bytes("continues on.") + HARD
    #expect(linesPass(data).lines[0].separator == .wrap)
}
