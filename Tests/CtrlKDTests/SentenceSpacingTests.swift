import Testing
@testable import CtrlKD

/// b33 N9 (Jon's ruling, 2026-08-26, field notes register row, mirrored from ctrl-kd
/// 0750948): sentence-spacing export option {keep, single}.
///
/// RULED (verbatim): "let's have a default on Modern exports to convert to single
/// space after a period ending a sentence. Printed (and Native) should keep documents
/// as is. And then the flag allows you to force the other option." The field notes
/// name '.' explicitly and don't rule '?'/'!' in or out; this implementation covers
/// all three real sentence-enders (the classic typing-class rule) -- see
/// `sentenceEndChars` (Block.swift).
///
/// The rule is deliberately SIMPLE, no abbreviation detection ("no cleverness"): a
/// double space after '.', '?', or '!' collapses to one space regardless of what
/// precedes it (an abbreviation like "e.g." included). A double space that does NOT
/// follow one of those three characters (after a comma, or with no punctuation at all)
/// is untouched in EVERY mode -- this flag has nothing to say about it.
///
/// Independent of the flag: Markdown must never emit a line ending in 2+ spaces
/// unless it is the emitter's own deliberate hard-break join (a verified verse/stanza
/// unit) -- CommonMark reads a coincidental trailing double space as a break the
/// source never asked for. The two CLI-wiring tests for this flag live in
/// `SRCLITests.swift` (`sentenceSpacingFlagIsValidatedAgainstItsChoices`/
/// `sentenceSpacingFlagReachesTheEmitterAndForcesKeepOnModernDefault`), matching
/// ctrl-kd's own `test_cli_sentence_spacing_*` pair.

private let header = ws7Block(0x00)

private let sentence = "He said hello.  She replied yes!  Then asked why?  "
    + "I don't know, honestly."

private func doc(_ text: String = sentence) -> Document {
    parseWS(header + bytes(text) + HARD)
}

private let collapsed = "He said hello. She replied yes! Then asked why? "
    + "I don't know, honestly."
// HTML escapes the apostrophe -- the substring every HTML check uses instead, short
// enough to still prove the collapse happened at every sentence end.
private let collapsedNoApos = "He said hello. She replied yes! Then asked why? I"

// --------------------------------------------------------- Modern default

@Test func modernDefaultConvertsToSingleSpaceText() throws {
    let d = doc()
    let out = emitText(d, mode: .modern)
    #expect(!out.trimmed().contains("  "))
    #expect(out.contains(collapsed))
}

@Test func modernDefaultConvertsToSingleSpaceMarkdown() throws {
    let d = doc()
    let out = emitMarkdown(d, mode: .modern)
    #expect(!out.trimmed().contains("  "))
    #expect(out.contains(collapsed))
}

@Test func modernDefaultConvertsToSingleSpaceHTML() throws {
    let d = doc()
    let out = emitHTML(d, mode: .modern)
    #expect(out.contains(collapsedNoApos))
    // the body paragraph itself carries no double space (the generated CSS's own
    // internal formatting is not what this checks -- just the rendered sentence)
    #expect(!out.contains("hello.  She"))
}

@Test func modernDefaultConvertsToSingleSpaceRTF() throws {
    let d = doc()
    let out = emitRTF(d, mode: .modern)
    #expect(out.contains(collapsed))
    #expect(!out.contains("hello.  She"))
}

@Test func modernDefaultConvertsToSingleSpacePDF() throws {
    let d = doc()
    let auto = emitPDF(d, mode: .modern)
    let forcedSingle = emitPDF(d, mode: .modern, options: EmitOptions(sentenceSpacing: .single))
    let forcedKeep = emitPDF(d, mode: .modern, options: EmitOptions(sentenceSpacing: .keep))
    // auto (the default) must match the explicit 'single' force, and differ from the
    // explicit 'keep' force -- proves the mode-aware default actually resolved to
    // single, not just "did nothing".
    #expect(auto == forcedSingle)
    #expect(auto != forcedKeep)
}

// ----------------------------------------------------- Printed/Native default

@Test func printedDefaultPreservesDoubleSpaceText() throws {
    let d = doc()
    let out = emitText(d, mode: .printed)
    #expect(out.contains("hello.  She replied yes!  Then asked why?  I"))
}

