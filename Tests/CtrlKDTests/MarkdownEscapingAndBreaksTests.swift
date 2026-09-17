import Foundation
import Testing
@testable import CtrlKD

/// E7 (Jon, 2026-09-17): the three Markdown emitter defects the style-export audit found,
/// and the boundaries of each fix. Swift port of ctrl-kd's
/// `tests/test_markdown_escaping_and_breaks.py` — same synthetic documents, same
/// expectations.
///
/// All three were found by `research/2026-09-17_markdown-style-export-audit.md` and all
/// three affected BOTH engines identically, which is what made them correctness bugs
/// rather than portability ones. Each fix is the audit's own recommended option.
///
///   A. STRIKEOUT RUNS COLLIDED. A bold or italic word butted against the strikeout text
///      around it is a separate span, so the emitter closed the strikeout and reopened it
///      with nothing in between: `~~alpha~~~~**beta**~~~~gamma~~`. Four tildes are not
///      strikethrough in any flavour — the strikeout was lost AND the tildes became
///      visible text. Fixed by merging a run the span split (audit §6.A option 3).
///
///   B. `<` AND `&` WERE NOT ESCAPED. A document that literally says `<SP>` or `<Enter>`
///      emitted it raw, and every renderer read it as an unknown HTML element and showed
///      NOTHING — the word vanished. `<B>` is worse: a real tag, switching bold on with
///      nothing to switch it off. Fixed by escaping both (audit §6.B option 1).
///
///   C. HARD-BREAK UNITS EMITTED WHITESPACE-ONLY LINES. A verse/stanza unit containing a
///      blank line was joined with the two-trailing-spaces hard break, turning the blank
///      into a line of two spaces. CommonMark reads that as a blank line, so the paragraph
///      split anyway — into pieces whose raw text claimed otherwise. Fixed by closing the
///      unit at a blank line (audit §6.C option 2), plus dropping the dangling trailing
///      `  ` a unit ending in a blank used to leave.
///
/// DELIBERATELY UNCHANGED, and tested as such so a later reader does not "fix" them by
/// accident: Printed-mode Markdown, and any print-stream/columnar document in either mode,
/// is a FENCED CODE BLOCK of the text rendering. Its content is literal — escaping `<`
/// inside it would put a backslash on the reader's screen, and collapsing its blank lines
/// would destroy the layout that is the whole point of a captured page.
///
/// Synthetic fixtures only.

private let e7Hard: [UInt8] = [0x0D, 0x0A]

private func e7WS7Block(_ cmd: UInt8, _ content: [UInt8] = []) -> [UInt8] {
    let count = UInt16(content.count + 4)
    var out: [UInt8] = [0x1D]
    out += [UInt8(count & 0xFF), UInt8(count >> 8)]
    out.append(cmd)
    out += content
    out += [UInt8(count & 0xFF), UInt8(count >> 8)]
    out.append(0x1D)
    return out
}

/// Without the WS5+ seed a short synthetic file classifies as a print stream, which
/// renders as a fenced block and exercises none of this.
private let e7Seed = e7WS7Block(0x0B, [0, 0, 0, 0])

// WordStar's inline toggles (`WS_TOGGLES`): each byte turns its attribute on, and the
// same byte turns it off again.
private let e7Bold: [UInt8] = [0x02]      // ^PB
private let e7Under: [UInt8] = [0x13]     // ^PS
private let e7Italic: [UInt8] = [0x19]    // ^PY
private let e7Strike: [UInt8] = [0x18]    // ^PX

private func e7Doc(_ parts: [[UInt8]]) -> [UInt8] {
    var out: [UInt8] = []
    for part in parts { out += part }
    return out
}

private func e7Text(_ s: String) -> [UInt8] { Array(s.utf8) }

private func e7Markdown(_ data: [UInt8], mode: EmitMode = .modern) -> String {
    emitMarkdown(parseWS(data), mode: mode)
}

// ------------------------------------------------------------------------ A

