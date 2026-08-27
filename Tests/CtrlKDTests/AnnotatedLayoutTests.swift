import Foundation
import Testing
@testable import CtrlKD

/// Show Invisibles, part 1/4 (job 255): `annotatedLayout`'s five invisible-ink classes.
/// Synthetic fixtures exercise each class in isolation; the corpus gauntlet at the
/// bottom runs OLDTIMES.WS/LJ6DTP.WS/BOX.WS when the private archive is present and
/// passes vacuously otherwise, same convention as every other corpus test in this suite.
///
/// Byte fixtures are built as `var data = ...; data += ...` in short steps rather than
/// one long chained `+` expression — a handful of spots elsewhere in this suite
/// (WriterTests.swift, ModernRulingsTests.swift) skip that convention and time out this
/// toolchain's type-checker; this file follows it throughout so it doesn't join them.

/// Concatenate every `.visible`-kind span's text, across every line — what a viewer
/// ignoring all invisible ink reconstructs.
private func visibleText(_ doc: AnnotatedDocument) -> String {
    let visibleSpans = doc.lines.flatMap { $0.spans }.filter { $0.kind == .visible }
    return visibleSpans.map(\.text).joined()
}

private func dotCommandTexts(_ doc: AnnotatedDocument) -> [String] {
    let spans = doc.lines.flatMap { $0.spans }.filter { $0.kind == .dotCommand }
    return spans.map(\.text)
}

private func commentTexts(_ doc: AnnotatedDocument) -> [String] {
    let spans = doc.lines.flatMap { $0.spans }.filter { $0.kind == .comment }
    return spans.map(\.text)
}

private func styleToggleTokens(_ doc: AnnotatedDocument) -> [String] {
    doc.lines.flatMap { $0.spans }.compactMap {
        if case .styleToggle(let token) = $0.kind { return token }
        return nil
    }
}

// ------------------------------------------------------------ dot commands

@Test func dotCommandsBecomeTheirOwnAnnotatedLines() {
    // Same shape as WriterTests's `dotLinesBetweenParagraphsKeepPosition`: two dot
    // commands sit between two paragraphs, at their own document position.
    var data = bytes("First paragraph.")
    data += HARD
    data += HARD
    data += bytes(".lm 8\r\n.rm 65\r\n")
    data += bytes("Indented paragraph.")
    data += HARD
    data += [0x1A]
    let doc = parseWS(data)
    let annotated = annotatedLayout(doc)

    #expect(dotCommandTexts(annotated) == [".lm 8", ".rm 65"])
    let plain = doc.iterLines().map { $0.text() }.joined()
    #expect(visibleText(annotated) == plain)
}

// ------------------------------------------------------------ comments

@Test func commentsSurfaceInlineBesideTheirReferenceMark() {
    var data = bytes(".he Running head with #  \r\n")
    data += bytes(".. a comment the printer never sees\r\n")
    data += bytes(".ig another comment form\r\n")
    data += bytes("Body text here.")
    data += HARD
    data += ws7Block(0x0B, payload: [0, 0, 0, 0])
    data += [0x1A]
    let doc = parseWS(data)
    let noteKinds = doc.notes.map(\.kind)
    #expect(noteKinds == [NoteKind.comment, NoteKind.comment])
    let annotated = annotatedLayout(doc)

    let expectedComments = ["a comment the printer never sees", "another comment form"]
    #expect(commentTexts(annotated) == expectedComments)
    // The reference marks WordStar itself shows (the small "1"/"2") are still there,
    // unedited, under .visible — this feature only ever ADDS spans.
    let visible = visibleText(annotated)
    #expect(visible.contains("1"))
    #expect(visible.contains("2"))
    let plain = doc.iterLines().map { $0.text() }.joined()
    #expect(visible == plain)
}

// ------------------------------------------------------------ style toggles

@Test func styleTogglesMarkBoldAndItalicBoundaries() {
    var data = bytes("plain ")
    data += [0x02]
    data += bytes("bold")
    data += [0x02]
    data += bytes(" and ")
    data += [0x19]
    data += bytes("italic")
    data += [0x19]
    data += bytes(" done")
    data += HARD
    data += [0x1A]
    let doc = parseWS(data)
    let annotated = annotatedLayout(doc)

    #expect(styleToggleTokens(annotated) == ["^B", "^B", "^Y", "^Y"])
    let plain = doc.iterLines().map { $0.text() }.joined()
    #expect(visibleText(annotated) == plain)
}

// ------------------------------------------------------------ soft/hard returns

