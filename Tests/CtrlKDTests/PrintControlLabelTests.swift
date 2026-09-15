/// Planning #270 item 36, Jon's ruling 2026-09-13: "Print controls aren't supposed to
/// be visible except in Show Invisibles."
///
/// A 0x0F user print control carries a SCREEN display string — WordStar shows it in the
/// EDITOR where the control sits (`sawyer/LSRBOX/LSRBOX.WS` labels its rules
/// `«Shaded ...»`, LJ6DTP has 41 of them) — and sends the raw printer payload to the
/// paper instead, the block advancing by its own declared HMI word. The label is an
/// editor artifact, so NO view and NO export may show it: Printed, the Native layout
/// JSON, Modern, RTF, HTML, plain text and Markdown all drop it, and only the app's
/// Show Invisibles draws it, from the ONE place the layout contract still publishes it
/// (`invisibles["print_controls"]`, format version 9).
///
/// One test per surface, by name, so a regression names the surface that broke. Port of
/// ctrl-kd's `tests/test_print_control_labels_invisible.py` (commit `bef1abd`).
/// Synthetic fixture only.
import Foundation
import Testing
@testable import CtrlKD

private let printControlLabel = "EMPTY 3-dot rule"
private let printControlHMI = 900       // 5 print columns at 180 HMI units each

private func ws7Block(_ cmd: UInt8, _ content: [UInt8]) -> [UInt8] {
    let count = UInt16(content.count + 4)
    let le: [UInt8] = [UInt8(count & 0xFF), UInt8(count >> 8)]
    var out: [UInt8] = [0x1D]
    out += le
    out += [cmd]
    out += content
    out += le
    out += [0x1D]
    return out
}

private func printControlDocument() -> Document {
    let shown = [UInt8](printControlLabel.utf8)
    let payload = [UInt8]("\u{1B}*c2370a0003b0P".utf8)
    var content: [UInt8] = [UInt8(printControlHMI & 0xFF), UInt8(printControlHMI >> 8)]
    content += [UInt8(shown.count)]
    content += shown
    content += payload
    let control = ws7Block(0x0F, content)
    var bytes = ws7Block(0x00, [0x70] + [UInt8](repeating: 0, count: 15))
    bytes += [UInt8]("Before the control ".utf8) + control
    bytes += [UInt8](" after the control".utf8) + [0x0D, 0x0A]
    bytes += [UInt8]("Plain paragraph of ordinary prose padding for detection.".utf8)
    bytes += [0x0D, 0x0A]
    return parseWS(bytes)
}

private func layoutObject(_ options: EmitOptions = EmitOptions()) throws -> [String: Any] {
    let json = emitLayout(printControlDocument(), mode: .modern, options: options)
    return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                        as? [String: Any])
}

// MARK: - the exports

@Test func printControlLabelNeverAppearsInPlainText() {
    for mode in [EmitMode.printed, .modern] {
        let out = emitText(printControlDocument(), mode: mode, options: EmitOptions())
        #expect(!out.contains(printControlLabel))
        #expect(out.contains("Before the control"))
    }
}

@Test func printControlLabelNeverAppearsInMarkdown() {
    for mode in [EmitMode.printed, .modern] {
        let out = emitMarkdown(printControlDocument(), mode: mode, options: EmitOptions())
        #expect(!out.contains(printControlLabel))
        #expect(out.contains("Before the control"))
    }
}

@Test func printControlLabelNeverAppearsInHTML() {
    for mode in [EmitMode.printed, .modern] {
        let out = emitHTML(printControlDocument(), mode: mode, options: EmitOptions())
        #expect(!out.contains(printControlLabel))
        #expect(out.contains("Before the control"))
    }
}

@Test func printControlLabelNeverAppearsInRTF() {
    for mode in [EmitMode.printed, .modern] {
        let out = emitRTF(printControlDocument(), mode: mode, options: EmitOptions())
        #expect(!out.contains(printControlLabel))
        #expect(out.contains("Before the control"))
    }
}

@Test func printControlLabelNeverAppearsInEitherPDF() {
    for mode in [EmitMode.printed, .modern] {
        let pdf = emitPDF(printControlDocument(), mode: mode, options: EmitOptions())
        // the label has to be looked for in the DRAWN text, not the raw
        // (Flate-compressed) file, where the assertion would pass for the wrong reason
        let drawn = contentSpans(pdf).map(\.text).joined(separator: " ")
        #expect(!drawn.contains(printControlLabel))
        #expect(drawn.contains("Before"))
    }
}

