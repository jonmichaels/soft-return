/// MailMerge DATA files — detection, reading and the record shape.
///
/// Jon's rulings 2026-09-13 (planning #264, MAIL MERGE SCOPE and its two addenda),
/// verbatim: "the list of name and addresses? Those we should be able to open and people
/// should be able to get that list out into something useful"; "a plain list: names (and
/// addresses if present) on lines, one record per block — not a table export"; "we should
/// probably have some code to detect a file as a MailMerge data file. It should show up
/// listed as such in Document Info. And yes we should be kind and strip out the codes on
/// export."; "a .DTA made in document mode carries WordStar's high-bit marks, control
/// codes, Ctrl-Z padding and cp437 characters; the reader must decode through the engine
/// ... so the list is clean — that is the point of opening it in Soft Return."
///
/// A WordStar MailMerge data file is comma-separated quoted records — CSV before anyone
/// called it that — read by a merge document's `.df`, one field per `.rv` name. It is not
/// a document: no dot commands, no prose, nothing to lay out. What it has is a LIST.
///
/// NO MERGE IS EVER EXECUTED, here or anywhere (register "Mail Merge — scope"; the
/// permanent ruling 2026-08-06). This reads a list.
///
/// THE TEST IS STRUCTURAL AND ONLY STRUCTURAL. The Corpus-And-Filetype-Index states the
/// rule: `detect()` must be corroborated by STRUCTURE, never by a usage string — that is
/// exactly how `.PDF` false-positived on binaries carrying help text. Nothing here looks
/// for a word, a name, a header row or a field label. Six facts, all required:
///
///   1. no symmetric blocks and no wrapped extended characters past the opening header
///      (a list carries no footnotes, fonts or style library — this is what keeps a real
///      DOCUMENT out);
///   2. at least two records;
///   3. every non-blank record parses as a comma-separated field list, and an
///      unterminated quote disqualifies the whole file;
///   4. every record the SAME field count, and at least two — the strongest single
///      signal, and the one prose cannot fake;
///   5. most fields QUOTED (Jon: "already comma-separated quoted records");
///   6. no record a dot command. A `.df`/`.rv` line means this is the merge LETTER.
///
/// Port of the `core.py` block above `split_merge_fields`.

/// The document kind, as `Detection.kind` and `Document.kind` report it.
public let mergeDataKind = "MailMerge data file"

let mergeDataMinRecords = 2
let mergeDataMinFields = 2
let mergeDataQuotedShare = 0.5

/// One MailMerge data record -> `[(value, wasQuoted)]`, or nil when the line is not a
/// well-formed record.
///
/// Fields are comma-separated; a field may be wrapped in `"`, inside which a comma is
/// literal and `""` is one quote character. Space around a field is not part of it. An
/// unterminated quote returns nil — a half-quoted line is not a record, and accepting one
/// would let ordinary prose containing a quotation mark through. Port of
/// `split_merge_fields`.
public func splitMergeFields(_ text: String) -> [(value: String, quoted: Bool)]? {
    let chars = Array(text)
    var out: [(value: String, quoted: Bool)] = []
    var i = 0
    let n = chars.count
    while true {
        while i < n, chars[i] == " " { i += 1 }
        if i < n, chars[i] == "\"" {
            i += 1
            var buf = ""
            while true {
                if i >= n { return nil }              // unterminated quote
                if chars[i] == "\"" {
                    if i + 1 < n, chars[i + 1] == "\"" {
                        buf.append("\"")
                        i += 2
                        continue
                    }
                    i += 1
                    break
                }
                buf.append(chars[i])
                i += 1
            }
            out.append((buf, true))
        } else {
            var end = i
            while end < n, chars[end] != "," { end += 1 }
            var value = String(chars[i..<end])
            while value.hasPrefix(" ") { value.removeFirst() }
            while value.hasSuffix(" ") { value.removeLast() }
            out.append((value, false))
            i = end
        }
        while i < n, chars[i] == " " { i += 1 }
        if i >= n { return out }
        if chars[i] != "," { return nil }             // rubbish after a field
        i += 1
    }
}

/// `.xx` — a dot command, the one thing a data file never carries.
func isDotCommandLine(_ text: String) -> Bool {
    var t = Substring(text)
    while t.first == " " || t.first == "\t" { t = t.dropFirst() }
    let chars = Array(t)
    guard chars.count >= 3, chars[0] == ".", chars[1].isLetter else { return false }
    return chars[2].isLetter || chars[2] == " " || chars[2] == "\t"
}

/// `[[field, ...]]` when `lines` (already decoded to text) are the records of a MailMerge
/// data file, else nil. The six structural facts are listed at the head of this file;
/// this is where they are applied, and it is the ONE place — `detect` and
/// `parseMergeData` both come here, so the classification and the reading can never
/// disagree about what a record is. Port of `merge_data_records`.
public func mergeDataRecords(_ lines: [String]) -> [[String]]? {
    var records: [[String]] = []
    var quoted = 0
    var fieldsTotal = 0
    for text in lines {
        if text.trimmed().isEmpty { continue }
        if isDotCommandLine(text) { return nil }
        guard let parsed = splitMergeFields(text),
              parsed.count >= mergeDataMinFields else { return nil }
        if let first = records.first, parsed.count != first.count { return nil }
        records.append(parsed.map(\.value))
        quoted += parsed.filter(\.quoted).count
        fieldsTotal += parsed.count
    }
    guard records.count >= mergeDataMinRecords, fieldsTotal > 0 else { return nil }
    guard Double(quoted) >= Double(fieldsTotal) * mergeDataQuotedShare else { return nil }
    return records
}

