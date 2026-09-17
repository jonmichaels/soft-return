/// planning #264 CHECK PLAN, layer 2 (Jon, 2026-09-14): "2 is fine now." — structural
/// RTF/HTML checks and a parser round trip, in both engines' suites.
///
/// WHY THIS LAYER EXISTS. Layer 1 is the rules pinned by name and the cross-engine byte
/// gate: it proves the two engines agree and that each named rule fires. Neither says the
/// FILE IS WELL FORMED. An RTF with one unbalanced brace, or a control word no reader
/// knows, or a section opener the document never asked for, passes every byte comparison
/// in the suite as long as both engines are wrong in the same way. Layer 3 (LibreOffice
/// headless, or Jon's own eyes on Word and Pages) is the only thing that can judge how it
/// LOOKS; this is what can be automated today, and it is about SHAPE.
///
/// THREE CHECKS:
///
///   RTF   braces balance (honouring `\{`, `\}` and `\\`); every control word comes from
///         a list this file names; and the number of `\sect` openers equals the number of
///         section breaks the document actually asked for (`rtfSectionBreaks`). The word
///         list is the point of the second one: a typo (`\keepnn`) and a real new feature
///         look identical to a byte comparison, and only one should be added to the list.
///   HTML  the body parses under a STRICT parser — `XMLParser`, after the void elements
///         are self-closed and `&nbsp;` becomes numeric. A browser forgives almost
///         anything; XML forgives nothing.
///   TRIP  the RTF and the HTML are read back to plain text and compared,
///         whitespace-normalised, with our own `emitText`.
///
/// Port of ctrl-kd's `tests/test_structural_checks.py`, including its own account of what
/// these caught on their first run.
import Foundation
#if canImport(FoundationXML)
// `XMLParser` is in Foundation on Apple platforms and in FoundationXML on Linux — this
// file's strict HTML check has to build in both places, and the engine suite runs on
// both.
import FoundationXML
#endif
import Testing
@testable import CtrlKD

private let curatedStructuralDocs = [
    "REF/WINGDING.CHT",       // `.co5` columns, five of them
    "MICKEE/MICKEE.WS",       // columns on and off, `.cb`, a head change
    "MACROS/HOLYMAC/1-3MAC",  // a head redefined mid-document, `.cp`
    "OLDTIMES.WS",            // `.cp`, a running head, notes, the byline defect
    "LJ6DTP.WS",              // a driver document: substitutions, print controls
    "REF/WSFORMAT.WS",        // long, heavily dot-commanded reference prose
    "STRENGTH.WS",            // space-centred lines, no head or foot at all
    "RTF-RJS/NOVEL.WS",       // styles, `.tc` entries, merge variables
    "REF/TOCTRICK.WS",        // the merge page-number variable
    "VERSIONS.TXT",           // a printstream
]

// MARK: - RTF shape

/// Every place the brace nesting goes wrong.
func rtfBraceErrors(_ rtf: String) -> [String] {
    var errors: [String] = []
    var depth = 0
    let chars = Array(rtf)
    var i = 0
    while i < chars.count {
        if chars[i] == "\\", i + 1 < chars.count {
            i += 2                                  // an escape, whatever it is
            continue
        }
        if chars[i] == "{" {
            depth += 1
        } else if chars[i] == "}" {
            depth -= 1
            if depth < 0 {
                errors.append("a closing brace with nothing open at \(i)")
                depth = 0
            }
        }
        i += 1
    }
    if depth != 0 { errors.append("\(depth) group(s) never closed") }
    return errors
}

/// Every control word either engine writes. A word NOT on this list is not necessarily
/// wrong — it is UNREVIEWED, which is the thing this check is for.
let rtfKnownControlWords: Set<String> = Set("""
rtf ansi deff fonttbl f falt colortbl red green blue stylesheet s
paperw paperh margl margr margt margb facingp margmirror headery footery
pgnstart landscape cols colsx sect sectd column page par line tab titlepg
header headerl headerr headerf footer footerl footerr footerf chpgn
pard plain qc qr ql qj fs cf chcbpat highlight b i ul ulnone strike super sub nosupersub
fi li ri sl slmult sb sa keep keepn up dn
chftn footnote ftnalt chatn annotation atnid atnauthor
u uc bkmkstart bkmkend field fldinst fldrslt pict pngblip jpegblip
picw pich picwgoal pichgoal emfblip wmetafile
info title author creatim yr mo dy
""".split(whereSeparator: \.isWhitespace).map(String.init))

