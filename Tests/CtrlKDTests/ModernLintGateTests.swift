/// Port of `tests/test_modern_lint.py` (ctrl-kd, the b23 "exports overhaul") — paragraph-
/// assembly fixtures plus the permanent output-quality lint gates Jon's ruling asked for.
/// These are permanent Tier-1 quality gates, not scaffolding: they stay in the suite even
/// after the fixtures that first caught each defect stop being the only way to catch it.
///
/// Synthetic fixtures only, built byte-by-byte, same discipline as `Fixtures.swift`. A
/// corpus-driven pass (`test_lint_gates_over_private_corpus` in Python) is intentionally
/// NOT ported here — this port has no equivalent of `CTRLKD_PRIVATE_FIXTURES` wired to a
/// directory of loose documents; `CTRLKD_PRIVATE_CORPUS` (the `WSChangeTests.swift`
/// convention) is a different, WS-file-specific corpus shape. The synthetic gates below are
/// exactly the regression trip-wires the Python suite documents them as.
import Foundation
import Testing
@testable import CtrlKD

// MARK: - fixture helpers specific to this file's tests

/// A WS5+ document: one Block, `lines` as hard-return-terminated typed paragraphs
/// (manuscript convention — indentation marks a new paragraph, not a blank line). Port of
/// `_typed_paragraph_doc`.
private func typedParagraphDoc(_ lines: [[UInt8]]) -> Document {
    var body: [UInt8] = []
    for (i, line) in lines.enumerated() {
        if i > 0 { body += HARD }
        body += line
    }
    body += HARD
    return parseWS(ws7Block(0x00) + body)
}

/// A WS5+ document whose Blocks are BLANK-LINE delimited — the other real manuscript
/// convention. `blockLinesList` is a list of blocks, each itself a list of hard-terminated
/// line bytestrings. Port of `_para_blocks_doc`.
private func paraBlocksDoc(_ blockLinesList: [[[UInt8]]]) -> Document {
    var body: [UInt8] = []
    for lines in blockLinesList {
        for (i, line) in lines.enumerated() {
            if i > 0 { body += HARD }
            body += line
        }
        body += HARD + HARD
    }
    return parseWS(ws7Block(0x00) + body)
}

private let lintHeader: [UInt8] = [0x70] + [UInt8](repeating: 0, count: 15)

/// A parsed Document whose one styled block uses paragraph style `name`. Port of
/// `_doc_with_style`.
private func docWithStyle(_ name: String, _ record: [UInt8], _ body: [UInt8]) -> Document {
    let lib = styleLibrary([(name: "WordStar Defaults", record: nil),
                            (name: "WordStar Defaults", record: nil),
                            (name: name, record: record)])
    return parseWS(documentWithStyleLibrary(body: styleRef(2) + body, library: lib))
}

/// `n`-visible-character non-terminal, non-quote-opening filler text — a stand-in for a
/// real verse line whose own length happens to fall past the shortness pre-filter. Port of
/// `_filler`.
private func filler(_ n: Int) -> String {
    var out = ""
    while out.count < n { out += "word " }
    return String(out.prefix(n)).trimmedTrailing()
}

// MARK: - regex helpers (test-only; `Sources/` stays Foundation-free, this file does not)

private func regexMatches(_ pattern: String, _ text: String,
                          options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return re.matches(in: text, options: [], range: range)
}

private func group(_ m: NSTextCheckingResult, _ idx: Int, in text: String) -> String? {
    guard idx < m.numberOfRanges else { return nil }
    guard let r = Range(m.range(at: idx), in: text) else { return nil }
    return String(text[r])
}

private func regexSub(_ pattern: String, _ text: String,
                      options: NSRegularExpression.Options = []) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
}

// MARK: - paragraph assembly (rule 2: poems survive; rule 3: no hard breaks inside prose)

@Test func assembleParagraphsShortLinesStayOneUnit() {
    // Calibration fixture for PARAGRAPH_JOIN_SLACK: four deliberately short hard-terminated
    // lines — shaped like a real four-line quotation (longest real line 43 of 65 columns)
    // — must NOT split into separate paragraphs.
    let lines = [bytes("     Line one is short,"), bytes("     line two also short --"),
                bytes("     line three fits the pattern --"), bytes("     line four closes it.")]
    let doc = typedParagraphDoc(lines)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 1)
    #expect(units.reduce(0) { $0 + $1.count } == 4)
}

@Test func assembleParagraphsLongIndentedLinesEachSplit() {
    // A hard-return line that opens with a typed indent AND runs close to the block's own
    // measured margin starts a NEW paragraph.
    let long = String(repeating: "x", count: 58)
    let lines = ["     \(long) one", "     \(long) two", "     \(long) three"].map(bytes)
    let doc = typedParagraphDoc(lines)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 3)
    #expect(units.allSatisfy { $0.count == 1 })
}

@Test func ws4MultiStanzaPoemSurvivesWithNoAttributesOrStyles() {
    let stanza1 = ["Winter light upon the pane", "shadows learning how to fall",
                   "something waits beyond the rain", "patient at the garden wall"]
    let stanza2 = ["Morning comes without a sound", "grey and folded like a page",
                   "footsteps circling worn ground", "marking time against the age"]
    var body: [UInt8] = []
    for stanza in [stanza1, stanza2] {
        for line in stanza { body += bytes("     ") + ws4Text(line) + HARD }
        body += HARD
    }
    let doc = parseWS(body)
    let stanzaBlocks = doc.blocks.filter { $0.kind == .para && !$0.lines.isEmpty }
    #expect(stanzaBlocks.count == 2)
    let margin = docMargin(doc)
    for b in stanzaBlocks {
        let units = assembleParagraphs(b, margin: margin)
        #expect(units.count == 1)
        #expect(units.reduce(0) { $0 + $1.count } == 4)
    }
}

@Test func ws4DialogueRunDoesNotFalsePositiveAsStanza() {
    let lines = ["Wait.", "\"Where are you going?\"", "Nothing here.", "He turned around.",
                "\"I already told you.\"", "Gone."]
    var body: [UInt8] = []
    for l in lines { body += bytes("     ") + ws4Text(l) + HARD }
    let doc = parseWS(body)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 6)
    #expect(units.allSatisfy { $0.count == 1 })
}

@Test func ws4LongLineBoxedInByVerseWidensIntoTheRun() {
    let stanza = ["shadows learning how to fall", "something waits beyond the rain",
                  filler(60), "patient at the garden wall", "marking time against the age"]
    var body: [UInt8] = []
    for l in stanza { body += bytes("     ") + ws4Text(l) + HARD }
    let doc = parseWS(body)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 1)
    #expect(units.reduce(0) { $0 + $1.count } == 5)
}

@Test func ws4LongLineBoxedInByDialogueDoesNotWiden() {
    let lines = ["Wait.", "\"Where are you going?\"", filler(59),
                "\"I already told you.\"", "Gone."]
    var body: [UInt8] = []
    for l in lines { body += bytes("     ") + ws4Text(l) + HARD }
    let doc = parseWS(body)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 5)
    #expect(units.allSatisfy { $0.count == 1 })
}