// MARK: - the Native layout JSON

@Test func printControlLabelNeverAppearsInThePrintedLayoutJSON() throws {
    // The defect this ruling actually found. Every other surface already dropped the
    // label; the printed page-lines in the `layout` JSON -- the contract the Native view
    // draws from -- published `segments` verbatim, label and all. They now publish the
    // control's declared printed WIDTH as spaces, the same swap the printed text/HTML
    // paths and the PDF writer have always made.
    let root = try layoutObject()
    let printed = try #require(root["printed"] as? [String: Any])
    let printedJSON = String(decoding: try JSONSerialization.data(withJSONObject: printed),
                             as: UTF8.self)
    #expect(!printedJSON.contains(printControlLabel))
    let modern = try #require(root["modern"] as? [String: Any])
    let modernJSON = String(decoding: try JSONSerialization.data(withJSONObject: modern),
                            as: UTF8.self)
    #expect(!modernJSON.contains(printControlLabel))
    let pages = try #require(printed["pages"] as? [[String: Any]])
    var padded: [String: Any]?
    for page in pages {
        for line in (page["lines"] as? [[String: Any]] ?? []) {
            for segment in (line["segments"] as? [[String: Any]] ?? []) {
                let styles = segment["styles"] as? [String] ?? []
                if styles.contains(where: { $0.hasPrefix("pctl") }) { padded = segment }
            }
        }
    }
    let segment = try #require(padded, "the print control's own segment must still exist")
    #expect(segment["text"] as? String == "     ")            // 900 HMI / 180 = 5 columns
    #expect((segment["styles"] as? [String] ?? []).contains("pctl\(printControlHMI)"))
}

