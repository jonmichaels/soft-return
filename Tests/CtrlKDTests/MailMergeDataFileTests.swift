/// planning #264, MAIL MERGE SCOPE (Jon, 2026-09-13) and its two addenda.
///
/// Verbatim: "the list of name and addresses? Those we should be able to open and people
/// should be able to get that list out into something useful"; then "a plain list: names
/// (and addresses if present) on lines, one record per block — not a table export"; then
/// "we should probably have some code to detect a file as a MailMerge data file. It
/// should show up listed as such in Document Info. And yes we should be kind and strip
/// out the codes on export."; and finally "a .DTA made in document mode carries
/// WordStar's high-bit marks, control codes, Ctrl-Z padding and cp437 characters; the
/// reader must decode through the engine ... so the list is clean — that is the point of
/// opening it in Soft Return."
///
/// NO MERGE IS EVER EXECUTED, here or anywhere (register "Mail Merge — scope"; the
/// permanent ruling 2026-08-06). This reads a list.
///
/// THE DETECTION IS STRUCTURAL AND ONLY STRUCTURAL, because the
/// Corpus-And-Filetype-Index says it has to be: corroborate by SHAPE, never by a usage
/// string — that is exactly how `.PDF` false-positived on binaries carrying help text.
/// Nothing in `mergeDataRecords` looks for a word, a name, a header row or a field label;
/// the false-positive rows below are what that buys.
///
/// Port of ctrl-kd's `tests/test_mailmerge_data_files.py`. Synthetic fixtures.
import Foundation
import Testing
@testable import CtrlKD

private let mergeHard: [UInt8] = [0x0D, 0x0A]
private let mergeSoft: [UInt8] = [0x8D, 0x0A]
private let mergePad: [UInt8] = Array(repeating: 0x1A, count: 8)

private func mergeBytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// A WS4 word: bit 7 on the last letter, WordStar's own wrap mark.
private func hibitWord(_ word: String) -> [UInt8] {
    var bytes = Array(word.utf8)
    bytes[bytes.count - 1] |= 0x80
    return bytes
}

private var plainDataFile: [UInt8] {
    var out = mergeBytes("\"Sawyer\",\"Robert J.\",\"Toronto\"")
    out += mergeHard
    out += mergeBytes("\"Doe\",\"Jane\",\"Ottawa\"")
    out += mergeHard
    out += mergeBytes("\"Roe\",\"Richard\",\"Halifax\"")
    out += mergeHard
    out += mergePad
    return out
}

private func mergeLines(_ text: String) -> [UInt8] {
    var out: [UInt8] = []
    for line in text.components(separatedBy: "\n") where !line.isEmpty {
        out += mergeBytes(line)
        out += mergeHard
    }
    return out
}

private func recordRows(_ doc: Document) -> [[String]] {
    doc.blocks.map { block in
        block.lines.map { $0.spans.map(\.text).joined() }.filter { !$0.isEmpty }
    }
}

// MARK: - detection

@Test func aPlainDataFileIsRecognised() {
    let det = detect(plainDataFile)
    #expect(det.kind == mergeDataKind)
    #expect(det.mergeRecords == 3)
    #expect(det.mergeFields == 3)
}

@Test func theVariantIsLeftExactlyAsTheBytesFoundIt() {
    // The kind is an ADDITIONAL fact about the same bytes. A non-document data file
    // really is plain text and everything downstream that branches on `variant` must go
    // on seeing what it always saw.
    #expect(detect(plainDataFile).variant == .printstream)
}

@Test func documentInfoReportsTheKind() throws {
    // "It should show up listed as such in Document Info."
    let report = documentInfo(plainDataFile, path: "WSLIST.DTA")
    guard case .object(let fields) = report else {
        Issue.record("documentInfo did not return an object")
        return
    }
    #expect(fields["kind"] == .string(mergeDataKind))
    #expect(fields["merge_records"] == .int(3))
}

// MARK: - false positives

@Test func ordinaryProseWithCommasIsNotADataFile() {
    let prose = mergeLines("""
    It was a bright, cold day in April, and the clocks
    were striking thirteen, as they always do.
    """)
    #expect(detect(prose).kind == nil)
}

@Test func aMergeLetterIsNotItsData() {
    // A `.df`/`.rv` line means this is the letter. The corpus's own `MAILLIST.DOT` is
    // exactly this shape.
    let letter = mergeLines("""
    .df wslist.dta
    .rv name, company, city
    "Dear &name&","&company&","&city&"
    "Dear &name&","&company&","&city&"
    """)
    #expect(detect(letter).kind == nil)
}

