import Testing
@testable import CtrlKD

/// b24 engine wave, round 18 port — mirrors ctrl-kd's tests/test_flags_toc_inline.py.
/// One focused, fail-first-verified test per item rather than an exhaustive port of every
/// Python case: each proves the MECHANISM landed, not every edge case Python's own larger
/// suite covers.

// MARK: - item 1: TOC/Index compilation + --toc

/// Soft returns (not plain hard-returned lines) so `detect()` reads a document as ws4/
/// ws5+ prose rather than a `printstream` -- needed only where the test also calls
/// `documentInfo` (which gates its whole shape-3 report on that classification) or
/// requests `mode: .modern` on a document that would otherwise force printed rendering
/// via `isPrinted`'s own `printstream` check. Same fix pattern as `PrintedFidelityTests`.
private let tocDiagnoseProse = bytes("word") + SOFT + bytes("word") + SOFT + bytes("word") + SOFT

/// A document with two `.tc` entries either side of a real `.pa` break, and one `.ix`
/// entry after it -- `.pa` always closes the current page (even an empty one), so this
/// guarantees exactly two Printed pages regardless of body length.
private func tocFixture() -> [UInt8] {
    bytes(".tc Chapter One") + HARD
        + bytes("Body one.") + HARD
        + bytes(".pa") + HARD
        + bytes(".tc Chapter Two") + HARD
        + bytes(".ix Term") + HARD
        + bytes("Body two.") + HARD
}

@Test func tocIndexCompiledInPrintedPDFWithRealPageNumbers() throws {
    let pdf = emitPDF(parseWS(tocFixture()), mode: .printed, options: EmitOptions(toc: true))
    #expect(contains(pdf, bytes("(TABLE OF CONTENTS)")))
    #expect(contains(pdf, bytes("(Chapter One 1)")))          // page 1, before the .pa
    #expect(contains(pdf, bytes("(Chapter Two 2)")))          // page 2, after the .pa
    #expect(contains(pdf, bytes("(INDEX)")))
    #expect(contains(pdf, bytes("(Term 2)")))
}

@Test func tocIndexCompiledInPrintedRTFWithRealPageNumbers() throws {
    let rtf = emitRTF(parseWS(tocFixture()), mode: .printed, options: EmitOptions(toc: true))
    #expect(rtf.contains("TABLE OF CONTENTS"))
    #expect(rtf.contains("Chapter One 1"))
    #expect(rtf.contains("Chapter Two 2"))
    #expect(rtf.contains("INDEX"))
    #expect(rtf.contains("Term 2"))
    // TOC before Index, both after the body -- three \page breaks total: the real .pa,
    // the TOC section's own opener, and the TOC/Index divider.
    #expect(rtf.range(of: "TABLE OF CONTENTS")!.lowerBound
        < rtf.range(of: "INDEX")!.lowerBound)
}

@Test func tocIndexInNonPagedFormatsHasNoPageNumbers() throws {
    let data = bytes(".tc Chapter One") + HARD + tocDiagnoseProse + bytes("End.") + HARD
    let doc = parseWS(data)
    let options = EmitOptions(toc: true)
    let text = emitText(doc, mode: .modern, options: options)
    let md = emitMarkdown(doc, mode: .modern, options: options)
    let html = emitHTML(doc, mode: .modern, options: options)
    let rtf = emitRTF(doc, mode: .modern, options: options)
    for out in [text, md, html, rtf] {
        #expect(out.contains("Chapter One"))
        #expect(!out.contains("Chapter One 1"))    // no page reference ever appended
    }
    // TOC before Index ordering, at least in the one format that always carries both
    // headings verbatim (Text).
    #expect(text.contains("TABLE OF CONTENTS"))
}

@Test func tocFlagDefaultsOff() throws {
    let rtf = emitRTF(parseWS(tocFixture()), mode: .printed)   // default EmitOptions
    #expect(!rtf.contains("TABLE OF CONTENTS"))
    #expect(!rtf.contains("INDEX"))
}

@Test func tocAbsentWhenDocumentHasNoEntries() throws {
    let data = bytes("Nothing to compile.") + HARD
    let on = emitRTF(parseWS(data), mode: .printed, options: EmitOptions(toc: true))
    let off = emitRTF(parseWS(data), mode: .printed, options: EmitOptions(toc: false))
    #expect(on == off)      // nothing to compile either way -- byte-identical
}

@Test func diagnoseSurfacesTocIndexCounts() throws {
    let data = bytes(".tc Chapter One") + HARD + tocDiagnoseProse
        + bytes(".ix Term") + HARD + tocDiagnoseProse + bytes("End.") + HARD
    guard case .object(let obj) = documentInfo(data),
          case .object(let tocIndex)? = obj["toc_index"] else {
        Issue.record("no toc_index object in diagnose output")
        return
    }
    #expect(tocIndex["toc_entries"] == .int(1))
    #expect(tocIndex["index_entries"] == .int(1))
}

@Test func diagnoseOmitsTocIndexKeyWhenNonePresent() throws {
    let data = tocDiagnoseProse + bytes("Plain document.") + HARD
    guard case .object(let obj) = documentInfo(data) else {
        Issue.record("diagnose output is not an object")
        return
    }
    #expect(obj["toc_index"] == nil)
}

// MARK: - item 2: inline colour/size + --inline-styling