// MARK: - epigraph handling (convention-outlier detection bounded by document position)

@Test func epigraphAtDocumentHeadBecomesOneStanzaUnit() {
    let epigraph = [bytes("the river does not pause to name itself"),
                    bytes("nor does the field ask why it opens"),
                    bytes("toward whatever light the morning keeps")]
    let body1 = [bytes("     A plain paragraph that behaves exactly as expected here.")]
    let body2 = [bytes("     Another ordinary paragraph continues the story further.")]
    let body3 = [bytes("     A third paragraph closes out this small fixture nicely.")]
    let doc = paraBlocksDoc([epigraph, body1, body2, body3])
    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    #expect(conventionIndent == 5)
    let margin = docMargin(doc)
    let blocks = doc.blocks.enumerated().filter { $0.element.kind == .para && !$0.element.lines.isEmpty }

    let epigraphUnits = assembleParagraphs(blocks[0].element, margin: margin,
                                           headPosition: headPosition[blocks[0].offset] ?? false,
                                           conventionIndent: conventionIndent)
    #expect(epigraphUnits.count == 1)
    #expect(epigraphUnits.reduce(0) { $0 + $1.count } == 3)

    for (bi, b) in blocks.dropFirst() {
        let units = assembleParagraphs(b, margin: margin, headPosition: headPosition[bi] ?? false,
                                       conventionIndent: conventionIndent)
        #expect(units.count == 1 && units[0].count == 1)
    }

    // acceptance, restated across all four Modern formats: 3 source lines -> 1 unit with
    // internal breaks only, everywhere.
    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)
    let md = emitMarkdown(doc, mode: .modern)
    let t = emitText(doc, mode: .modern)
    #expect(countOccurrencesStr("<p", in: h) == 4 && countOccurrencesStr("<br>", in: h) == 2)
    #expect(countOccurrencesStr(#"\line"#, in: r) == 2)
    #expect(countOccurrencesStr("\n\n", in: md) == 3)
    #expect(countOccurrencesStr("\n\n", in: t) == 3)
}

@Test func epigraphAfterChapterHeadingBecomesOneStanzaUnit() {
    let body1 = [bytes("     A plain paragraph that behaves exactly as expected here.")]
    let body2 = [bytes("     Another ordinary paragraph continues the story further.")]
    let chapterHeading = [bytes("     Chapter Two")]
    let chapterEpigraph = [bytes("the river does not pause to name itself"),
                           bytes("nor does the field ask why it opens"),
                           bytes("toward whatever light the morning keeps")]
    let body3 = [bytes("     A third paragraph closes out this small fixture nicely.")]
    var doc = paraBlocksDoc([body1, body2, chapterHeading, chapterEpigraph, body3])
    let blockIndices = doc.blocks.enumerated()
        .filter { $0.element.kind == .para && !$0.element.lines.isEmpty }.map(\.offset)
    doc.blocks[blockIndices[2]].heading = 1     // force heading classification (Chapter Two)

    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    let margin = docMargin(doc)
    #expect(headPosition[blockIndices[3]] == true)   // epigraph reopened by the heading

    let epigraphUnits = assembleParagraphs(doc.blocks[blockIndices[3]], margin: margin,
                                           headPosition: headPosition[blockIndices[3]] ?? false,
                                           conventionIndent: conventionIndent)
    #expect(epigraphUnits.count == 1)
    #expect(epigraphUnits.reduce(0) { $0 + $1.count } == 3)

    for bi in [blockIndices[0], blockIndices[1], blockIndices[4]] {
        let units = assembleParagraphs(doc.blocks[bi], margin: margin,
                                       headPosition: headPosition[bi] ?? false,
                                       conventionIndent: conventionIndent)
        #expect(units.count == 1 && units[0].count == 1)
    }
}

@Test func conventionOutlierMidBodyStaysConservativeUnlessOverwhelming() {
    let body1 = [bytes("     A plain paragraph that behaves exactly as expected here.")]
    let body2 = [bytes("     Another ordinary paragraph continues the story further.")]
    let body3 = [bytes("     A third paragraph closes out this small fixture nicely.")]
    let midbodyConservative = [
        bytes("Quiet now, she said firmly."), bytes("Nobody answered at all."),
        bytes("Then footsteps came again outside."),
        bytes("     He turned back toward the door slowly."),
        bytes("It was already too late for that."),
    ]
    let midbodyStrongOverride = [
        bytes("the wind keeps turning without a name"), bytes("and nothing answers from the field"),
        bytes("until the light comes back again"), bytes("     circling slowly toward the door"),
        bytes("waiting for whatever comes next"),
    ]
    let doc = paraBlocksDoc([body1, body2, midbodyConservative, body3, midbodyStrongOverride])
    let (conventionIndent, headPosition) = paragraphLayoutContext(doc)
    let margin = docMargin(doc)
    let blocks = doc.blocks.enumerated().filter { $0.element.kind == .para && !$0.element.lines.isEmpty }
        .map { ($0.offset, $0.element) }

    let conservative = blocks[2]
    #expect((headPosition[conservative.0] ?? false) == false)
    let units1 = assembleParagraphs(conservative.1, margin: margin,
                                    headPosition: headPosition[conservative.0] ?? false,
                                    conventionIndent: conventionIndent)
    #expect(units1.map(\.count) == [3, 2])

    let override = blocks[4]
    #expect((headPosition[override.0] ?? false) == false)
    let units2 = assembleParagraphs(override.1, margin: margin,
                                    headPosition: headPosition[override.0] ?? false,
                                    conventionIndent: conventionIndent)
    #expect(units2.count == 1)
    #expect(units2.reduce(0) { $0 + $1.count } == 5)
}

// MARK: - all-four-format acceptance (poem preservation / prose splitting)

private let poemLines = [bytes("     Line one is short,"), bytes("     line two also short --"),
                         bytes("     line three fits the pattern --"),
                         bytes("     line four closes it.")]

@Test func modernHTMLPoemStaysOneParagraphWithHardBreaks() {
    let doc = typedParagraphDoc(poemLines)
    let h = emitHTML(doc, mode: .modern)
    #expect(countOccurrencesStr("<p", in: h) == 1)
    #expect(countOccurrencesStr("<br>", in: h) == 3)
    #expect(!h.contains("<pre"))
}

@Test func modernRTFPoemStaysOneParWithLineBreaks() {
    let doc = typedParagraphDoc(poemLines)
    let r = emitRTF(doc, mode: .modern)
    #expect(countOccurrencesStr(#"\par"#, in: r) == 1)
    #expect(countOccurrencesStr(#"\line"#, in: r) == 3)
}

@Test func modernMarkdownPoemStaysOneParagraphWithHardBreaks() {
    let doc = typedParagraphDoc(poemLines)
    let md = emitMarkdown(doc, mode: .modern)
    #expect(countOccurrencesStr("\n\n", in: md) == 0)
    #expect(countOccurrencesStr("  \n", in: md) == 3)
    #expect(!md.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasSuffix("\\") })
}