@Test func aStyleSplitStrikeoutRunDoesNotEmitFourTildes() {
    // The reported shape, exactly: a bold word butted straight against the strikeout text
    // around it, no space between. Before the guard this emitted
    //     ~~alpha~~~~**beta**~~~~gamma~~
    // — the strikeout closing and reopening with nothing in between.
    let data = e7Doc([e7Seed, e7Strike, e7Text("alpha"), e7Bold, e7Text("beta"), e7Bold,
                      e7Text("gamma"), e7Strike, e7Hard])
    let out = e7Markdown(data).trimmed()
    #expect(!out.contains("~~~~"), "\(out)")
    #expect(out == "~~alpha**beta**gamma~~", "\(out)")
}

@Test func theMergedStrikeoutStillMarksEveryWord() {
    // The guard must not lose the run it merges: ONE `~~` pair around the whole thing,
    // with the bold still inside it.
    let data = e7Doc([e7Seed, e7Strike, e7Text("alpha"), e7Bold, e7Text("beta"), e7Bold,
                      e7Text("gamma"), e7Strike, e7Hard])
    let out = e7Markdown(data)
    #expect(out.components(separatedBy: "~~").count - 1 == 2, "\(out)")
    #expect(out.contains("alpha") && out.contains("beta") && out.contains("gamma"), "\(out)")
}

@Test func aCosmeticStrikeoutSplitIsDeliberatelyLeftAlone() {
    // A SPACE between the spans means the delimiters are not adjacent, so there is no
    // collision — three struck runs render correctly. This is the audit's option 3 doing
    // exactly what it promised: fix the rendering breakage, leave the cosmetic splits
    // alone. Tidying those too would re-baseline every Markdown cell in both engines.
    let data = e7Doc([e7Seed, e7Strike, e7Text("alpha "), e7Bold, e7Text("beta"), e7Bold,
                      e7Text(" gamma"), e7Strike, e7Hard])
    #expect(e7Markdown(data).trimmed() == "~~alpha~~ ~~**beta**~~ ~~gamma~~")
}

@Test func boldBesideItalicIsNeverMerged() {
    // The guard compares the delimiter each span actually emitted, never a string suffix —
    // a suffix test cannot tell `**bold**` followed by `*italic*` (which ends in `*` and
    // starts with `*`) from two halves of one italic run, and merging them would corrupt
    // both.
    let data = e7Doc([e7Seed, e7Bold, e7Text("bold"), e7Bold,
                      e7Italic, e7Text("italic"), e7Italic, e7Hard])
    let out = e7Markdown(data)
    #expect(out.contains("**bold**"), "\(out)")
    #expect(out.contains("*italic*"), "\(out)")
}

// ------------------------------------------------------------------------ B

@Test func angleBracketsInTheSourceSurvive() {
    // `<SP>` used to vanish entirely: every renderer read it as an unknown HTML element
    // and showed nothing.
    let out = e7Markdown(e7Doc([e7Seed, e7Text("Press <SP> then <Enter>."), e7Hard]))
    #expect(out.contains("\\<SP>") && out.contains("\\<Enter>"), "\(out)")
}

@Test func aSourceBTagDoesNotSwitchBoldOn() {
    // `<B>` is a REAL tag — unescaped it turned bold on for the rest of the document with
    // nothing to turn it off.
    let out = e7Markdown(e7Doc([e7Seed, e7Text("Type <B> to continue."), e7Hard]))
    #expect(out.contains("\\<B>"), "\(out)")
}

@Test func ampersandsAreEscaped() {
    let out = e7Markdown(e7Doc([e7Seed, e7Text("Smith & Sons."), e7Hard]))
    #expect(out.contains("\\&"), "\(out)")
}

@Test func theEmittersOwnTagsAreNeverEscaped() {
    // `<u>`/`<sub>`/`<sup>` are wrapped around text the escaper has already returned, so
    // they must come through intact — escaping them would put a backslash on the reader's
    // screen and lose the underline.
    let out = e7Markdown(e7Doc([e7Seed, e7Text("plain "), e7Under, e7Text("under"),
                                e7Under, e7Text(" plain"), e7Hard]))
    #expect(out.contains("<u>under</u>"), "\(out)")
    #expect(!out.contains("\\<u>"), "\(out)")
}

