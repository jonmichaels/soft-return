import Testing
@testable import CtrlKD

/// job-013: the exact-fill blank sheet, finally fixed.
///
/// The bug's whole history in one place, because the shape of it is the interesting part:
///
/// 1. **job-011** found it. Modern mode ends every block with a blank line, so content that
///    exactly fills a page spills that blank onto page 2, and the per-page trailing-blank
///    strip then empties page 2 — leaving a real, empty final page. `emitPDF` turns it into a
///    sheet of paper with nothing on it.
/// 2. **Python 1.1.5** fixed it in the wrong place: the pop ran *before* the stripping, so it
///    looked at a page that still had a positive line count and skipped it.
/// 3. **job-012** found *that* — and found that 1.1.5's new test could not fail, because it
///    fed `parse_ws` bytes that `detect` classifies as a print stream, which reach one page by
///    an entirely different route.
/// 4. **Python 1.1.6** moved the pop after the stripping and rewrote the test around real WS4
///    bytes through `parse()`. That is what this file pins.
///
/// The lesson worth keeping is step 3: a fix and a test can both be *present*, both look
/// right, and still neither of them touch the behavior they name. The test that would have
/// caught it is the one below whose input is proven to reach the branch.

// MARK: - the other pop path (port of Python 1.1.6's new named test)

@Test func pdfTrailingDoublePageBreakNoBlankSheet() {
    // Port of `test_pdf_trailing_double_pagebreak_no_blank_sheet`. Trailing `.pa .pa` appends
    // a page that is empty on its own, with no stripping needed — so unlike the exact-fill
    // case it was already popped correctly at 1.1.5. It is here as the pop's other half:
    // together the two prove the pop handles a page that starts empty AND a page that only
    // becomes empty.
    let data = bytes("Page one text here.") + HARD + bytes(".pa") + HARD + bytes(".pa") + HARD
    let pages = docToPagelines(parseWS(data), printed: false)
    #expect(pages.allSatisfy { !$0.isEmpty }, "page line counts: \(pages.map(\.count))")

    // Interior blank pages from `.pa .pa` BETWEEN content are preserved — the pop takes only
    // the last page, and a deliberate blank sheet mid-document is the author's layout.
    let data2 = bytes("One.") + HARD + bytes(".pa") + HARD + bytes(".pa") + HARD
        + bytes("Two.") + HARD
    #expect(docToPagelines(parseWS(data2), printed: false).map { !$0.isEmpty }
            == [true, false, true])
}

@Test func everyTrailingBlankPageIsPoppedNotJustTheLast() {
    // The pop is a `while`, and the loop matters: three or more trailing `.pa` append more
    // than one empty page, and an `if` would leave all but the first behind. Found by the
    // job-013 mutation run — `layout-pop-once-not-while` survived the six new vectors and
    // every prior test, because nothing in either suite had ever put two empty pages at the
    // end of a document.
    //
    // Ground truth from the reference at 1.1.6: one page for any number of trailing breaks,
    // checked for n = 1 through 4 in both modes.
    for n in 1...4 {
        var data = bytes("Page one.") + HARD
        for _ in 0..<n {
            data += bytes(".pa") + HARD
        }
        let doc = parseWS(data)
        #expect(docToPagelines(doc, printed: false).map(\.count) == [1], "\(n) trailing .pa, modern")
        #expect(docToPagelines(doc, printed: true).map(\.count) == [1], "\(n) trailing .pa, printed")
    }
}

// MARK: - the fixture that proved the bug, now proving the fix

