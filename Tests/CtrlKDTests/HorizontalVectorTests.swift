import Foundation
import Testing
@testable import CtrlKD

/// Equivalence proof against `Resources/horizontal-vectors-2.0.0.json` — machine-generated
/// by the Python ctrl-kd 2.0.0 reference for "physical lines and horizontal geometry": 4
/// `line_cases` (each with `input_hex`, per-block physical lines + `soft` flags + merged
/// texts, and the FULL expected output of `emit_text` printed/modern, `emit_markdown`/
/// `rtf`/`html` modern), 6 `geometry_cases` (`.cw`/`.po` parse results plus
/// `printed_size`/`printed_left`), 3 `pdf_cases` (the first `[Tf-size, x, y]` STRING
/// triples from the printed PDF content stream), and a `printstream` entry.
///
/// Every string output is asserted by EXACT equality (the byte-parity claim); `printed_left`
/// is asserted as `Double` equality; the PDF triples are asserted as STRING equality — not a
/// numeric re-parse, since a numeric comparison could paper over a formatting difference
/// Python's own bytes would never produce.
///
/// `Foundation` is imported here for `JSONDecoder`/`Bundle` only; the `CtrlKD` library
/// target itself stays Foundation-free.

private struct PhysicalLineVector: Decodable {
    let text: String
    let soft: Bool
}

private struct HBlockVector: Decodable {
    let kind: String
    let physical: [PhysicalLineVector]
    let merged: [String]
}

private struct LineCase: Decodable {
    let name: String
    let inputHex: String
    let blocks: [HBlockVector]
    let emitTextPrinted: String
    let emitTextModern: String
    let emitMarkdownModern: String
    let emitRtfModern: String
    let emitHtmlModern: String

    enum CodingKeys: String, CodingKey {
        case name
        case inputHex = "input_hex"
        case blocks
        case emitTextPrinted = "emit_text_printed"
        case emitTextModern = "emit_text_modern"
        case emitMarkdownModern = "emit_markdown_modern"
        case emitRtfModern = "emit_rtf_modern"
        case emitHtmlModern = "emit_html_modern"
    }
}

private struct HGeometryCase: Decodable {
    let name: String
    let inputHex: String
    let cw120: Double
    let cwSource: String
    let poCols: Double
    let poSource: String
    let printedSize: Int
    let printedLeft: Double

    enum CodingKeys: String, CodingKey {
        case name
        case inputHex = "input_hex"
        case cw120 = "cw_120"
        case cwSource = "cw_source"
        case poCols = "po_cols"
        case poSource = "po_source"
        case printedSize = "printed_size"
        case printedLeft = "printed_left"
    }
}

private struct PdfCase: Decodable {
    let name: String
    let inputHex: String
    let opsFirst4: [[String]]

    enum CodingKeys: String, CodingKey {
        case name
        case inputHex = "input_hex"
        case opsFirst4 = "ops_first4"
    }
}

private struct HPrintstreamEntry: Decodable {
    let printedSize: Int
    let printedLeft: Double

    enum CodingKeys: String, CodingKey {
        case printedSize = "printed_size"
        case printedLeft = "printed_left"
    }
}

private struct HorizontalVectorFile: Decodable {
    let note: String
    let lineCases: [LineCase]
    let geometryCases: [HGeometryCase]
    let pdfCases: [PdfCase]
    let printstream: HPrintstreamEntry

    enum CodingKeys: String, CodingKey {
        case note
        case lineCases = "line_cases"
        case geometryCases = "geometry_cases"
        case pdfCases = "pdf_cases"
        case printstream
    }
}

private func loadHorizontalVectors() throws -> HorizontalVectorFile {
    let url = try #require(
        Bundle.module.url(forResource: "horizontal-vectors-2.0.0", withExtension: "json"),
        "horizontal-vectors-2.0.0.json missing from the test bundle"
    )
    return try JSONDecoder().decode(HorizontalVectorFile.self, from: Data(contentsOf: url))
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

/// The first `limit` `[Tf-size, Td-x, Td-y]` STRING triples from a PDF's content streams —
/// the operator shape is `BT /F1 12 Tf 0 Ts 72.0 708.0 Td (text) Tj ET`, so the size sits one
/// field before `Tf` and the x/y pair sits the two fields before `Td`.
private func pdfOpsTriples(_ pdf: [UInt8], limit: Int) -> [[String]] {
    var out: [[String]] = []
    for line in latin1(pdf).split(separator: "\n", omittingEmptySubsequences: false) {
        guard line.contains(" Td (") else { continue }
        let fields = line.split(separator: " ")
        guard let tfIndex = fields.firstIndex(of: "Tf"), tfIndex >= 1,
              let tdIndex = fields.firstIndex(of: "Td"), tdIndex >= 2 else { continue }
        out.append([String(fields[tfIndex - 1]), String(fields[tdIndex - 2]), String(fields[tdIndex - 1])])
        if out.count == limit { return out }
    }
    return out
}