@Test func printedDefaultPreservesDoubleSpaceMarkdown() throws {
    let d = doc()
    let out = emitMarkdown(d, mode: .printed)
    #expect(out.contains("hello.  She replied yes!  Then asked why?  I"))
}

@Test func printedDefaultPreservesDoubleSpaceHTML() throws {
    let d = doc()
    let out = emitHTML(d, mode: .printed)
    #expect(out.contains("hello.  She replied yes!  Then asked why?  I"))
}

@Test func printedDefaultPreservesDoubleSpaceRTF() throws {
    let d = doc()
    let out = emitRTF(d, mode: .printed)
    #expect(out.contains("hello.  She replied yes!  Then asked why?  I"))
}

@Test func printedDefaultPreservesDoubleSpacePDF() throws {
    let d = doc()
    let auto = emitPDF(d, mode: .printed)
    let forcedKeep = emitPDF(d, mode: .printed, options: EmitOptions(sentenceSpacing: .keep))
    let forcedSingle = emitPDF(d, mode: .printed, options: EmitOptions(sentenceSpacing: .single))
    #expect(auto == forcedKeep)
    #expect(auto != forcedSingle)
}

// ------------------------------------------------------------- flag overrides

@Test func flagForcesKeepOnModern() throws {
    let d = doc()
    let out = emitText(d, mode: .modern, options: EmitOptions(sentenceSpacing: .keep))
    #expect(out.contains("hello.  She replied yes!  Then asked why?  I"))
}

@Test func flagForcesSingleOnPrinted() throws {
    let d = doc()
    for fn: (Document, EmitMode, EmitOptions) -> String in [emitText, emitMarkdown, emitRTF] {
        let out = fn(d, .printed, EmitOptions(sentenceSpacing: .single))
        #expect(out.contains(collapsed))
    }
    let htmlOut = emitHTML(d, mode: .printed, options: EmitOptions(sentenceSpacing: .single))
    #expect(htmlOut.contains(collapsedNoApos))
}

@Test func flagForcesSingleOnPrintedPDF() throws {
    let d = doc()
    let keep = emitPDF(d, mode: .printed, options: EmitOptions(sentenceSpacing: .keep))
    let single = emitPDF(d, mode: .printed, options: EmitOptions(sentenceSpacing: .single))
    #expect(keep != single)
}

@Test func flagForcesKeepOnModernPDF() throws {
    let d = doc()
    let defaultSingle = emitPDF(d, mode: .modern)
    let forcedKeep = emitPDF(d, mode: .modern, options: EmitOptions(sentenceSpacing: .keep))
    #expect(defaultSingle != forcedKeep)
}

// --------------------------------------------------------------- not sentence-ending

/// The flag has nothing to say about a double space that does not follow '.', '?', or
/// '!' -- comma included -- in EITHER mode.
@Test func doubleSpaceAfterCommaIsNeverTouched() throws {
    let d = doc("A list: apples,  oranges, and pears.")
    for mode: EmitMode in [.modern, .printed] {
        for ss: EmitOptions.SentenceSpacingMode in [.keep, .single] {
            let out = emitText(d, mode: mode, options: EmitOptions(sentenceSpacing: ss))
            #expect(out.contains("apples,  oranges"))
        }
    }
}

@Test func bareDoubleSpaceWithNoPunctuationIsNeverTouched() throws {
    let d = doc("Two words  apart with no punctuation before the gap.")
    for mode: EmitMode in [.modern, .printed] {
        for ss: EmitOptions.SentenceSpacingMode in [.keep, .single] {
            let out = emitText(d, mode: mode, options: EmitOptions(sentenceSpacing: ss))
            #expect(out.contains("words  apart"))
        }
    }
}

/// Jon's ruling: a simple two-spaces-after-period rule, no cleverness -- "e.g.  " is
/// not special-cased and collapses exactly like a genuine sentence end.
@Test func abbreviationDoubleSpaceCollapsesSameAsARealSentenceEnd() throws {
    let d = doc("See the guide, e.g.  the appendix, for details.")
    let single = emitText(d, mode: .modern)          // auto -> single
    #expect(single.contains("e.g. the appendix"))
    #expect(!single.contains("e.g.  the"))
    let kept = emitText(d, mode: .printed)           // auto -> keep
    #expect(kept.contains("e.g.  the appendix"))
}