@Test func endMarksReflectSoftVersusHardReturns() {
    var data = bytes(String(repeating: "x", count: 55) + " words")
    data += SOFT
    data += bytes("ends here.")
    data += HARD
    data += [0x1A]
    let doc = parseWS(data)
    let annotated = annotatedLayout(doc)
    let realLines = annotated.lines.filter { !$0.spans.isEmpty }

    #expect(realLines.count == 2)
    #expect(realLines[0].endMark == .softReturn)
    #expect(realLines[1].endMark == .hardReturn)
}

// ------------------------------------------------------------ page-break origin

@Test func explicitAndConditionalPageBreaksCarryTheirDotText() {
    var data = bytes("Page one.")
    data += HARD
    data += bytes(".pa\r\n")
    data += bytes("Page two.")
    data += HARD
    data += bytes(".cp4\r\n")
    data += bytes("Page three.")
    data += HARD
    data += [0x1A]
    let doc = parseWS(data)
    let annotated = annotatedLayout(doc)

    let reasons = annotated.lines.compactMap { line -> String? in
        guard case .pageBreakOrigin(let reason) = line.pageBreakBefore else { return nil }
        return reason
    }
    #expect(reasons == [".pa", ".cp4"])
}

@Test func naturalOverflowIsDetectedViaTheRealPaginator() {
    // No page geometry, no dot commands at all -- 70 short hard-returned lines, well
    // past the ~55-line default printed capacity (`PDFMetrics`/`printedCap`'s doc
    // comment). Natural breaks come ONLY from the real paginator (`layoutPrintedPagesPlain`,
    // widened to internal for this), never from a re-derived guess.
    var data: [UInt8] = []
    for n in 1...70 {
        data += bytes("Line \(n).")
        data += HARD
    }
    data += [0x1A]
    let doc = parseWS(data)
    #expect(!hasPlaceableNotes(doc))
    let annotated = annotatedLayout(doc)

    let natural = InkKind.pageBreakOrigin("")
    let naturalBreaks = annotated.lines.filter { $0.pageBreakBefore == natural }
    #expect(!naturalBreaks.isEmpty)
    // Cross-check against the real paginator directly: number of natural breaks plus
    // one (the first page needs no "before" break) equals the page count.
    let pages = layoutPrintedPagesPlain(doc)
    #expect(naturalBreaks.count == pages.count - 1)
}

// ------------------------------------------------------------ corpus gauntlet

@Test func oldtimesSurfacesItsDotCommandsAndComments() {
    let path = archiveWSPath + "/OLDTIMES.WS"
    guard let d = FileManager.default.contents(atPath: path) else { return }
    let doc = parseWS([UInt8](d))
    let annotated = annotatedLayout(doc)

    let dots = dotCommandTexts(annotated)
    #expect(dots.contains { $0.uppercased().hasPrefix(".H1") })
    let condpageDots = dots.filter { $0.uppercased().hasPrefix(".CP") }
    #expect(condpageDots.count >= 4)
    let comments = doc.notes.filter { $0.kind == NoteKind.comment }
    if !comments.isEmpty {
        #expect(commentTexts(annotated).count == comments.count)
    }
    let plain = doc.iterLines().map { $0.text() }.joined()
    #expect(visibleText(annotated) == plain)
}

@Test func lj6dtpSurfacesStyleToggleBoundaries() {
    let path = archiveWSPath + "/LJ6DTP.WS"
    guard let d = FileManager.default.contents(atPath: path) else { return }
    let doc = parseWS([UInt8](d))
    let annotated = annotatedLayout(doc)

    #expect(!styleToggleTokens(annotated).isEmpty)
    let plain = doc.iterLines().map { $0.text() }.joined()
    #expect(visibleText(annotated) == plain)
}

/// Round-trip: `annotatedLayout` is read-only over the parsed IR — calling it changes
/// nothing `emitPDF` sees from the SAME `Document` value afterward. This is the one
/// byte-identity proof this repo can make directly; the app-side manifest/oracle gate
/// (BOX/OLDTIMES/LJ6DTP printed shas) is a separate, later verification this job's brief
/// scopes to the engine checkout alone (see LESSONS).
@Test func annotatedLayoutDoesNotAffectSubsequentEmission() throws {
    for name in ["BOX.WS", "OLDTIMES.WS", "LJ6DTP.WS"] {
        let path = archiveWSPath + "/" + name
        guard let d = FileManager.default.contents(atPath: path) else { continue }
        let doc = parseWS([UInt8](d))
        let before = emitPDF(doc, mode: .printed)
        _ = annotatedLayout(doc)
        let after = emitPDF(doc, mode: .printed)
        #expect(before == after, "\(name)")
    }
}