@Test func recordsOfDifferentWidthsAreNotADataFile() {
    // Uniform field count is the strongest single signal, and the one prose cannot fake.
    #expect(detect(mergeLines("\"a\",\"b\",\"c\"\n\"d\",\"e\"")).kind == nil)
}

@Test func aSingleFieldPerLineIsNotADataFile() {
    #expect(detect(mergeLines("\"Sawyer\"\n\"Doe\"\n\"Roe\"")).kind == nil)
}

@Test func oneRecordIsNotAList() {
    #expect(detect(mergeLines("\"Sawyer\",\"Robert J.\",\"Toronto\"")).kind == nil)
}

@Test func mostlyUnquotedRecordsAreNotADataFile() {
    // Jon's own description of the shape: "already comma-separated quoted records (CSV
    // without headers)." A bare comma list could be anything.
    #expect(detect(mergeLines("a,b,c\nd,e,f\ng,h,i")).kind == nil)
}

@Test func anUnterminatedQuoteDisqualifiesTheFile() {
    #expect(detect(mergeLines("\"Sawyer\",\"Robert J.\",\"Toronto\n\"Doe\",\"Jane\",\"Ottawa\"")).kind == nil)
}

@Test func aRealDocumentIsNeverADataFile() {
    // Symmetric blocks past the opening header are WS5+ machinery — a list carries no
    // footnotes, fonts or style library.
    let count = UInt16(4 + 8)
    var note: [UInt8] = [0x1D, UInt8(count & 0xFF), UInt8(count >> 8), 0x06]
    note += [UInt8](repeating: 0, count: 7)
    note += [UInt8(count & 0xFF), UInt8(count >> 8), 0x1D]
    var data = mergeBytes("\"a\",\"b\",\"c\"")
    data += mergeHard
    data += note
    data += mergeBytes("\"d\",\"e\",\"f\"")
    data += mergeHard
    #expect(detect(data).kind == nil)
}

@Test func noUsageStringIsEverConsulted() {
    // The index's own rule. A file whose FIELD TEXT is full of merge vocabulary is still
    // judged on its shape alone — this one passes because it is shaped like a list, not
    // because of what it says.
    let talky = mergeLines("""
    "mail merge",".df",".rv"
    "data file","dta","merge"
    """)
    #expect(detect(talky).kind == mergeDataKind)
    // ...and the same words in a shape that is not a list are refused
    let prose = mergeLines("""
    mail merge data file .df .rv
    a second line of the same
    """)
    #expect(detect(prose).kind == nil)
}

// MARK: - opening it as records

@Test func itOpensAsOneBlockPerRecord() throws {
    let doc = try parse(plainDataFile)
    #expect(doc.kind == mergeDataKind)
    #expect(doc.blocks.count == 3)
    #expect(recordRows(doc)[0] == ["Sawyer", "Robert J.", "Toronto"])
}