@Test func showInvisiblesIsTheOnePlaceThePrintControlLabelSurvives() throws {
    // ...and it has to survive SOMEWHERE, or the ruling's own exception ("only Show
    // Invisibles shows them") has nothing to draw. Format version 9 publishes it in the
    // invisibles layer, located on the printed page-line segment it belongs to.
    let root = try layoutObject()
    #expect((root["version"] as? Int ?? 0) >= 9)
    let invisibles = try #require(root["invisibles"] as? [String: Any])
    let controls = try #require(invisibles["print_controls"] as? [[String: Any]])
    #expect(controls.count == 1)
    let control = try #require(controls.first)
    #expect(control["label"] as? String == printControlLabel)
    #expect(control["hmi"] as? Int == printControlHMI)
    #expect(control["columns"] as? Int == 5)

    let printed = try #require(root["printed"] as? [String: Any])
    let pages = try #require(printed["pages"] as? [[String: Any]])
    let page = pages[try #require(control["page"] as? Int) - 1]
    let line = (page["lines"] as? [[String: Any]] ?? [])[try #require(control["line"] as? Int)]
    let segment = (line["segments"] as? [[String: Any]] ?? [])[try #require(control["segment"] as? Int)]
    #expect((segment["styles"] as? [String] ?? []).contains(where: { $0.hasPrefix("pctl") }))
}

@Test func aDocumentWithNoPrintControlPublishesAnEmptyList() throws {
    // Purely additive: a document with no 0x0F control anywhere emits an empty list,
    // not a missing key, and nothing else about its JSON moves.
    var bytes = ws7Block(0x00, [0x70] + [UInt8](repeating: 0, count: 15))
    bytes += [UInt8]("Ordinary prose with no print control at all.".utf8) + [0x0D, 0x0A]
    let json = emitLayout(parseWS(bytes), mode: .modern, options: EmitOptions())
    let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                            as? [String: Any])
    let invisibles = try #require(root["invisibles"] as? [String: Any])
    #expect((invisibles["print_controls"] as? [[String: Any]])?.isEmpty == true)
    #expect((invisibles["modern_print_controls"] as? [[String: Any]])?.isEmpty == true)
}

// MARK: - MODERN's own Show Invisibles
//
// Planning #264 running list, the batch-23 finding: Modern's Show Invisibles showed NO
// print-control label at all. Item 36 gave the printed page-lines a channel for it
// (version 9) and left Modern with none — `modernSemanticFlow` drops the span, and the
// POSITION went with the label. Version 10 is the Modern twin of that: label plus
// position in the invisibles layer, never on a rendering surface. Port of ctrl-kd's own
// four tests in `tests/test_print_control_labels_invisible.py`.

@Test func modernPublishesTheLabelAndWhereItSat() throws {
    // `item` indexes `modern["items"]`; `run` is the index of the run the control
    // PRECEDES, so the app can draw the marker between two runs without re-deriving
    // anything. The fixture's control sits between "Before the control " and " after
    // the control" — run 1 of item 0.
    let root = try layoutObject()
    #expect((root["version"] as? Int ?? 0) >= 10)
    let invisibles = try #require(root["invisibles"] as? [String: Any])
    let controls = try #require(invisibles["modern_print_controls"] as? [[String: Any]])
    #expect(controls.count == 1)
    let control = try #require(controls.first)
    #expect(control["label"] as? String == printControlLabel)
    #expect(control["hmi"] as? Int == printControlHMI)
    #expect(control["columns"] as? Int == 5)
    #expect(control["run"] as? Int == 1)
    let modern = try #require(root["modern"] as? [String: Any])
    let items = try #require(modern["items"] as? [[String: Any]])
    let item = items[try #require(control["item"] as? Int)]
    #expect(item["kind"] as? String == "para")
    let runs = try #require(item["runs"] as? [[String: Any]])
    #expect(runs.map { $0["text"] as? String ?? "" }
            == ["Before the control ", " after the control"])
}

@Test func modernRunsStillCarryNoTraceOfTheControl() throws {
    // The flow still DROPS the span: the label is not ink, in Modern or anywhere else.
    // The invisibles layer is the only place it exists.
    let root = try layoutObject()
    let modern = try #require(root["modern"] as? [String: Any])
    for item in (modern["items"] as? [[String: Any]] ?? []) {
        for run in (item["runs"] as? [[String: Any]] ?? []) {
            #expect(!(run["text"] as? String ?? "").contains(printControlLabel))
        }
    }
}

@Test func aControlAtTheEndOfALineRecordsTheRunCount() throws {
    // "After the last run on the line" has to be expressible, and `runs.count` is how:
    // there is no following run to point at.
    let shown = [UInt8](printControlLabel.utf8)
    var content: [UInt8] = [UInt8(printControlHMI & 0xFF), UInt8(printControlHMI >> 8)]
    content += [UInt8(shown.count)] + shown + [UInt8]("\u{1B}*c2370a0003b0P".utf8)
    var bytes = ws7Block(0x00, [0x70] + [UInt8](repeating: 0, count: 15))
    bytes += [UInt8]("Text then the control".utf8) + ws7Block(0x0F, content) + [0x0D, 0x0A]
    bytes += [UInt8]("Plain paragraph of ordinary prose padding.".utf8) + [0x0D, 0x0A]
    let json = emitLayout(parseWS(bytes), mode: .modern, options: EmitOptions())
    let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                            as? [String: Any])
    let invisibles = try #require(root["invisibles"] as? [String: Any])
    let control = try #require((invisibles["modern_print_controls"]
                                as? [[String: Any]])?.first)
    let modern = try #require(root["modern"] as? [String: Any])
    let items = try #require(modern["items"] as? [[String: Any]])
    let runs = items[try #require(control["item"] as? Int)]["runs"] as? [[String: Any]]
    #expect(control["run"] as? Int == (runs?.count ?? -1))
}

@Test func theTwoPrintControlListsAreIndependent() throws {
    // They are not the same list seen twice: their coordinates locate different things
    // (a printed page-line segment vs a position in `modern["items"]`) and their counts
    // genuinely differ — a running head's own control repeats on every printed page and
    // reaches no Modern item at all. Both are present, both name this document's one
    // body control.
    let root = try layoutObject()
    let invisibles = try #require(root["invisibles"] as? [String: Any])
    let printed = try #require(invisibles["print_controls"] as? [[String: Any]])
    let modern = try #require(invisibles["modern_print_controls"] as? [[String: Any]])
    #expect(printed.map { $0["label"] as? String ?? "" } == [printControlLabel])
    #expect(modern.map { $0["label"] as? String ?? "" } == [printControlLabel])
    #expect(Set(printed[0].keys) == ["page", "line", "segment", "label", "hmi", "columns"])
    #expect(Set(modern[0].keys) == ["item", "run", "label", "hmi", "columns"])
}