@Test func modernTextPoemStaysOneParagraphWithLineBreaks() {
    let doc = typedParagraphDoc(poemLines)
    let t = emitText(doc, mode: .modern)
    #expect(countOccurrencesStr("\n\n", in: t) == 0)
    #expect(t.trimmed().filter { $0 == "\n" }.count == 3)
}

@Test func modernProseLinesEachGetOwnParagraph() {
    let long = String(repeating: "x", count: 58)
    let lines = ["     \(long) one", "     \(long) two", "     \(long) three"].map(bytes)
    let doc = typedParagraphDoc(lines)
    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)
    let md = emitMarkdown(doc, mode: .modern)
    let t = emitText(doc, mode: .modern)
    #expect(countOccurrencesStr("<p", in: h) == 3 && !h.contains("<br>"))
    #expect(countOccurrencesStr(#"\par"#, in: r) == 3 && countOccurrencesStr(#"\line"#, in: r) == 0)
    #expect(countOccurrencesStr("\n\n", in: md) == 2 && !md.contains("\\\n"))
    #expect(countOccurrencesStr("\n\n", in: t) == 2)
}

@Test func modernNonVerseMultilineUnitFlowsInAllFourFormats() {
    let lines = [bytes("     Fenn walked slowly to the door and stopped there for a moment."),
                bytes("He turned the handle very carefully and stepped outside into the cold.")]
    let doc = typedParagraphDoc(lines)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 1 && units[0].count == 2)
    let dominant = blockDominantStyles(mergedLines(doc.blocks[0]))
    #expect(!looksLikeVerse(units[0], dominantStyles: dominant))

    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)
    let md = emitMarkdown(doc, mode: .modern)
    let t = emitText(doc, mode: .modern)
    #expect(countOccurrencesStr("<p", in: h) == 1 && !h.contains("<br>"))
    #expect(countOccurrencesStr(#"\par"#, in: r) == 1 && !r.contains(#"\line"#))
    #expect(countOccurrencesStr("\n\n", in: md) == 0 && !md.contains("\\\n"))
    #expect(t.trimmed().filter { $0 == "\n" }.count == 0)
}

@Test func modernFirstLineIndentBecomesPropertyNotLiteralSpaces() {
    let doc = typedParagraphDoc([bytes("     Indented paragraph text here, fine.")])
    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)
    #expect(h.contains("text-indent:5ch"))
    #expect(regexMatches(#"<p[^>]*>\s{2,}"#, h).isEmpty)
    #expect(r.contains(#"\fi720"#))               // 5 cols * 144 twips/col
    #expect(regexMatches(#"\\par [^{}]*\{[^{}]*  "#, r).isEmpty)
}

@Test func modernMarkdownDropsFirstLineIndent() {
    let doc = typedParagraphDoc([bytes("     Indented paragraph text here, fine.")])
    let md = emitMarkdown(doc, mode: .modern)
    #expect(!md.hasPrefix("     "))
    #expect(String(md.drop(while: { $0 == "\n" })).hasPrefix("Indented"))
}

@Test func modernQuoteStyleGetsBlockquotePrefixInMarkdown() {
    let rec = styleRecord(left: 1260, just: 0)
    let body = bytes("A quoted passage of reasonable length for testing purposes.") + HARD
    let doc = docWithStyle("Double-Indented Quote", rec, body)
    #expect(doc.blocks.last?.styleName == "Double-Indented Quote")
    let md = emitMarkdown(doc, mode: .modern)
    #expect(md.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasPrefix("> ") })
}

// MARK: - lint gates (permanent regression trip-wires)

/// Adjacent, byte-identical-style spans surviving in the IR itself — must stay empty;
/// `mergedLines` already calls `coalesceSpans` internally. Port of `_ir_bad_adjacent_spans`.
private func irBadAdjacentSpans(_ doc: Document) -> [(String, String)] {
    var bad: [(String, String)] = []
    for b in doc.blocks {
        for line in mergedLines(b) {
            let spans = line.spans
            guard spans.count >= 2 else { continue }
            for i in 0..<(spans.count - 1) {
                let a = spans[i], c = spans[i + 1]
                if a.styleKey == c.styleKey, !a.styles.contains(.fnref) {
                    bad.append((String(a.text.prefix(24)), String(c.text.prefix(24))))
                }
            }
        }
    }
    return bad
}

/// Every Modern paragraph unit's OWN first line, after `splitLeadingIndent` runs on it, must
/// not still open with a literal 2+-space run. Port of `_ir_bad_paragraph_indent_opens`.
private func irBadParagraphIndentOpens(_ doc: Document) -> [(String?, String)] {
    var bad: [(String?, String)] = []
    let margin = docMargin(doc)
    for b in doc.blocks {
        guard b.kind == .para, b.heading == 0 else { continue }
        for unit in assembleParagraphs(b, margin: margin) {
            let (_, spans) = splitLeadingIndent(unit[0].spans)
            if let first = spans.first, first.text.hasPrefix("  ") {
                bad.append((b.styleName, String(first.text.prefix(40))))
            }
        }
    }
    return bad
}

/// Does paragraph UNIT contain an indented line anywhere but first, and if so, is the unit
/// actually a verified stanza? Port of `_unit_is_glued`.
private func unitIsGlued(_ unit: [Line], _ dominant: StyleKey) -> Bool {
    guard unit.count >= 2 else { return false }
    let interiorIndented = unit.dropFirst().contains { lineVisibleText($0).hasPrefix("     ") }
    return interiorIndented && !looksLikeVerse(unit, dominantStyles: dominant)
}

/// Port of `_ir_glued_indented_paragraphs`.
private func irGluedIndentedParagraphs(_ doc: Document) -> [(String?, [String])] {
    var bad: [(String?, [String])] = []
    let margin = docMargin(doc)
    for b in doc.blocks {
        guard b.kind == .para, b.heading == 0 else { continue }
        let merged = mergedLines(b)
        let dominant = blockDominantStyles(merged)
        for unit in assembleParagraphs(b, margin: margin) {
            if unitIsGlued(unit, dominant) {
                bad.append((b.styleName, unit.map { String(lineVisibleText($0).prefix(30)) }))
            }
        }
    }
    return bad
}

@Test func irGluedIndentedParagraphsGateCatchesRound1Shape() {
    // Round-1 shape: two complete, terminally-punctuated, unstyled prose sentences —
    // decisively NOT verse by every looksLikeVerse signal — with the second glued in as an
    // indented INTERIOR line of the first's unit instead of starting its own.
    let gluedUnit = [
        Line(spans: [Span(text: "     Fenn walked to the door and stopped there.", styles: [])]),
        Line(spans: [Span(text: "     He turned the handle very slowly indeed today.", styles: [])]),
    ]
    #expect(unitIsGlued(gluedUnit, StyleKey()))

    // Companion: a real 2-line stanza, second line indented — must NOT be flagged.
    let verseUnit = [
        Line(spans: [Span(text: "     Winter light upon the pane", styles: [])]),
        Line(spans: [Span(text: "     shadows learning how to fall", styles: [])]),
    ]
    #expect(!unitIsGlued(verseUnit, StyleKey()))
}