/// Every control word in `rtf`, in order.
///
/// A SCAN, not a pattern match: `\\`, `\{` and `\}` are ESCAPES, and a document whose
/// text contains a DOS path (`C:\WS\PrintFilePrinter`, which LJ6DTP.WS really does)
/// escapes each backslash, so a naive scan reads `\WS` as a control word called `WS`.
/// Found by this very check on its first run.
func rtfControlWords(_ rtf: String) -> [String] {
    var out: [String] = []
    let chars = Array(rtf)
    var i = 0
    while i < chars.count {
        guard chars[i] == "\\" else {
            i += 1
            continue
        }
        var j = i + 1
        var word = ""
        while j < chars.count, chars[j].isLetter, chars[j].isASCII {
            word.append(chars[j])
            j += 1
        }
        if word.isEmpty {
            i += 2                                  // an escaped character
            continue
        }
        out.append(word)
        if j < chars.count, chars[j] == "-" { j += 1 }
        while j < chars.count, chars[j].isNumber { j += 1 }
        i = j
    }
    return out
}

func rtfUnknownControlWords(_ rtf: String) -> [String] {
    Set(rtfControlWords(rtf)).subtracting(rtfKnownControlWords).sorted()
}

func rtfSectionOpenerCount(_ rtf: String) -> Int {
    rtf.components(separatedBy: #"\sect\sectd"#).count - 1
}

// MARK: - RTF -> text

private let rtfDestinations: Set<String> = [
    "fonttbl", "colortbl", "stylesheet", "info",
    "header", "headerl", "headerr", "headerf",
    "footer", "footerl", "footerr", "footerf",
    "footnote", "annotation", "atnid", "atnauthor", "pict", "field",
]

/// A small RTF text extractor — enough to read our own output back.
///
/// Skips the destination groups whose content is not body text, unescapes `\uN?`, turns
/// `\par`, `\line`, `\page` and `\column` into newlines, and drops every other control
/// word. Deliberately small: a full RTF reader would hide the very defects this is here
/// to find.
///
/// The skip depth is set only when nothing is already being skipped — a nested
/// `{\*\falt ...}` group inside the font table used to OVERWRITE the table's own depth
/// and then clear it on its own closing brace, leaking `;Courier New;` into the text.
/// Found by this check on its first run.
func rtfToText(_ rtf: String) -> String {
    let chars = Array(rtf)
    var out = ""
    var depth = 0
    var skipDepth: Int? = nil
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if ch == "{" {
            depth += 1
            i += 1
            if skipDepth == nil {
                var j = i
                var star = false
                if j < chars.count, chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == "*" {
                    star = true
                }
                var word = ""
                if j < chars.count, chars[j] == "\\" {
                    j += 1
                    while j < chars.count, chars[j].isLetter { word.append(chars[j]); j += 1 }
                }
                if star || rtfDestinations.contains(word) { skipDepth = depth }
            }
            continue
        }
        if ch == "}" {
            if skipDepth == depth { skipDepth = nil }
            depth -= 1
            i += 1
            continue
        }
        if ch == "\\" {
            var j = i + 1
            var word = ""
            while j < chars.count, chars[j].isLetter, chars[j].isASCII {
                word.append(chars[j])
                j += 1
            }
            if word.isEmpty {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                i += 2
                if skipDepth == nil, next == "\\" || next == "{" || next == "}" {
                    out.append(next)
                }
                continue
            }
            var negative = false
            if j < chars.count, chars[j] == "-" { negative = true; j += 1 }
            var digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if j < chars.count, chars[j] == " " { j += 1 }
            i = j
            if skipDepth != nil { continue }
            switch word {
            case "par", "line", "page", "column": out.append("\n")
            case "tab": out.append("\t")
            case "u" where !digits.isEmpty:
                var value = Int(digits) ?? 0
                if negative { value += 65536 }
                if let scalar = Unicode.Scalar(value) { out.unicodeScalars.append(scalar) }
                if i < chars.count, chars[i] == "?" { i += 1 }   // the ANSI fallback
            default: break
            }
            continue
        }
        if skipDepth == nil, ch != "\r", ch != "\n" { out.append(ch) }
        i += 1
    }
    return out
}

// MARK: - HTML strict

private final class XMLWellFormedness: NSObject, XMLParserDelegate {
    var errors: [String] = []
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        errors.append(parseError.localizedDescription)
    }
}

