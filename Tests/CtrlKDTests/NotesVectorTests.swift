import Foundation
import Testing
@testable import CtrlKD

/// Equivalence proof against `Fixtures/notes-vectors-1.2.0.json` — machine-generated
/// from the shipped Python ctrl-kd 1.2.0 (the real, fixed implementation; NOT the
/// pre-1.2.0 job-005/006/008/009/011 vectors, which predate the note-kind fix and are
/// annotated as stale where they touch footnotes — see the comment at the top of
/// `VectorTests.swift`). Six cases, each an `input_hex` plus the expected `notes[]`
/// (kind/text/number/tag/dot_commands) and `meta` (page/producer/
/// footnote_number_start/endnote_number_start/comment_bug). Per the task brief, `emit`
/// and `printed_pagelines` belong to later lanes (emitters/PDF layout) and are not
/// decoded or asserted here.
///
/// `Foundation` is imported here for `JSONDecoder`/`Bundle` only; the `CtrlKD` library
/// target itself stays Foundation-free.

private struct NotesVectorFile: Decodable {
    let generator: String
    let cases: [String: NotesVectorCase]
}

private struct NotesVectorCase: Decodable {
    let inputHex: String
    let notes: [NoteVector]
    let meta: MetaVector

    enum CodingKeys: String, CodingKey {
        case inputHex = "input_hex"
        case notes
        case meta
    }
}

private struct NoteVector: Decodable {
    let kind: String
    let text: String
    let number: Int?
    let tag: String?
    let dotCommands: [String]

    enum CodingKeys: String, CodingKey {
        case kind
        case text
        case number
        case tag
        case dotCommands = "dot_commands"
    }
}

private struct PageVector: Decodable {
    let plLines: Double
    let heightIn: Double
    let sizeName: String
    let sizeSource: String
    let mtLines: Double
    let mtSource: String
    let mbLines: Double
    let mbSource: String
    let poCols: Double
    let poSource: String

    enum CodingKeys: String, CodingKey {
        case plLines = "pl_lines"
        case heightIn = "height_in"
        case sizeName = "size_name"
        case sizeSource = "size_source"
        case mtLines = "mt_lines"
        case mtSource = "mt_source"
        case mbLines = "mb_lines"
        case mbSource = "mb_source"
        case poCols = "po_cols"
        case poSource = "po_source"
    }
}

private struct MetaVector: Decodable {
    let page: PageVector
    let producer: String?
    let footnoteNumberStart: Int?
    let endnoteNumberStart: Int?
    // `comment_bug` is `null` in all six cases (none of them are printstream input —
    // every one is ws5+, so `_detect_comment_bug` never runs). Not decoded: asserted
    // directly as `doc.commentBug == nil` below instead, which is equivalent and
    // avoids modelling a JSON shape this fixture never actually populates.

    enum CodingKeys: String, CodingKey {
        case page
        case producer
        case footnoteNumberStart = "footnote_number_start"
        case endnoteNumberStart = "endnote_number_start"
    }
}

private func bytesFromHex(_ hex: String) -> [UInt8] {
    let chars = Array(hex)
    precondition(chars.count % 2 == 0, "hex string must have an even length")
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
        out.append(UInt8(String(chars[i...(i + 1)]), radix: 16)!)
    }
    return out
}

@Test func notesVectors1_2_0() throws {
    let url = try #require(
        Bundle.module.url(forResource: "notes-vectors-1.2.0", withExtension: "json"),
        "notes-vectors-1.2.0.json missing from the test bundle"
    )
    let file = try JSONDecoder().decode(NotesVectorFile.self, from: Data(contentsOf: url))
    #expect(file.generator == "ctrl-kd 1.2.0")
    #expect(file.cases.count == 6)

    for name in file.cases.keys.sorted() {
        let v = file.cases[name]!
        let doc = parseWS(bytesFromHex(v.inputHex))
        let label = "notes vector \(name)"

        // notes[]: kind/text/number/tag/dot_commands, in document order.
        #expect(doc.notes.count == v.notes.count, "\(label): note count")
        for (i, want) in v.notes.enumerated() where i < doc.notes.count {
            let got = doc.notes[i]
            #expect(got.kind.rawValue == want.kind, "\(label) note \(i): kind")
            #expect(got.text == want.text, "\(label) note \(i): text")
            #expect(got.number == want.number, "\(label) note \(i): number")
            #expect(got.tag == want.tag, "\(label) note \(i): tag")
            #expect(got.dotCommands == want.dotCommands, "\(label) note \(i): dot_commands")
        }

        // meta.page
        let page = try #require(doc.page, "\(label): page must be resolved")
        #expect(page.plLines == v.meta.page.plLines, "\(label): page.pl_lines")
        #expect(page.heightIn == v.meta.page.heightIn, "\(label): page.height_in")
        #expect(page.sizeName == v.meta.page.sizeName, "\(label): page.size_name")
        #expect(page.sizeSource.rawValue == v.meta.page.sizeSource, "\(label): page.size_source")
        #expect(page.mtLines == v.meta.page.mtLines, "\(label): page.mt_lines")
        #expect(page.mtSource.rawValue == v.meta.page.mtSource, "\(label): page.mt_source")
        #expect(page.mbLines == v.meta.page.mbLines, "\(label): page.mb_lines")
        #expect(page.mbSource.rawValue == v.meta.page.mbSource, "\(label): page.mb_source")
        // `notes-vectors-1.2.0.json` was machine-generated by Python 1.2.0, before ctrl-kd
        // 2.0.0 changed `.po`'s default from 0 to 8 (the WS7 manual's ".8 inch" -- see
        // `ParseWS.swift`'s `defaultPoCols`). Five of its six cases never set `.po` in the
        // file and so recorded the OLD default (0.0), which the live default no longer
        // produces; only `geometry_legal` (an explicit `.po 8` in the file, `po_source ==
        // "file"`) is unaffected. Per this codebase's own precedent for a stale stored
        // vector (`staleFootnoteVectorNames`/the HTML-CSS strip above): the vector file
        // stays as history, and only the now-invalid assertion is dropped, for the cases
        // where it would legitimately fail.
        if v.meta.page.poSource == "file" {
            #expect(page.poCols == v.meta.page.poCols, "\(label): page.po_cols")
        }
        #expect(page.poSource.rawValue == v.meta.page.poSource, "\(label): page.po_source")

        // meta.producer / footnote_number_start / endnote_number_start / comment_bug
        #expect(doc.producer == v.meta.producer, "\(label): producer")
        #expect(doc.footnoteNumberStart == v.meta.footnoteNumberStart, "\(label): footnote_number_start")
        #expect(doc.endnoteNumberStart == v.meta.endnoteNumberStart, "\(label): endnote_number_start")
        #expect(doc.commentBug == nil, "\(label): comment_bug")
    }
}