@Test func horizontalLineVectorsMatchPython200() throws {
    // Direct `parseWS`, matching the Python reference's own tests. Every block's PHYSICAL
    // lines (text + `soft`) and `mergedLines` output must reproduce exactly, and so must
    // every emitter's full output — the byte-parity claim ctrl-kd 2.0.0 shipped with.
    let file = try loadHorizontalVectors()
    #expect(file.lineCases.count == 4)

    for v in file.lineCases {
        let label = "horizontal line vector \(v.name)"
        let doc = parseWS(bytesFromHex(v.inputHex))
        #expect(doc.blocks.count == v.blocks.count, "\(label): block count")

        for (b, wantBlock) in v.blocks.enumerated() where b < doc.blocks.count {
            let gotBlock = doc.blocks[b]
            #expect(gotBlock.kind.rawValue == wantBlock.kind, "\(label) block \(b): kind")
            #expect(gotBlock.lines.count == wantBlock.physical.count,
                    "\(label) block \(b): physical line count")
            for (l, wantLine) in wantBlock.physical.enumerated() where l < gotBlock.lines.count {
                #expect(gotBlock.lines[l].text() == wantLine.text,
                        "\(label) block \(b) line \(l): text")
                #expect(gotBlock.lines[l].soft == wantLine.soft,
                        "\(label) block \(b) line \(l): soft")
            }
            let merged = mergedLines(gotBlock).map { $0.text() }
            #expect(merged == wantBlock.merged, "\(label) block \(b): merged")
        }

        #expect(emitText(doc, mode: .printed) == v.emitTextPrinted, "\(label): emit_text printed")
        #expect(emitText(doc, mode: .modern) == v.emitTextModern, "\(label): emit_text modern")
        #expect(emitMarkdown(doc, mode: .modern) == v.emitMarkdownModern,
                "\(label): emit_markdown modern")
        #expect(emitRTF(doc, mode: .modern) == v.emitRtfModern, "\(label): emit_rtf modern")
        #expect(emitHTML(doc, mode: .modern) == v.emitHtmlModern, "\(label): emit_html modern")
    }
}

@Test func horizontalGeometryVectorsMatchPython200() throws {
    let file = try loadHorizontalVectors()
    #expect(file.geometryCases.count == 6)

    for v in file.geometryCases {
        let label = "horizontal geometry vector \(v.name)"
        let doc = parseWS(bytesFromHex(v.inputHex))
        let page = try #require(doc.page, "\(label): page must be resolved")
        #expect(page.cw120 == v.cw120, "\(label): cw_120")
        #expect(page.cwSource.rawValue == v.cwSource, "\(label): cw_source")
        #expect(page.poCols == v.poCols, "\(label): po_cols")
        #expect(page.poSource.rawValue == v.poSource, "\(label): po_source")

        let size = printedSize(doc)
        #expect(size == v.printedSize, "\(label): printed_size")
        // Double equality: this is the byte-parity claim for the exact IEEE-754 float
        // Python's own `_printed_left` produces, same operation order and all.
        #expect(printedLeft(doc, size: size) == v.printedLeft, "\(label): printed_left")
    }
}

@Test func horizontalPDFVectorsMatchPython200ByteForByte() throws {
    let file = try loadHorizontalVectors()
    #expect(file.pdfCases.count == 3)

    for v in file.pdfCases {
        let label = "horizontal pdf vector \(v.name)"
        let doc = parseWS(bytesFromHex(v.inputHex))
        let pdf = emitPDF(doc, mode: .printed)
        let got = pdfOpsTriples(pdf, limit: v.opsFirst4.count)
        #expect(got == v.opsFirst4, "\(label): ops_first4")
    }
}

@Test func horizontalPrintstreamKeepsFixedSizeAndMargin() throws {
    // A print stream carries no page geometry at all (`doc.page == nil`), so `printedSize`/
    // `printedLeft` fall back to the same fixed size/margin every print-to-disk capture
    // always used — matching the Python reference's own `_printed_size`/`_printed_left`
    // nil-geometry branch.
    let file = try loadHorizontalVectors()
    let doc = Document()
    #expect(doc.page == nil, "printstream: page must be nil")
    let size = printedSize(doc)
    #expect(size == file.printstream.printedSize, "printstream: printed_size")
    #expect(printedLeft(doc, size: size) == file.printstream.printedLeft, "printstream: printed_left")
}