/// The body, parsed as XML. A browser forgives almost anything; XML forgives nothing, and
/// an unclosed or mis-nested tag is exactly the class of defect a byte comparison cannot
/// see.
func htmlBodyXMLErrors(_ html: String) -> [String] {
    guard let open = html.range(of: "<body>"),
          let close = html.range(of: "</body>", options: .backwards) else {
        return ["no <body> in the document"]
    }
    var body = String(html[open.upperBound..<close.lowerBound])
    for void in ["br", "hr", "img", "meta", "link", "input"] {
        body = selfClose(body, tag: void)
    }
    body = body.replacingOccurrences(of: "&nbsp;", with: "&#160;")
    let parser = XMLParser(data: Data(("<root>" + body + "</root>").utf8))
    let delegate = XMLWellFormedness()
    parser.delegate = delegate
    if !parser.parse(), delegate.errors.isEmpty {
        delegate.errors.append("XMLParser refused the body with no error recorded")
    }
    return delegate.errors
}

private func selfClose(_ html: String, tag: String) -> String {
    var out = ""
    var rest = Substring(html)
    while let open = rest.range(of: "<" + tag) {
        let after = open.upperBound
        // `<br` must not match `<break`: the next character ends the tag name.
        if after < rest.endIndex, rest[after].isLetter || rest[after] == "-" {
            out += rest[rest.startIndex..<after]
            rest = rest[after...]
            continue
        }
        guard let gt = rest[after...].firstIndex(of: ">") else { break }
        var inner = String(rest[after..<gt])
        while inner.hasSuffix("/") { inner.removeLast() }
        // Sequential `+=`, not a chained `+`: planning #253, the macOS type-checker.
        out += rest[rest.startIndex..<open.lowerBound]
        out += "<"
        out += tag
        out += inner
        out += "/>"
        rest = rest[rest.index(after: gt)...]
    }
    return out + rest
}

private let htmlBlockTags = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
                             "ul", "ol", "li", "dl", "dt", "dd",
                             "blockquote", "section", "pre"]

/// BLOCK BOUNDARIES ON BOTH TAGS, opening and closing. A nested list — `<dd>76702,747<dl>
/// <dt>GEnie:</dt>...` on MICKEE.WS, where the ladder really does step in — opens its
/// sublist INSIDE the `<dd>` with no closing tag between, so closing tags alone ran two
/// rows' words together. Found by this check on its first run; the markup is right and
/// the reader was not.
func htmlToText(_ html: String) -> String {
    guard let open = html.range(of: "<body>"),
          let close = html.range(of: "</body>", options: .backwards) else { return "" }
    let body = String(html[open.upperBound..<close.lowerBound])
    var out = ""
    var rest = Substring(body)
    while let lt = rest.firstIndex(of: "<") {
        out += rest[rest.startIndex..<lt]
        guard let gt = rest[lt...].firstIndex(of: ">") else { break }
        var name = ""
        var k = rest.index(after: lt)
        if k < gt, rest[k] == "/" { k = rest.index(after: k) }
        while k < gt, rest[k].isLetter || rest[k].isNumber {
            name.append(rest[k])
            k = rest.index(after: k)
        }
        let lower = name.lowercased()
        if lower == "br" || lower == "hr" || htmlBlockTags.contains(lower) {
            out += "\n"
        }
        rest = rest[rest.index(after: gt)...]
    }
    out += rest
    return htmlUnescape(out.replacingOccurrences(of: "&nbsp;", with: " "))
}

/// The entity forms this emitter actually writes — including `&#x27;`, which Python's own
/// `html.escape` produces for an apostrophe and a five-entry hand table missed on every
/// document in the set. Found by this check on its first run.
func htmlUnescape(_ text: String) -> String {
    var out = text
    for (entity, replacement) in [("&#x27;", "'"), ("&#39;", "'"), ("&quot;", "\""),
                                  ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
        out = out.replacingOccurrences(of: entity, with: replacement)
    }
    return out
}

// MARK: - the word comparison

/// The word sequence, whitespace-normalised — what a round trip can honestly compare.
/// Line breaks, indent columns and paragraph gaps are each format's own business; the
/// WORDS are the document.
///
/// The PAGE-BREAK MARK is dropped first, and it is the one thing this has to forgive:
/// each format writes the same fact its own way — a form feed in printed text, a
/// twenty-dash rule in Modern text, `<hr class="pb">` in HTML, `\page` in RTF — and only
/// the text ones are made of characters a word split can see. `markers` does the same for
/// a BULLET glyph HTML's own `<li>` consumed.
func exportWords(_ text: String, markers: Set<String> = []) -> [String] {
    text.split(whereSeparator: \.isWhitespace)
        .map(String.init)
        .filter { word in
            if markers.contains(word) { return false }
            if word == "\u{0C}" { return false }
            if word.count == 20, word.allSatisfy({ $0 == "-" }) { return false }
            return true
        }
}