// ----------------------------------------------------------- notes text too

@Test func footnoteTextAlsoGetsSentenceSpacing() throws {
    let data = header + bytes("Body")
        + ws7Note(bytes("A note.  With two spaces."), cmd: 0x03, number: 0)
        + bytes(" text.") + HARD
    let d = parseWS(data)
    let single = emitText(d, mode: .modern)
    #expect(single.contains("note. With two spaces."))
    let kept = emitText(d, mode: .printed)
    #expect(kept.contains("note.  With two spaces."))
}

// --------------------------------------------------------------- MD guard

/// The exact hazard the field notes named: a sentence joint landing at a reflowed
/// line's own END. 'keep' does not collapse the double space mid-line, but MUST NOT
/// let a source line's own trailing double space survive as an unintended CommonMark
/// hard break.
@Test func mdGuardStripsTrailingDoubleSpaceEvenInKeepMode() throws {
    let d = doc("First sentence.  Second ends here.  ")
    let out = emitMarkdown(d, mode: .modern, options: EmitOptions(sentenceSpacing: .keep))
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init).filter { !$0.trimmed().isEmpty }
    #expect(!lines.contains { $0.hasSuffix("  ") })
    // the INTERIOR double space (not at line end) is untouched by 'keep'
    #expect(out.contains("sentence.  Second"))
}

@Test func mdGuardHoldsUnderSingleToo() throws {
    let d = doc("First sentence.  Second ends here.  ")
    let out = emitMarkdown(d, mode: .modern, options: EmitOptions(sentenceSpacing: .single))
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init).filter { !$0.trimmed().isEmpty }
    #expect(!lines.contains { $0.hasSuffix("  ") })
    #expect(out.contains("sentence. Second"))
}

/// Inside a fenced code block trailing spaces are inert (no CommonMark construct
/// reads inside one) -- sentence-spacing itself still applies there (inherited from
/// `emitText`'s own printed facsimile).
@Test func mdGuardNeverFiresInPrintedFencedFacsimile() throws {
    let d = doc("First sentence.  Second ends here.  ")
    let out = emitMarkdown(d, mode: .printed)          // auto -> keep
    #expect(out.contains("```"))
    #expect(out.contains("sentence.  Second ends here."))
}

/// A verified verse/stanza unit's own deliberate "  \n" join (Jon's 2026-08-17
/// hard-break ruling) must survive untouched -- the guard only ever removes a
/// coincidence baked into a LINE's own text, never the join the emitter adds on
/// purpose. Same shape as `ModernLintGateTests.swift`'s own `typedParagraphDoc`/
/// `poemLines` (short, 5-space-indented, hard-return-terminated lines in ONE block --
/// what `looksLikeVerse` recognises), with a sentence-ending double space typed at
/// each line's own end.
private func versePoemDoc(_ lines: [String]) -> Document {
    var body: [UInt8] = []
    for (i, line) in lines.enumerated() {
        if i > 0 { body += HARD }
        body += bytes(line)
    }
    body += HARD
    return parseWS(header + body)
}

@Test func mdGuardDoesNotBreakARealVerseHardBreak() throws {
    let poem = versePoemDoc([
        "     Line one ends.  --",
        "     line two ends!  --",
        "     line three closes.  --",
    ])
    for ss: EmitOptions.SentenceSpacingMode in [.keep, .single] {
        let out = emitMarkdown(poem, mode: .modern, options: EmitOptions(sentenceSpacing: ss))
        #expect(out.contains("  \n"), "\(ss): \(out)")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // every join BUT the last line ends in the intentional two-space hard break --
        // no OTHER line (in particular, no line's own trailing typed spaces) survives.
        let trailing = lines.filter { $0.hasSuffix("  ") }
        #expect(trailing.count == 2, "\(ss): \(lines)")
    }
    let singleOut = emitMarkdown(poem, mode: .modern, options: EmitOptions(sentenceSpacing: .single))
    #expect(singleOut.contains("Line one ends. --"))
    let keepOut = emitMarkdown(poem, mode: .modern, options: EmitOptions(sentenceSpacing: .keep))
    #expect(keepOut.contains("line two ends!  --"))
}