/// Modern HTML must carry NO page-width opinion of its own. Port of `_html_bad_geometry`.
private func htmlBadGeometry(_ h: String) -> [String] {
    var bad: [String] = []
    if !regexMatches(#"(?<![-\w])max-width\s*:"#, h).isEmpty { bad.append("max-width declared") }
    if !regexMatches(#"(?<![-\w])width\s*:"#, h).isEmpty { bad.append("width declared") }
    for m in regexMatches(#"margin-(left|right)\s*:\s*([\d.]+)in"#, h) {
        guard let side = group(m, 1, in: h), let numStr = group(m, 2, in: h),
              let num = Double(numStr) else { continue }
        if num > 1.0 { bad.append("margin-\(side):\(numStr)in") }
    }
    return bad
}

/// Modern RTF's stylesheet must carry no `\li`/`\ri` over 1440 twips (1in). Port of
/// `_rtf_bad_geometry`.
private func rtfBadGeometry(_ r: String) -> [String] {
    let matches = regexMatches(#"\{\\stylesheet.*?\}(?=\\paperw)"#, r, options: [.dotMatchesLineSeparators])
    guard let first = matches.first, let sheet = group(first, 0, in: r) else { return [] }
    var bad: [String] = []
    for m in regexMatches(#"\\(li|ri)(\d+)"#, sheet) {
        guard let kind = group(m, 1, in: sheet), let numStr = group(m, 2, in: sheet),
              let num = Int(numStr) else { continue }
        if num > 1440 { bad.append("\\\(kind)\(num)") }
    }
    return bad
}

/// No CONTENT line in Modern Markdown may open with 4+ literal spaces. Port of
/// `_md_deep_indent_lines`.
private func mdDeepIndentLines(_ md: String) -> [String] {
    md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        .filter { $0.hasPrefix("    ") }
}

/// ctrl-kd round 12: an ODD number of trailing backslashes is CommonMark's real
/// hard-break syntax (a single unescaped `\` at end of line, or any unpaired one after
/// however many escaped `\\` pairs precede it) -- still forbidden here. An EVEN number
/// is fully paired escape sequences (`\\` -> one literal backslash character, per
/// CommonMark's own escape rule) -- legitimate CONTENT the emitter escapes at every
/// position (`markdownSpan` and the round-12 fix to the note-definition path), not
/// emitter syntax. A character-reference document whose own lines legitimately end in
/// a literal backslash is exactly this shape: every trailing run is an even,
/// fully-escaped count. Port of `_md_trailing_backslash_lines`.
private func mdTrailingBackslashLines(_ md: String) -> [String] {
    md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        .filter { line in
            var n = 0
            for ch in line.reversed() {
                guard ch == "\\" else { break }
                n += 1
            }
            return n % 2 == 1
        }
}

/// No `</blockquote>` may be immediately followed by a `<blockquote>` across only
/// whitespace. Port of `_html_adjacent_blockquotes`.
private func htmlAdjacentBlockquotes(_ h: String) -> [String] {
    regexMatches(#"</blockquote>\s*<blockquote>"#, h).compactMap { group($0, 0, in: h) }
}

/// Every `<p>`'s own `text-indent` INSIDE one `<blockquote>` must be the same value. Port
/// of `_html_blockquote_indent_variance`.
private func htmlBlockquoteIndentVariance(_ h: String) -> [Set<String>] {
    var bad: [Set<String>] = []
    for m in regexMatches(#"<blockquote>(.*?)</blockquote>"#, h, options: [.dotMatchesLineSeparators]) {
        guard let bq = group(m, 1, in: h) else { continue }
        let indents = Set(regexMatches(#"text-indent:(\d+)ch"#, bq).compactMap { group($0, 1, in: bq) })
        if indents.count > 1 { bad.append(indents) }
    }
    return bad
}

/// `r` with the `\fonttbl` AND `\stylesheet` groups removed. Port of `_rtf_body_only`.
private func rtfBodyOnly(_ r: String) -> String {
    let noFontTbl = regexSub(#"\{\\fonttbl.*?\}(?=\{\\stylesheet|\\paperw)"#, r,
                             options: [.dotMatchesLineSeparators])
    return regexSub(#"\{\\stylesheet.*?\}(?=\\paperw)"#, noFontTbl, options: [.dotMatchesLineSeparators])
}

/// Replay Modern RTF's own body — direct-formatting tokens only — and flag a paragraph
/// whose direct li/ri don't match its referenced style's table margins, or a quote
/// paragraph's own `\fi` outside a sane bound. Port of `_rtf_state_issues`.
private func rtfStateIssues(_ r: String, _ doc: Document, printed: Bool = false) -> [String] {
    var margins: [Int: (li: Int, ri: Int)] = [:]
    var quoteSlots: Set<Int> = []
    for e in doc.styles where e.record != nil {
        margins[e.slot] = rtfStyleMargins(e, printed: printed)
        if isQuoteName(e.name) { quoteSlots.insert(e.slot) }
    }
    let body = rtfBodyOnly(r)
    var li = 0, ri = 0, fi = 0
    var bad: [String] = []
    for m in regexMatches(#"\\li(-?\d+)|\\ri(-?\d+)|\\fi(-?\d+)|\\s(\d+) "#, body) {
        if let s = group(m, 1, in: body), let v = Int(s) { li = v }
        if let s = group(m, 2, in: body), let v = Int(s) { ri = v }
        if let s = group(m, 3, in: body), let v = Int(s) { fi = v }
        if let sTok = group(m, 4, in: body), let sNum = Int(sTok) {
            let slot = sNum - 1
            if let exp = margins[slot] {
                if li != exp.li || ri != exp.ri {
                    bad.append(#"\s\#(sTok): direct(li=\#(li),ri=\#(ri)) != style(\#(exp.li),\#(exp.ri))"#)
                }
                if quoteSlots.contains(slot), abs(fi) > 1440 {
                    bad.append(#"\s\#(sTok): fi=\#(fi) exceeds 1440-twip bound"#)
                }
            }
        }
    }
    return bad
}

private let rtfAttrCtl: [(name: String, style: Style, ctl: String)] = [
    ("b", .bold, #"\b "#), ("i", .italic, #"\i "#), ("u", .underline, #"\ul "#),
    ("sup", .sup, #"\super "#), ("sub", .sub, #"\sub "#), ("strike", .strike, #"\strike "#),
]

/// `body` split into chunks, each ending right after a `\par ` marker. Port of Python's
/// `re.split(r'(?<=\\par )', body)` (a lookbehind split, unavailable directly in NSRegularExpression).
private func splitAfterParMarker(_ body: String) -> [String] {
    let marker = #"\par "#
    var segments: [String] = []
    var searchStart = body.startIndex
    var chunkStart = body.startIndex
    while let r = body.range(of: marker, range: searchStart..<body.endIndex) {
        segments.append(String(body[chunkStart..<r.upperBound]))
        chunkStart = r.upperBound
        searchStart = r.upperBound
    }
    if chunkStart < body.endIndex {
        segments.append(String(body[chunkStart..<body.endIndex]))
    }
    return segments
}

/// Every RUN inside a paragraph that references a stylesheet style must carry that style's
/// OWN declared character attributes as direct control words. Port of
/// `_rtf_missing_run_attrs`.
private func rtfMissingRunAttrs(_ r: String, _ doc: Document) -> [(String, [String], String)] {
    var styleAttrs: [Int: Style] = [:]
    for e in doc.styles where e.record != nil {
        styleAttrs[e.slot] = e.record?.attrs ?? []
    }
    let body = rtfBodyOnly(r)
    var bad: [(String, [String], String)] = []
    for para in splitAfterParMarker(body) {
        guard let m = regexMatches(#"\\s(\d+) "#, para).first, let sTok = group(m, 1, in: para),
              let slot = Int(sTok) else { continue }
        let attrs = styleAttrs[slot - 1] ?? []
        let needed = rtfAttrCtl.filter { attrs.contains($0.style) }
        guard !needed.isEmpty else { continue }
        for rm in regexMatches(#"\{([^{}]*)\}"#, para) {
            guard let run = group(rm, 1, in: para) else { continue }
            guard run.contains(where: { $0.isLetter }) else { continue }
            if run.contains(#"\*\"#) || run.contains(#"\chftn"#) || run.contains(#"\chatn"#)
                || run.contains(#"\atnid"#) || run.contains(#"\footnote"#) || run.contains(#"\annotation"#) {
                continue
            }
            let missing = needed.filter { !run.contains($0.ctl) }.map(\.name)
            if !missing.isEmpty {
                bad.append((sTok, missing, String(run.prefix(40))))
            }
        }
    }
    return bad
}

private let attrSet: Style = [.bold, .italic, .underline, .strike, .sub, .sup]

/// Every character attribute effectively present anywhere in the document — style-declared
/// OR run-toggled, merged via `effectiveSpanStyles`. Port of `_effective_attrs_present`.
private func effectiveAttrsPresent(_ doc: Document) -> Style {
    var present: Style = []
    for b in doc.blocks where b.kind == .para && !b.lines.isEmpty {
        for line in b.lines {
            for sp in line.spans where !sp.styles.contains(.fnref) {
                present.formUnion(effectiveSpanStyles(sp, block: b).intersection(attrSet))
            }
        }
    }
    return present
}

private let attrMarkers: [String: [(name: String, style: Style, markers: [String])]] = [
    "html": [("b", .bold, ["<strong", "font-weight:bold"]), ("i", .italic, ["<em", "font-style:italic"]),
             ("u", .underline, ["<u>"]), ("strike", .strike, ["<s>", "text-decoration:line-through"]),
             ("sub", .sub, ["<sub", "vertical-align:sub"]), ("sup", .sup, ["<sup", "vertical-align:super"])],
    "rtf": [("b", .bold, [#"\b "#]), ("i", .italic, [#"\i "#]), ("u", .underline, [#"\ul "#]),
            ("strike", .strike, [#"\strike "#]), ("sub", .sub, [#"\sub "#]), ("sup", .sup, [#"\super "#])],
    "markdown": [("b", .bold, ["**"]), ("i", .italic, ["*"]), ("strike", .strike, ["~~"]),
                 ("u", .underline, ["<u>"]), ("sub", .sub, ["<sub>"]), ("sup", .sup, ["<sup>"])],
]

/// Attributes in `attrsPresent` with none of their mapped markers anywhere in `rendered`.
/// Port of `_missing_attr_markers`.
private func missingAttrMarkers(_ rendered: String, fmt: String, attrsPresent: Style) -> [String] {
    guard let table = attrMarkers[fmt] else { return [] }
    let body = fmt == "rtf" ? rtfBodyOnly(rendered) : rendered
    return table.filter { attrsPresent.contains($0.style) && !$0.markers.contains { body.contains($0) } }
        .map(\.name)
}

// ------------------------------------------------------- round 6/7 gates (16-18)

/// The RTF vertical-space tokens PRINTED mode is expected to carry: `\sl` per distinct
/// `.lh`-derived leading in force across the document's paragraph blocks, `\fi` per
/// distinct `.pm`-derived first-line indent, and the document-wide `\sb`/`\sa` pair from
/// WordTsar's `.PSA`/`.PSB`. Port of `_rtf_printed_vertical_space_expected`.
private func rtfPrintedVerticalSpaceExpected(_ doc: Document)
    -> (sl: Set<Int>, fi: Set<Int>, sb: Int?, sa: Int?) {
    var margins: [Int: (li: Int, ri: Int)] = [:]
    for e in doc.styles where e.record != nil {
        margins[e.slot] = rtfStyleMargins(e, printed: true)
    }
    var slValues: Set<Int> = []
    var fiValues: Set<Int> = []
    for (bi, b) in doc.blocks.enumerated() where b.kind == .para && !b.lines.isEmpty {
        slValues.insert(rtfSlTwips(rtfBlockLead48(doc, b, bi: bi)))
        if b.paraMargin != nil {
            let li = margins[b.styleID ?? -1]?.li ?? 0
            if let fi = rtfPMFiTwips(b, liTwips: li) { fiValues.insert(fi) }
        }
    }
    let (sb, sa) = rtfDocSpacingTwips(doc)
    return (slValues, fiValues, sb, sa)
}

/// Printed/Native RTF is missing an EXPECTED `\sl`/`\fi`(.pm)/`\sb`/`\sa` direct token —
/// round 6's own acceptance idea. Port of `_rtf_printed_vertical_space_issues`.
private func rtfPrintedVerticalSpaceIssues(_ doc: Document) -> [String] {
    let r = emitRTF(doc, mode: .printed, options: EmitOptions(notes: EmitOptions.allNotes))
    let body = rtfBodyOnly(r)
    func found(_ pattern: String) -> Set<Int> {
        Set(regexMatches(pattern, body).compactMap { group($0, 1, in: body).flatMap(Int.init) })
    }
    let slFound = found(#"\\sl(-?\d+)\\slmult0 "#)
    let fiFound = found(#"\\fi(-?\d+) "#)
    let sbFound = found(#"\\sb(-?\d+) "#)
    let saFound = found(#"\\sa(-?\d+) "#)
    let (slExpected, fiExpected, sbExpected, saExpected) = rtfPrintedVerticalSpaceExpected(doc)
    var bad: [String] = []
    let missingSl = slExpected.subtracting(slFound)
    if !missingSl.isEmpty { bad.append("sl missing \(missingSl)") }
    let missingFi = fiExpected.subtracting([0]).subtracting(fiFound)
    if !missingFi.isEmpty { bad.append("fi(pm) missing \(missingFi)") }
    if let sbExpected, !sbFound.contains(sbExpected) { bad.append("sb \(sbExpected) not in \(sbFound)") }
    if let saExpected, !saFound.contains(saExpected) { bad.append("sa \(saExpected) not in \(saFound)") }
    return bad
}

/// Modern RTF carries NONE of `\sl`/`\sb`/`\sa` — round 6's doctrine: the reader owns
/// presentation there, same as the no-page-width ruling. Port of
/// `_rtf_modern_vertical_space_leak`.
private func rtfModernVerticalSpaceLeak(_ doc: Document) -> [String] {
    let r = emitRTF(doc, mode: .modern)
    var bad: [String] = []
    if r.contains(#"\sl"#), !regexMatches(#"\\sl-?\d+\\slmult0"#, r).isEmpty { bad.append("sl") }
    if !regexMatches(#"\\sb-?\d+[ }]"#, r).isEmpty { bad.append("sb") }
    if !regexMatches(#"\\sa-?\d+[ }]"#, r).isEmpty { bad.append("sa") }
    return bad
}

/// `.aw off` (`block.wrap == false`) must assemble into ONE preserved unit, every line
/// kept — Register C23 (round 7). Port of `_wrap_off_issues`.
private func wrapOffIssues(_ doc: Document) -> [(String, Int, [Int])] {
    let margin = docMargin(doc)
    let (ci, hp) = paragraphLayoutContext(doc)
    var bad: [(String, Int, [Int])] = []
    for (idx, b) in doc.blocks.enumerated() {
        guard b.kind == .para, !b.lines.isEmpty, b.wrap == false else { continue }
        let merged = mergedLines(b)
        let units = assembleParagraphUnits(merged, margin: margin, headPosition: hp[idx] ?? false,
                                           conventionIndent: ci, wrap: b.wrap)
        if units.count != 1 || units.reduce(0, { $0 + $1.count }) != merged.count {
            bad.append((b.styleName ?? "", merged.count, units.map(\.count)))
        }
    }
    return bad
}

/// A wrap=off block never splits into more than one `<p>`/`\par` in Modern HTML/RTF, and
/// every one of its OWN internal line breaks survives as `<br>`/`\line` — the whole block
/// rendered alone (a synthetic single-block document) so the counts are unambiguous. Port
/// of `_wrap_off_rendering_issues`.
private func wrapOffRenderingIssues(_ doc: Document) -> [(String, Int, Int, Int)] {
    var bad: [(String, Int, Int, Int)] = []
    for b in doc.blocks {
        guard b.kind == .para, !b.lines.isEmpty, b.wrap == false else { continue }
        let merged = mergedLines(b)
        guard merged.count >= 2 else { continue }
        var mini = doc
        mini.blocks = [b]
        let expected = merged.count - 1
        let h = emitHTML(mini, mode: .modern)
        let pCount = countOccurrencesStr("<p", in: h)
        let brCount = countOccurrencesStr("<br>", in: h)
        if pCount != 1 || brCount != expected { bad.append(("html", pCount, brCount, expected)) }
        let r = emitRTF(mini, mode: .modern)
        let parCount = countOccurrencesStr(#"\par"#, in: r)
        let lineCount = countOccurrencesStr(#"\line"#, in: r)
        if parCount < 1 || lineCount != expected { bad.append(("rtf", parCount, lineCount, expected)) }
    }
    return bad
}

/// Renders all four Modern formats (also the corpus smoke test — every real fixture must
/// convert without crashing) and checks every permanent lint gate. Port of
/// `_assert_lint_gates`.
private func assertLintGates(_ name: String, _ doc: Document) {
    let allNotes = EmitOptions(notes: EmitOptions.allNotes)
    let h = emitHTML(doc, mode: .modern, options: allNotes)
    let r = emitRTF(doc, mode: .modern, options: allNotes)
    let md = emitMarkdown(doc, mode: .modern, options: allNotes)
    _ = emitText(doc, mode: .modern, options: allNotes)

    #expect(htmlBadGeometry(h).isEmpty, "\(name): html page-width/geometry leak \(htmlBadGeometry(h))")
    #expect(rtfBadGeometry(r).isEmpty, "\(name): rtf geometry over 1in \(rtfBadGeometry(r))")
    #expect(mdDeepIndentLines(md).isEmpty,
           "\(name): markdown deep indent \(mdDeepIndentLines(md).prefix(5))")
    #expect(mdTrailingBackslashLines(md).isEmpty,
           "\(name): markdown trailing backslash \(mdTrailingBackslashLines(md).prefix(5))")
    #expect(htmlAdjacentBlockquotes(h).isEmpty, "\(name): adjacent blockquotes")
    #expect(htmlBlockquoteIndentVariance(h).isEmpty,
           "\(name): blockquote text-indent variance \(htmlBlockquoteIndentVariance(h))")
    #expect(rtfStateIssues(r, doc, printed: false).isEmpty,
           "\(name): rtf direct-formatting gap \(rtfStateIssues(r, doc, printed: false))")
    #expect(rtfMissingRunAttrs(r, doc).isEmpty,
           "\(name): rtf run missing style attr \(rtfMissingRunAttrs(r, doc).prefix(5))")

    let attrsPresent = effectiveAttrsPresent(doc)
    if !attrsPresent.isEmpty {
        for (fmt, rendered) in [("html", h), ("rtf", r), ("markdown", md)] {
            let missing = missingAttrMarkers(rendered, fmt: fmt, attrsPresent: attrsPresent)
            #expect(missing.isEmpty, "\(name): \(fmt) attribute mapping missing \(missing)")
        }
    }

    // 16. Modern RTF carries none of \sl/\slmult/\sb/\sa (round 6: the reader owns
    //     presentation, same doctrine as no-page-width)
    let modernLeak = rtfModernVerticalSpaceLeak(doc)
    #expect(modernLeak.isEmpty, "\(name): modern rtf vertical-space leak \(modernLeak)")
    // 17. Printed/Native RTF carries every EXPECTED \sl/\fi(.pm)/\sb/\sa direct token
    //     (round 6)
    let printedVSIssues = rtfPrintedVerticalSpaceIssues(doc)
    #expect(printedVSIssues.isEmpty, "\(name): printed rtf vertical-space gap \(printedVSIssues)")
    // 18. wrap=off (.aw off) blocks assemble into ONE preserved unit, every line kept —
    //     Register C23 (round 7)
    let wrapIssues = wrapOffIssues(doc)
    #expect(wrapIssues.isEmpty, "\(name): wrap=off split \(wrapIssues)")
    let wrapRenderIssues = wrapOffRenderingIssues(doc)
    #expect(wrapRenderIssues.isEmpty, "\(name): wrap=off rendering \(wrapRenderIssues)")

    #expect(irBadAdjacentSpans(doc).isEmpty, "\(name): un-coalesced adjacent spans")
    #expect(irBadParagraphIndentOpens(doc).isEmpty, "\(name): paragraph-opening indent")
    #expect(irGluedIndentedParagraphs(doc).isEmpty, "\(name): indented line glued mid-paragraph")

    if doc.detection?.variant != .printstream, !doc.columnar {
        #expect(!h.contains("<pre"), "\(name): modern html used <pre>")
    }
    #expect(!h.contains("--ws-typestyle"), "\(name): ws-typestyle leak")

    for m in regexMatches(#"<h[1-3][^>]*>(.*?)</h[1-3]>"#, h, options: [.dotMatchesLineSeparators]) {
        guard let inner = group(m, 1, in: h) else { continue }
        let bad = inner.hasPrefix(" ") || inner.hasPrefix("&nbsp;")
        #expect(!bad, "\(name): heading leading alignment padding \(String(group(m, 0, in: h)?.prefix(80) ?? ""))")
    }
}

@Test func lintGatesOnDoubleCenteredHeadingSyntheticRegression() {
    let data = ws7Block(0x00, payload: lintHeader) + bytes(".oc on\r\n")
        + bytes("     Title Text Here") + HARD + bytes(".oc off\r\n")
    var doc = parseWS(data)
    doc.blocks[0].heading = 1              // force heading classification
    _ = emitHTML(doc, mode: .modern)
    assertLintGates("synthetic-centered-heading", doc)
}

@Test func round3GeometryNormalizationAndQuoteDistinction() {
    let quoteRec = styleRecord(left: 10440, just: 0, right: 10440)     // 5.8in each side
    let lib = styleLibrary([(name: "WordStar Defaults", record: nil),
                            (name: "WordStar Defaults", record: nil),
                            (name: "Double-Indented Quote", record: quoteRec)])
    let body = bytes("     An ordinary body paragraph with plenty of text in it.") + HARD
        + styleRef(2) + bytes("A quoted passage that must read as visibly different from body.") + HARD
        + styleRef(1) + bytes("     Back to an ordinary body paragraph to close things out.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    assertLintGates("synthetic-quote-geometry", doc)

    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)
    let t = emitText(doc, mode: .modern)
    let md = emitMarkdown(doc, mode: .modern)

    #expect(h.contains("<blockquote>") && h.contains("</blockquote>"))
    #expect(!h.contains("5.8") && !h.contains("in;") && !h.contains("in\""))
    #expect(htmlBadGeometry(h).isEmpty)

    #expect(r.contains(#"\li720\ri720"#))
    #expect(rtfBadGeometry(r).isEmpty)

    let quoteLine = t.split(separator: "\n").first { $0.contains("quoted passage") }
    #expect(quoteLine?.hasPrefix("    ") == true && quoteLine?.hasPrefix("     ") == false)

    #expect(md.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.hasPrefix("> ") })
    #expect(mdDeepIndentLines(md).isEmpty)
}

@Test func round4QuoteGroupMergesAcrossStylesAndUnits() {
    let quoteRec = styleRecord(left: 1260, just: 0)
    let creditRec = styleRecord(left: 1260, just: 0)
    let lib = styleLibrary([(name: "WordStar Defaults", record: nil),
                            (name: "WordStar Defaults", record: nil),
                            (name: "Double-Indented Quote", record: quoteRec),
                            (name: "MS Quote Credit", record: creditRec)])
    // Lines run long enough (well past `classifyRows`'s own centered-via-spaces slack
    // bound, `Layout.swift`'s pre-existing job284 structure-rule heuristic) that none of
    // them coincidentally reads as an untagged centered line — a false positive there
    // would bypass this block's own quote-continuity/paragraph-assembly path entirely
    // (it renders straight to `builder.addText`, never touching `quoteBuffer`), which is
    // a confound this test must not have: it exists to prove quote-group continuity, not
    // to also exercise the separately-tracked, already-documented structure-rules-vs-
    // oracle gap.
    let body = styleRef(2)
        + bytes("      First quoted paragraph carries real sentence text.") + HARD
        + bytes("         Second quoted paragraph typed at a different depth.") + HARD
        + HARD
        + styleRef(3)
        + bytes("     Attribution credit line follows immediately after the quotation ends.") + HARD
        + HARD
        + styleRef(1)
        + bytes("     An ordinary body paragraph comes after the quote group and closes it out.") + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))

    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)

    #expect(countOccurrencesStr("<blockquote", in: h) == 1)
    let bqMatch = regexMatches(#"<blockquote>(.*?)</blockquote>"#, h, options: [.dotMatchesLineSeparators]).first
    let bq = bqMatch.flatMap { group($0, 1, in: h) } ?? ""
    #expect(countOccurrencesStr("<p", in: bq) == 3)
    let indents = Set(regexMatches(#"text-indent:(\d+)ch"#, bq).compactMap { group($0, 1, in: bq) })
    #expect(indents.count == 1)
    #expect(htmlAdjacentBlockquotes(h).isEmpty)
    #expect(htmlBlockquoteIndentVariance(h).isEmpty)

    #expect(rtfStateIssues(r, doc, printed: false).isEmpty)
    #expect(countOccurrencesStr(#"\li720\ri720"#, in: r) >= 1)
}

@Test func round5StyleLevelBoldReachesMarkdownAndRTFRuns() {
    let rec = styleRecord(just: -1, attrsOn: 0b11000000)      // bold + italic
    let lib = styleLibrary([(name: "WordStar Defaults", record: nil),
                            (name: "WordStar Defaults", record: nil),
                            (name: "Award Citation", record: rec)])
    let body = styleRef(2) + [0x19] + bytes("Honored for outstanding service to the community.") + [0x19] + HARD
    let doc = parseWS(documentWithStyleLibrary(body: body, library: lib))
    #expect(doc.blocks[0].styleAttrs == [.bold, .italic])

    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)
    let md = emitMarkdown(doc, mode: .modern)

    #expect(h.contains("font-weight:bold") && h.contains("font-style:italic"))
    #expect(rtfMissingRunAttrs(r, doc).isEmpty)
    #expect(r.contains(#"\b \i "#) || r.contains(#"\i \b "#))
    #expect(md.contains("***Honored"))
}

@Test func round12ContentBackslashSurvivesMarkdownUnescapedAsBreak() {
    // ctrl-kd round 12 (a character-code reference document -- the same self-
    // documenting class as LJ6DTP/SCRIPT.WS/LAYOUT.WS -- whose own lines legitimately
    // end in a literal backslash, e.g. explaining what a byte displays as):
    // `markdownSpan` already doubles every content backslash (`\` -> `\\`), which
    // CommonMark's own escape rule reads back as ONE literal backslash character, not
    // a break. The gate itself (`mdTrailingBackslashLines`) is fixed the same round: it
    // now counts trailing backslashes and flags only an ODD count (a real unescaped
    // break marker) -- an even, fully-paired count is legal escaped content.
    let doc = typedParagraphDoc([bytes("     Byte 92 displays on screen as a literal backslash: \\")])
    let md = emitMarkdown(doc, mode: .modern)
    #expect(mdTrailingBackslashLines(md).isEmpty)
    // the escaped pair survives as visible text, not vanished into syntax
    #expect(md.contains("\\\\"))
}

@Test func round12NoteTextBackslashEscapedInDefinition() {
    // ctrl-kd round 12: a note's own text is embedded verbatim in its Markdown
    // footnote-style definition -- the ONE path in this emitter that bypassed
    // `markdownSpan` entirely, so a content backslash anywhere in a note (mid-word or
    // trailing) reached CommonMark unescaped. Reproduced directly: a footnote whose
    // text contains a backslash mid-sentence.
    var data = ws7Block(0x00) + bytes("A claim needing a citation")
    data += ws7Note(bytes(#"See the C:\WS\NOTES.TXT file for detail."#), number: 0)
    data += bytes(" follows on.") + HARD
    let doc = parseWS(data)
    let md = emitMarkdown(doc, mode: .modern, options: EmitOptions(notes: EmitOptions.allNotes))
    let definition = md.split(separator: "\n", omittingEmptySubsequences: false)
        .first { $0.hasPrefix("[^1]:") }
    #expect(definition?.contains(#"C:\\WS\\NOTES.TXT"#) == true)   // doubled, not raw
    #expect(mdTrailingBackslashLines(md).isEmpty)
}

@Test func round6DoubleSpacedSourceOpensDoubleSpacedInPrintedRTF() {
    // Direct regression test for round 6 (2026-08-17): a document whose own `.lh`
    // doubles the default leading (16/48in vs the default 8/48in) must open double-
    // spaced in Printed/Native RTF -- Jon's own acceptance idea, verbatim. `.pm`
    // (paragraph margin -- WSFORMAT semantics: "the first line's own indent") lands as
    // `\fi`, relative to whatever `\li` is already in force (round 4's own style-margin
    // mechanism; 0 here, no style). Modern RTF gets NONE of it -- the reader owns
    // presentation there, same doctrine as the no-page-width ruling (round 3).
    let doc = parseWS(ws7Block(0x00, payload: lintHeader)
        + bytes(".lh 16\r\n.pm 10\r\n")
        + bytes("Some paragraph text set at double leading.") + HARD)
    #expect(doc.page?.lh48 == 16.0)
    // `.pm 10` -- column 10, 1-based like `.lm`/`.po` (b26 fix) -- normalizes to 9.0
    // offset columns.
    #expect(doc.blocks[0].paraMargin == 9.0)

    let rPrinted = emitRTF(doc, mode: .printed)
    #expect(rPrinted.contains(#"\sl-480\slmult0"#))      // 16 * 30 twips/48in-unit, doubled
    #expect(rPrinted.contains(#"\fi1296"#))               // 9 cols * 144 twips/col, li=0

    let rModern = emitRTF(doc, mode: .modern)
    #expect(rtfModernVerticalSpaceLeak(doc).isEmpty)
    #expect(!rModern.contains(#"\sl"#))
    #expect(rtfPrintedVerticalSpaceIssues(doc).isEmpty)
}

@Test func round6PsaPsbLandAsDirectSbSaInPrintedRTF() {
    // Direct regression test for round 6: WordTsar's own `.PSA`/`.PSB` extensions
    // (never a real WordStar 4/5/7 command -- their presence IS the producer signal
    // already recorded) build the MINIMAL model the ruling asked for: one document-
    // wide value each, applied uniformly to every printed paragraph and converted to
    // twips via the document's own default leading -- the same unit `\sl` itself uses.
    // Modern RTF and every other format stay untouched.
    let doc = parseWS(ws7Block(0x00, payload: lintHeader)
        + bytes(".PSB 1\r\n.PSA 2\r\n")
        + bytes("A paragraph with WordTsar spacing before and after.") + HARD)
    #expect(doc.producer == "wordtsar")
    #expect(doc.spaceBeforeLines == 1.0)
    #expect(doc.spaceAfterLines == 2.0)

    let rPrinted = emitRTF(doc, mode: .printed)
    #expect(rPrinted.contains(#"\sb240 "#))               // 1 line * 240 twips (default lead)
    #expect(rPrinted.contains(#"\sa480 "#))               // 2 lines * 240 twips
    #expect(rtfPrintedVerticalSpaceIssues(doc).isEmpty)

    let rModern = emitRTF(doc, mode: .modern)
    #expect(rtfModernVerticalSpaceLeak(doc).isEmpty)
    #expect(!rModern.contains(#"\sb"#) && !rModern.contains(#"\sa"#))

    // the other three Modern formats never had a spacing concept to lose -- confirmed
    // unaffected by rendering cleanly, matching every other gate
    let h = emitHTML(doc, mode: .modern)
    let md = emitMarkdown(doc, mode: .modern)
    let t = emitText(doc, mode: .modern)
    #expect(!h.trimmed().isEmpty && !md.trimmed().isEmpty && !t.trimmed().isEmpty)
}

@Test func round7WrapOffBlockNeverSplitsInAnyModernFormat() {
    // Direct regression test for round 7 (2026-08-17): a REGRESSION the register
    // re-audit found in this whole overhaul -- `.aw off` (`block.wrap == false`) was
    // honored before paragraph assembly existed (Modern simply never reflowed anything
    // back then), but the new paragraph-assembly path never learned to check it, so a
    // hand-positioned block could get torn apart at its own column headers. The classic
    // case: a small table, one row typed flush (its own header) then a row typed with a
    // stray 5-space indent -- phase 1's own "indent starts a new paragraph" rule
    // (correct for ordinary prose) would otherwise split the header from the rows it's
    // paired with. Fixed: the whole block is ONE preserved unit, every line kept, in
    // all four Modern formats -- Register C23, same family as verse (deliberate line
    // positions survive).
    let doc = parseWS(ws7Block(0x00, payload: lintHeader)
        + bytes(".aw off\r\n")
        + bytes("Name          Score") + HARD
        + bytes("     Alice          95") + HARD
        + bytes("Bob             87") + HARD)
    #expect(doc.blocks[0].wrap == false)
    let margin = docMargin(doc)
    let units = assembleParagraphs(doc.blocks[0], margin: margin)
    #expect(units.count == 1 && units.reduce(0) { $0 + $1.count } == 3, "\(units.map(\.count))")
    #expect(wrapOffIssues(doc).isEmpty)
    #expect(wrapOffRenderingIssues(doc).isEmpty)

    let h = emitHTML(doc, mode: .modern)
    let r = emitRTF(doc, mode: .modern)
    let md = emitMarkdown(doc, mode: .modern)
    let t = emitText(doc, mode: .modern)
    #expect(countOccurrencesStr("<p", in: h) == 1 && countOccurrencesStr("<br>", in: h) == 2)
    #expect(countOccurrencesStr(#"\par"#, in: r) == 1 && countOccurrencesStr(#"\line"#, in: r) == 2)
    #expect(countOccurrencesStr("\n\n", in: md) == 0 && countOccurrencesStr("  \n", in: md) == 2)
    #expect(countOccurrencesStr("\n\n", in: t) == 0)
    #expect(countOccurrencesStr("\n", in: t.trimmed()) == 2)
}

// MARK: - helpers

private func countOccurrencesStr(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let r = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = r.upperBound..<haystack.endIndex
    }
    return count
}