/// The glyphs this document's own classifier calls bullet markers. Modern HTML renders a
/// bullet row as a real `<ul><li>`, where the marker is the LIST's, drawn by CSS — so the
/// typed glyph correctly does not appear in the markup, while Modern text and Modern RTF
/// keep it. Read from the classifier's own verdicts, never from a hardcoded glyph list.
func bulletMarkers(_ doc: Document) -> Set<String> {
    var out: Set<String> = []
    for rows in classifyModernBlocks(doc).values {
        for row in rows {
            if let marker = row.structure?.marker, !marker.isEmpty { out.insert(marker) }
        }
    }
    return out
}

// MARK: - the rows

private func structuralSynthetic() -> Document {
    let count = UInt16(4 + 16)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var bytes: [UInt8] = [0x1D]
    bytes += le
    bytes += [0x00, 0x70]
    bytes += [UInt8](repeating: 0, count: 15)
    bytes += le
    bytes += [0x1D]
    bytes += Array("""
    .he First Head\r
    Opening paragraph of the document.\r
    .cp 3\r
    A Kept Heading\r
    \r
    Body under the heading.\r
    .co 2, 5\r
    Columnar text here.\r
    .cb\r
    Second column text.\r
    .co 1\r
    Back to one column.\r
    .pa\r
    .he Second Head\r
    After the head changed.\r
    """.replacingOccurrences(of: "\r\n", with: "\r\n").utf8)
    return parseWS(bytes)
}

@Test(arguments: [EmitMode.printed, .modern])
func syntheticRTFIsStructurallySound(mode: EmitMode) {
    let doc = structuralSynthetic()
    let rtf = emitRTF(doc, mode: mode)
    #expect(rtfBraceErrors(rtf) == [])
    #expect(rtfUnknownControlWords(rtf) == [])
    #expect(rtfSectionOpenerCount(rtf)
            == rtfSectionBreaks(doc).count)
}

@Test(arguments: [EmitMode.printed, .modern])
func syntheticHTMLParsesStrictly(mode: EmitMode) {
    #expect(htmlBodyXMLErrors(emitHTML(structuralSynthetic(), mode: mode)) == [])
}

@Test(arguments: [EmitMode.printed, .modern])
func syntheticExportsAgreeAboutTheWords(mode: EmitMode) {
    let doc = structuralSynthetic()
    let marks = bulletMarkers(doc)
    let text = exportWords(emitText(doc, mode: mode), markers: marks)
    #expect(exportWords(rtfToText(emitRTF(doc, mode: mode)), markers: marks) == text)
    #expect(exportWords(htmlToText(emitHTML(doc, mode: mode)), markers: marks) == text)
}

private func structuralArchiveDocument(_ name: String) throws -> Document {
    let url = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(name)
    return try parse([UInt8](try Data(contentsOf: url)))
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: curatedStructuralDocs, [EmitMode.printed, .modern])
func curatedRTFIsStructurallySound(name: String, mode: EmitMode) throws {
    let doc = try structuralArchiveDocument(name)
    let rtf = emitRTF(doc, mode: mode)
    #expect(rtfBraceErrors(rtf) == [], "\(name)")
    #expect(rtfUnknownControlWords(rtf) == [], "\(name)")
    #expect(rtfSectionOpenerCount(rtf)
            == rtfSectionBreaks(doc).count,
            "\(name)")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: curatedStructuralDocs, [EmitMode.printed, .modern])
func curatedHTMLParsesStrictly(name: String, mode: EmitMode) throws {
    #expect(htmlBodyXMLErrors(emitHTML(try structuralArchiveDocument(name), mode: mode))
            == [], "\(name)")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: curatedStructuralDocs, [EmitMode.printed, .modern])
func curatedExportsAgreeAboutTheWords(name: String, mode: EmitMode) throws {
    // THE ROUND TRIP. Two exports of one document that disagree about the WORDS have a
    // bug in one of them, and no byte comparison between engines can see it.
    let doc = try structuralArchiveDocument(name)
    let marks = bulletMarkers(doc)
    let text = exportWords(emitText(doc, mode: mode), markers: marks)
    #expect(exportWords(rtfToText(emitRTF(doc, mode: mode)), markers: marks) == text,
            "\(name) rtf")
    #expect(exportWords(htmlToText(emitHTML(doc, mode: mode)), markers: marks) == text,
            "\(name) html")
}