/// `data` reduced to candidate record lines, or nil when its shape rules a data file out
/// before any parsing.
///
/// A cheap byte-level decode, not the engine's — `detect` runs before anything is parsed.
/// It drops the trailing ^Z padding, steps over an opening WS5+ header block (a
/// document-mode data file has one and nothing else), refuses any file carrying further
/// symmetric blocks or wrapped extended characters, masks WordStar's bit-7 word marks
/// off, and splits on returns of BOTH kinds. `parseMergeData` re-reads the same file
/// through the real engine; this only has to be good enough to classify.
///
/// A SOFT return ends a candidate record here, and that is deliberate: it ends a `Line`
/// in the engine too (WS4 reads a short soft-broken line as a deliberate break by its own
/// fit heuristic, and even where WS5+ reads one as wrap the record halves reach this test
/// separately). A record long enough to WRAP therefore leaves two malformed halves and
/// the file is declined rather than half-read — conservative, and it keeps this test and
/// `parseMergeData`'s engine-decoded reading from ever disagreeing about where a record
/// ends. No corpus data file exists to argue otherwise (the archive carries none at all),
/// so the safe answer is the one taken. Port of `_merge_data_text_lines`.
func mergeDataTextLines(_ data: [UInt8]) -> [String]? {
    var core: [UInt8]
    if let eof = bareEOF(data) {
        core = Array(data[..<eof])
    } else {
        core = data
    }
    if core.count >= 8, core[0] == 0x1D, core[3] == 0x00 {
        let jump = Int(core[1]) | (Int(core[2]) << 8)
        let end = 2 + jump
        if jump >= 8, jump < 0x400, end < core.count, core[end] == 0x1D {
            core = Array(core[(end + 1)...])
        }
    }
    if core.isEmpty { return nil }
    if countSymmetricBlocks(core) > 0 { return nil }
    var t = 0
    while t + 2 < core.count {
        if core[t] == 0x1B, core[t + 2] == 0x1C { return nil }
        t += 1
    }
    var lines: [String] = []
    var buf: [UInt8] = []
    var i = 0
    while i < core.count {
        // A return is a return, soft or hard.
        if i + 1 < core.count, core[i + 1] == 0x0A, core[i] == 0x0D || core[i] == 0x8D {
            lines.append(String(decoding: buf.map { $0 & 0x7F }, as: UTF8.self))
            buf.removeAll(keepingCapacity: true)
            i += 2
            continue
        }
        let low = core[i] & 0x7F
        if low < 0x20, core[i] != 0x09 { return nil }   // control bytes: not a list
        buf.append(core[i])
        i += 1
    }
    lines.append(String(decoding: buf.map { $0 & 0x7F }, as: UTF8.self))
    return lines
}

/// `[[field, ...]]` when `data` is a MailMerge data file, else nil. Structural
/// throughout. Port of `detect_merge_data`.
public func detectMergeData(_ data: [UInt8]) -> [[String]]? {
    guard let lines = mergeDataTextLines(data) else { return nil }
    return mergeDataRecords(lines)
}

/// A MailMerge data file as READABLE RECORDS — one block per record, one line per field.
///
/// DECODED THROUGH THE ENGINE, and that is the whole reason this exists: the file is read
/// by the SAME parser its variant would always have used, and the records are split out
/// of the text that parser produced (on `mergedLines`, so a soft-wrapped line is joined
/// exactly where every other reader of this document would see it joined). The bit-7 word
/// marks, the soft spaces, the cp437 mapping and the ^Z padding are therefore handled
/// exactly once, by the code that already handles them everywhere else.
///
/// `detect`'s own cheap byte-level reading is what CLASSIFIED the file; this re-reads it
/// properly. The two share `mergeDataRecords`, so they cannot disagree about what a
/// record is; if the engine's decode turns out not to yield records after all, the file
/// falls back to the ordinary parse for its variant rather than losing anything.
///
/// Port of `parse_merge_data`.
public func parseMergeData(_ data: [UInt8], detection: Detection? = nil) -> Document {
    let det = detection ?? detect(data)
    let base: Document
    switch det.variant {
    case .ws4, .ws5plus: base = parseWS(data)
    default: base = parsePrintstream(data)
    }
    var textLines: [String] = []
    for block in base.blocks {
        for line in mergedLines(block) {
            textLines.append(line.spans.map(\.text).joined())
        }
    }
    guard let records = mergeDataRecords(textLines) else { return base }
    var doc = base
    doc.blocks = []
    doc.kind = mergeDataKind
    doc.mergeRecords = records.count
    doc.mergeFields = records[0].count
    // One block per record, one line per field, and a blank line BETWEEN records — "one
    // record per block", and the blank is what makes that visible in a format with no
    // blocks of its own. The last record gets none: a trailing blank is not a separator.
    for (k, fields) in records.enumerated() {
        var lines = fields.map { Line(spans: [Span(text: $0)]) }
        if k < records.count - 1 { lines.append(Line()) }
        doc.blocks.append(Block(kind: .para, lines: lines))
    }
    return doc
}