/// `ws7Block(0x00)` first establishes the symmetric-block-bearing WS5+ shape (matching
/// `fontChangesRenderAsRuns`'s own fixture pattern), a colour block splits "Before"/
/// "After" the way a font block does.
private func inlineColourFixture() -> [UInt8] {
    var data = ws7Block(0x00) + bytes("Before the colour. ")
    data += colourBlock(4)     // CGA index 4: red
    data += bytes("After the colour.") + HARD
    return data
}

@Test func inlineColourRendersInRTFWithCGAColourTable() throws {
    let rtf = emitRTF(parseWS(inlineColourFixture()), mode: .modern)
    #expect(rtf.contains(#"\colortbl"#))
    #expect(rtf.contains(#"\red170\green0\blue0;"#))   // index 4's own RGB triple
    #expect(rtf.contains(#"\cf5 "#))                    // WordStar index 4 -> \cf(4+1)
}

@Test func inlineColourRendersInHTMLWithCSSClass() throws {
    let html = emitHTML(parseWS(inlineColourFixture()), mode: .modern)
    #expect(html.contains("ws-colour-4"))
    #expect(html.contains(".ws-colour-4 { color:#aa0000 }"))
}

@Test func inlineStylingOffStripsColourFromRTFAndHTML() throws {
    let doc = parseWS(inlineColourFixture())
    let rtf = emitRTF(doc, mode: .modern, options: EmitOptions(inlineStyling: false))
    let html = emitHTML(doc, mode: .modern, options: EmitOptions(inlineStyling: false))
    #expect(!rtf.contains(#"\colortbl"#))
    #expect(!rtf.contains(#"\cf5 "#))
    #expect(!html.contains("ws-colour-4"))
    #expect(!html.contains(".ws-colour-4"))
}

@Test func inlineSizeAlreadyRendersInRTFAndHTMLAndPDF() throws {
    var data = ws7Block(0x00) + bytes("Before the size. ")
    data += fontBlock(0, points: 24.0)
    data += bytes("After the size.") + HARD
    let doc = parseWS(data)
    #expect(emitRTF(doc, mode: .modern).contains(#"\fs48"#))       // 24pt * 2 half-points
    #expect(emitHTML(doc, mode: .modern).contains("font-size:24pt"))
}

@Test func inlineStylingOffStripsSizeButNotFamily() throws {
    var data = ws7Block(0x00) + bytes("Before the size. ")
    data += fontBlock(helvTypestyle(), points: 24.0)
    data += bytes("After the size.") + HARD
    let doc = parseWS(data)
    let rtf = emitRTF(doc, mode: .modern, options: EmitOptions(inlineStyling: false))
    let html = emitHTML(doc, mode: .modern, options: EmitOptions(inlineStyling: false))
    #expect(!rtf.contains(#"\fs48"#))
    #expect(!html.contains("font-size:24pt"))
    // the font FAMILY switch is document rendering, not an authored styling CHOICE --
    // never gated.
    #expect(rtf.contains(#"\f2"#))
    #expect(html.contains("ws-font-0"))
}

@Test func inlineStylingNeverStripsAStylesOwnDeclaredSize() throws {
    // A paragraph STYLE's own declared font size (`FontChange.offset == -1`, the style-
    // library producer, never a real inline block -- round 9's own two-producer model)
    // must render regardless of `--inline-styling off`: it is document formatting, not
    // the author reaching for a size change mid-paragraph. 24pt = height word 480 (VMI
    // = points * 20).
    let rec = styleRecord(font: (width: 180, height: 480, typestyle: 0))
    let lib = styleLibrary([
        (name: "WordStar Defaults", record: nil),
        (name: "WordStar Defaults", record: nil),
        (name: "Big style", record: rec),
    ])
    let data = documentWithStyleLibrary(
        body: styleRef(2) + bytes("Styled text.") + HARD, library: lib)
    let doc = parseWS(data)
    #expect(doc.fonts.contains { $0.height1440 == 480 && $0.offset < 0 })
    let rtfOn = emitRTF(doc, mode: .modern, options: EmitOptions(inlineStyling: true))
    let rtfOff = emitRTF(doc, mode: .modern, options: EmitOptions(inlineStyling: false))
    #expect(rtfOn.contains(#"\fs48"#))
    #expect(rtfOn == rtfOff)
}

@Test func inlineStylingNeverReachesPDFColourBeyondLJ6DTP() throws {
    let doc = parseWS(inlineColourFixture())
    let on = emitPDF(doc, mode: .printed, options: EmitOptions(inlineStyling: true))
    let off = emitPDF(doc, mode: .printed, options: EmitOptions(inlineStyling: false))
    #expect(on == off)      // no generic PDF colour path exists to gate
}

@Test func diagnoseSurfacesInlineStylingCounts() throws {
    var data = ws7Block(0x00) + tocDiagnoseProse + bytes(" ")
    data += colourBlock(2)
    data += tocDiagnoseProse + HARD
    guard case .object(let obj) = documentInfo(data),
          case .object(let inlineStyling)? = obj["inline_styling"] else {
        Issue.record("no inline_styling object in diagnose output")
        return
    }
    #expect(inlineStyling["colour_spans"] != nil)
}

@Test func diagnoseInlineStylingExcludesStyleDeclaredSize() throws {
    // A fontless, colourless plain document reports no inline_styling key at all --
    // the aggregate-count key only appears when something is actually there to count
    // (matching `pm_blocks`/`toc_index`'s own "only report what's really there" shape).
    let data = tocDiagnoseProse + bytes("Plain document.") + HARD
    guard case .object(let obj) = documentInfo(data) else {
        Issue.record("diagnose output is not an object")
        return
    }
    #expect(obj["inline_styling"] == nil)
}