@Test func aNoteDefinitionEscapesTheSameCharactersAsBodyText() {
    // A note's raw text bypasses the span path, and escaped only the backslash until E7 —
    // so `<-Repeated` in a real TAGS annotation still vanished after every span had been
    // fixed. One escape definition, two readers.
    #expect(markdownEscape("<-Repeated & <B>") == "\\<-Repeated \\& \\<B>")
}

// ------------------------------------------------------------------------ C

/// A hand-positioned (`.aw off`) block: never reflowed, so its lines keep their own breaks
/// and take the two-trailing-spaces hard-break join. A blank line INSIDE such a block is
/// the real shape — a blank between two ordinary paragraphs ends the block instead and
/// never reaches the join. The corpus documents that carry this are mail-merge label
/// templates whose body opens with a blank line after their dot-command preamble.
private func e7Verse(_ lines: [String]) -> [UInt8] {
    var out = e7Seed + e7Text(".aw off") + e7Hard
    for (i, line) in lines.enumerated() {
        if i > 0 { out += e7Hard }
        out += e7Text(line)
    }
    out += e7Hard
    return out
}

@Test func aBlankLineInsideAHardBreakUnitStartsANewParagraph() {
    // Before the fix this emitted a first line of nothing but the two hard-break spaces.
    // CommonMark reads a whitespace-only line as blank, so the paragraph split anyway —
    // into pieces whose raw text claimed a break that could not happen.
    let out = e7Markdown(e7Verse(["", "alpha", "beta"]))
    let outLines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(!outLines.contains { !$0.isEmpty && $0.trimmed().isEmpty }, "\(out)")
    #expect(out.trimmed() == "alpha  \nbeta", "\(out)")
}

@Test func noLineIsEverOnlyWhitespace() {
    let out = e7Markdown(e7Verse(["", "alpha", "beta", "", "gamma"]))
    for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        #expect(line.isEmpty || !line.trimmed().isEmpty, "\(line)")
    }
}

@Test func aUnitEndingInABlankLeavesNoDanglingHardBreak() {
    // Inert — nothing follows it to break onto — but non-conforming, and it made the raw
    // text claim a break that could not happen.
    let out = e7Markdown(e7Verse(["", "alpha", "beta", ""]))
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (i, line) in lines.enumerated() where i + 1 < lines.count && line.hasSuffix("  ") {
        #expect(!lines[i + 1].trimmed().isEmpty, "\(out)")
    }
}

@Test func aRealHardBreakBetweenTwoContentLinesSurvives() {
    // The fix must not take the feature away.
    #expect(e7Markdown(e7Verse(["", "first verse", "second verse"])).contains("  \n"))
}

// ------------------------------------------- the fenced body is left literal

@Test func aPrintStreamRendersFencedAndIsLeftLiteral() {
    // A print stream (and every Printed-mode Markdown body) is a FENCED CODE BLOCK of the
    // text rendering. Inside a fence Markdown has no syntax at all, so escaping `<` would
    // put a visible backslash on the reader's screen and collapsing blank lines would
    // destroy the captured page's layout. None of the three fixes may reach it.
    var data = e7Text("Plain text with <SP> in it.")
    data += e7Hard
    data += e7Hard
    data += e7Text("After a blank.")
    data += e7Hard
    let doc = parseWS(data)
    #expect(isPrinted(doc), "fixture must classify as a print stream")
    let out = emitMarkdown(doc, mode: .modern)
    #expect(out.trimmed().hasPrefix("```"), "\(out)")
    #expect(out.contains("<SP>") && !out.contains("\\<SP>"), "\(out)")
}

@Test func printedModeMarkdownIsTheFencedBodyForAWSDocumentToo() {
    // Same rule from the other direction.
    let out = e7Markdown(e7Doc([e7Seed, e7Text("Press <SP> now."), e7Hard]), mode: .printed)
    #expect(out.trimmed().hasPrefix("```"), "\(out)")
    #expect(!out.contains("\\<"), "\(out)")
}