@Test func exactFillNoLongerReachesPaper() {
    // These are job-012's bytes, kept verbatim from the test that recorded the bug, because a
    // regression test is worth most when it is the exact input that once failed.
    //
    // A WS4 document — the high bit on each word's last letter means `detect` does NOT say
    // printstream, so this takes the modern path through `emitPDF` where the blank sheet was
    // visible in the file. At 1.1.5 this produced two `/Type /Page` objects, the second with a
    // zero-length content stream.
    var ws4: [UInt8] = []
    for i in 0..<26 {
        ws4 += ws4Text("Paragraph \(i) here.") + HARD + HARD
    }
    ws4 += ws4Text(String(repeating: "W", count: 60) + " " + String(repeating: "X", count: 40))
        + HARD + HARD
    let doc = parseWS(ws4)
    #expect(doc.detection?.variant == .ws4, "fixture must not be detected as a printstream")
    #expect(!isPrinted(doc), "…so emitPDF takes the modern path")

    // Was [54, 0] at 1.1.5. The 54 must still be there: the fix removes the empty page, it
    // does not lose a line of content off the end of the full one. `docToPagelines` itself
    // is UNCHANGED by the Modern-PDF rewrite (ruling 2026-08-05) — Python keeps its own
    // `_doc_to_pagelines`'s modern branch as dead code the same way, since `_emit_pdf_inner`
    // no longer calls it for Modern — so this half of the regression test still pins the
    // original bug fix exactly.
    #expect(docToPagelines(doc, printed: false).map(\.count) == [54])

    // `emitPDF(mode: .modern)` no longer goes through `docToPagelines` at all (it dispatches
    // to `modernStreams`'s proportional reflow instead), so the PAGE COUNT below is not the
    // same "54" — 14pt Times at 1.2x leading needs more vertical room per line than the old
    // fixed 65-col/54-line Courier grid did for the same text, and this fixture is now long
    // enough to spill onto a second page. What must still hold, and is what this test
    // actually guards against, is the ORIGINAL bug: no spurious trailing blank sheet — the
    // same trailing-empty-page trim (`while pages.count > 1 && ... .isEmpty`) protects the
    // new engine too.
    let pdf = emitPDF(doc, mode: .modern)
    #expect(countOccurrences(of: bytes("/Type /Page "), in: pdf) == 2)
    #expect(contains(pdf, bytes("/Count 2")))
    #expect(!contains(pdf, bytes("<< /Length 0 >>\nstream\n\nendstream")),
            "the blank sheet, gone from the bytes")
}

@Test func exactFillPrintstreamPathAlsoLosesItsBlankSheet() {
    // The other route into the same bug, and the one the job-012 vectors pinned: plain text
    // with hard returns, which `detect` calls a print stream. `parse()` on these bytes gave
    // [53, 0] at 1.1.5 — the `exact_fill_no_blank_sheet/modern` vector is that number, which
    // is why moving the pop made a job-012 vector stale (see `layoutUpdatesMatchPython116`).
    let n = (PDFMetrics.linesModern + 1) / 2
    var data: [UInt8] = []
    for i in 0..<n {
        data += bytes("Paragraph \(i) here.") + HARD + HARD
    }
    #expect(try! docToPagelines(parse(data), printed: false).map(\.count) == [53])
}

// MARK: - the pop's position is the whole fix

@Test func popRunsAfterStrippingNotBefore() {
    // The one assertion that distinguishes 1.1.6 from 1.1.5 at the level of the code rather
    // than an input: a final page whose lines are all blank is only empty AFTER stripping, so
    // a pop placed before it cannot see it. Built by hand so the reachability is visible in
    // the test instead of inferred from a byte fixture — an explicit page break, then a block
    // of nothing but blank lines.
    //
    // If the pop moves back above the stripping loop, this is the test that says so.
    let doc = Document(blocks: [
        Block(lines: [Line(spans: [Span(text: "content")])]),
        Block(kind: .pagebreak),
        Block(lines: [Line(spans: [Span(text: "   ")]), Line(spans: [Span(text: "")])]),
    ])
    // Printed mode: no reflow, so the blank lines land on page 2 exactly as written, and only
    // the trailing-blank strip empties it.
    let pages = docToPagelines(doc, printed: true)
    #expect(pages.count == 1, "page line counts: \(pages.map(\.count))")
    #expect(pages[0].count == 1)
}