@Test func theCtrlZPaddingNeverReachesAField() throws {
    for row in recordRows(try parse(plainDataFile)) {
        for field in row { #expect(!field.contains("\u{1A}")) }
    }
}

@Test func aDocumentModeFileIsDecodedThroughTheEngine() throws {
    // The point of opening one at all: bit-7 word marks stripped, a soft space read as a
    // space, ^Z padding dropped. WS4 shape — that is the era whose files carry the mark.
    var data: [UInt8] = mergeBytes("\"")
    data += hibitWord("Sawyer")
    data += mergeBytes("\",\"")
    data += hibitWord("Robert")
    data += [0xA0]                          // a soft space
    data += hibitWord("J")
    data += mergeBytes(".\",\"")
    data += hibitWord("Toronto")
    data += mergeBytes("\"")
    data += mergeHard
    data += mergeBytes("\"")
    data += hibitWord("Doe")
    data += mergeBytes("\",\"")
    data += hibitWord("Jane")
    data += mergeBytes("\",\"")
    data += hibitWord("Ottawa")
    data += mergeBytes("\"")
    data += mergeHard
    data += mergePad
    #expect(detect(data).kind == mergeDataKind)
    let rows = recordRows(try parse(data))
    #expect(rows[0] == ["Sawyer", "Robert J.", "Toronto"])
    #expect(rows[1] == ["Doe", "Jane", "Ottawa"])
}

@Test func aRecordLongEnoughToWrapIsDeclinedRatherThanHalfRead() {
    // A soft return ends a record line here, because it ends a `Line` in the engine too.
    // So a wrapped record leaves two malformed halves and the file is DECLINED —
    // conservative on purpose: it keeps `detect` and `parseMergeData` from ever
    // disagreeing about where a record ends.
    var data = mergeBytes("\"Sawyer\",\"Robert")
    data += mergeSoft
    data += mergeBytes("J.\",\"Toronto\"")
    data += mergeHard
    data += mergeBytes("\"Doe\",\"Jane")
    data += mergeSoft
    data += mergeBytes("A.\",\"Ottawa\"")
    data += mergeHard
    data += mergePad
    #expect(detect(data).kind == nil)
}

@Test func aCommaInsideAQuotedFieldIsNotASeparator() throws {
    let data = mergeLines("""
    "Sawyer","Toronto, Ontario","Canada"
    "Doe","Ottawa, Ontario","Canada"
    """)
    #expect(recordRows(try parse(data))[0] == ["Sawyer", "Toronto, Ontario", "Canada"])
}

@Test func aDoubledQuoteInsideAFieldIsOneQuote() throws {
    let data = mergeLines("""
    "Sawyer","the ""Rob"" one","Toronto"
    "Doe","the ""Jan"" one","Ottawa"
    """)
    #expect(recordRows(try parse(data))[0][1] == "the \"Rob\" one")
}

// MARK: - exporting the list

private let expectedList = """
Sawyer
Robert J.
Toronto

Doe
Jane
Ottawa

Roe
Richard
Halifax

"""

@Test(arguments: [EmitMode.printed, .modern])
func textIsThePlainList(mode: EmitMode) throws {
    #expect(emitText(try parse(plainDataFile), mode: mode) == expectedList)
}

@Test func markdownMirrorsTheTextList() throws {
    let md = emitMarkdown(try parse(plainDataFile), mode: .modern)
    let trimmed = md.components(separatedBy: "\n").map { line -> String in
        var l = Substring(line)
        while l.hasSuffix(" ") { l = l.dropLast() }
        return String(l)
    }
    #expect(trimmed == expectedList.components(separatedBy: "\n"))
}

@Test func htmlMirrorsTheTextList() throws {
    let html = emitHTML(try parse(plainDataFile), mode: .modern)
    let body = String(html[html.range(of: "<body>")!.lowerBound...])
    #expect(body.components(separatedBy: "<p").count - 1 == 3)
    #expect(body.contains("Sawyer<br>"))
    #expect(body.contains("Robert J.<br>"))
    #expect(body.contains("Toronto</p>"))
}

@Test func rtfMirrorsTheTextList() throws {
    let rtf = emitRTF(try parse(plainDataFile), mode: .modern)
    #expect(rtf.components(separatedBy: #"\par "#).count - 1 >= 3)
    for field in ["Sawyer", "Robert J.", "Toronto", "Halifax"] {
        #expect(rtf.contains(field))
    }
}

@Test func noExportEverCarriesAQuoteOrACommaSeparator() throws {
    // "strip out the codes on export" — the CSV punctuation is the file's own machinery,
    // not its content.
    let doc = try parse(plainDataFile)
    for out in [emitText(doc, mode: .modern), emitMarkdown(doc, mode: .modern)] {
        #expect(!out.contains("\""))
        #expect(!out.contains("\",\""))
    }
}

// MARK: - the corpus

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason))
func noArchiveDocumentIsTakenForADataFile() throws {
    // The false-positive gate that matters: every document the committed manifest names,
    // judged by the real `detect()`.
    //
    // THE ARCHIVE CARRIES NO DATA FILE AT ALL — swept 2026-09-14 over every file in the
    // corpus, allowing for high-bit marks: not one holds so much as two comma-separated
    // quoted records. The `.LST` files the corpus does have (`HP-ENV.LST`, `PHONE.LST`,
    // `INVNTORY.LST`, `LSRLABL3.LST`) are LABEL AND ENVELOPE TEMPLATES — real WordStar
    // documents full of dot commands, which is why the index lists them among the
    // documents whose extension lies. So this asserts the only thing the archive can
    // prove: that nothing in it is mistaken for one.
    var seen = 0
    for (name, entry) in AnswerKeyFixture.loaded?.sawyerConvertible ?? [:] {
        guard let relativePath = entry.path else { continue }
        let url = URL(fileURLWithPath: sawyerArchivePath)
            .appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { continue }
        seen += 1
        #expect(detect([UInt8](data)).kind == nil, "\(name)")
    }
    #expect(seen > 100)
}
