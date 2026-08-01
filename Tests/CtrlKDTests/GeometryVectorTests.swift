import Foundation
import Testing
@testable import CtrlKD

/// Equivalence proof against `Resources/geometry-vectors-2.0.0.json` — the LIVE parity
/// target for the vertical page-geometry model, machine-regenerated from the current Python
/// reference (ctrl-kd 2.0.0) whenever it moves: 19 `parse_ws` cases plus one `parse_printstream`
/// case. Every field of the resolved `page` meta (including every `*_source`), `printed_cap`,
/// `printed_top`, and `printed_lead` must reproduce exactly; where the vector also carries
/// `printed_page_line_counts` or `pdf_td_y_first3`, those are asserted too — the latter as
/// STRING equality, which is the byte-parity claim for a fractional `.lh`-derived lead.
///
/// `Foundation` is imported here for `JSONDecoder`/`Bundle` only; the `CtrlKD` library
/// target itself stays Foundation-free.

private struct GeometryPageVector: Decodable {
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
    let hmLines: Double
    let hmSource: String
    let fmLines: Double
    let fmSource: String
    let lh48: Double
    let lhSource: String
    let ls: Double
    let lsSource: String
    let textLines: Int

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
        case hmLines = "hm_lines"
        case hmSource = "hm_source"
        case fmLines = "fm_lines"
        case fmSource = "fm_source"
        case lh48 = "lh_48"
        case lhSource = "lh_source"
        case ls
        case lsSource = "ls_source"
        case textLines = "text_lines"
    }
}

private struct GeometryCase: Decodable {
    let name: String
    let inputHex: String
    let page: GeometryPageVector
    let printedCap: Int
    let printedTop: Int
    let printedLead: Double
    /// Present only for the two pagination cases (`pagination_55`, `pagination_lh16_27`).
    let printedPageLineCounts: [Int]?
    /// Present only for the two byte-parity cases (`pdf_coords_mt6_lh16`, `pdf_coords_lh_cm`).
    let pdfTdYFirst3: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case inputHex = "input_hex"
        case page
        case printedCap = "printed_cap"
        case printedTop = "printed_top"
        case printedLead = "printed_lead"
        case printedPageLineCounts = "printed_page_line_counts"
        case pdfTdYFirst3 = "pdf_td_y_first3"
    }
}

private struct PrintstreamEntry: Decodable {
    let printedCap: Int
    let printedTop: Int
    let printedLead: Double

    enum CodingKeys: String, CodingKey {
        case printedCap = "printed_cap"
        case printedTop = "printed_top"
        case printedLead = "printed_lead"
    }
}

private struct GeometryVectorFile: Decodable {
    let note: String
    let cases: [GeometryCase]
    let printstream: PrintstreamEntry
}

private func loadGeometryVectors() throws -> GeometryVectorFile {
    let url = try #require(
        Bundle.module.url(forResource: "geometry-vectors-2.0.0", withExtension: "json"),
        "geometry-vectors-2.0.0.json missing from the test bundle"
    )
    return try JSONDecoder().decode(GeometryVectorFile.self, from: Data(contentsOf: url))
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

/// The first `limit` `Td` y-coordinates in a PDF's content streams, as the EXACT strings the
/// writer produced. String equality (not a numeric re-parse) is the point: this is the
/// byte-parity claim for a fractional `.lh`-derived lead, where a numeric comparison could
/// paper over a formatting difference Python's own bytes would never produce.
private func pdfTdYStrings(_ pdf: [UInt8], limit: Int) -> [String] {
    var ys: [String] = []
    for line in latin1(pdf).split(separator: "\n", omittingEmptySubsequences: false) {
        guard line.contains(" Td (") else { continue }
        let fields = line.split(separator: " ")
        guard let tdIndex = fields.firstIndex(of: "Td"), tdIndex >= 1 else { continue }
        ys.append(String(fields[tdIndex - 1]))
        if ys.count == limit { return ys }
    }
    return ys
}

@Test func geometryVectorsMatchPython130() throws {
    // Direct `parseWS`, matching the Python reference's own tests (`core.parse_ws(...)`,
    // not the auto-detecting front door) — page geometry resolves regardless of variant, so
    // this is the same call the vectors were generated against.
    let file = try loadGeometryVectors()
    #expect(file.cases.count == 19)

    for v in file.cases {
        let label = "geometry vector \(v.name)"
        let doc = parseWS(bytesFromHex(v.inputHex))
        let page = try #require(doc.page, "\(label): page must be resolved")

        #expect(page.plLines == v.page.plLines, "\(label): pl_lines")
        #expect(page.heightIn == v.page.heightIn, "\(label): height_in")
        #expect(page.sizeName == v.page.sizeName, "\(label): size_name")
        #expect(page.sizeSource.rawValue == v.page.sizeSource, "\(label): size_source")
        #expect(page.mtLines == v.page.mtLines, "\(label): mt_lines")
        #expect(page.mtSource.rawValue == v.page.mtSource, "\(label): mt_source")
        #expect(page.mbLines == v.page.mbLines, "\(label): mb_lines")
        #expect(page.mbSource.rawValue == v.page.mbSource, "\(label): mb_source")
        // Unlike the job-NNN vector files (frozen history), this file is the LIVE parity
        // target and gets regenerated whenever the Python reference moves -- currently
        // machine-generated by ctrl-kd 2.0.0, so `.po`'s manual-stated default of 8
        // columns is recorded and asserted like every other field.
        #expect(page.poCols == v.page.poCols, "\(label): po_cols")
        #expect(page.poSource.rawValue == v.page.poSource, "\(label): po_source")
        #expect(page.hmLines == v.page.hmLines, "\(label): hm_lines")
        #expect(page.hmSource.rawValue == v.page.hmSource, "\(label): hm_source")
        #expect(page.fmLines == v.page.fmLines, "\(label): fm_lines")
        #expect(page.fmSource.rawValue == v.page.fmSource, "\(label): fm_source")
        #expect(page.lh48 == v.page.lh48, "\(label): lh_48")
        #expect(page.lhSource.rawValue == v.page.lhSource, "\(label): lh_source")
        #expect(page.ls == v.page.ls, "\(label): ls")
        #expect(page.lsSource.rawValue == v.page.lsSource, "\(label): ls_source")
        #expect(page.textLines == v.page.textLines, "\(label): text_lines")

        #expect(printedCap(doc) == v.printedCap, "\(label): printed_cap")
        #expect(printedTop(doc) == v.printedTop, "\(label): printed_top")
        #expect(printedLead(doc) == v.printedLead, "\(label): printed_lead")

        if let wantCounts = v.printedPageLineCounts {
            let pages = docToPagelines(doc, printed: true)
            #expect(pages.map(\.count) == wantCounts, "\(label): printed_page_line_counts")
        }

        if let wantYs = v.pdfTdYFirst3 {
            let pdf = emitPDF(doc, mode: .printed)
            #expect(pdfTdYStrings(pdf, limit: wantYs.count) == wantYs,
                    "\(label): pdf_td_y_first3")
        }
    }
}

@Test func geometryPrintstreamMatchesPython130() throws {
    // Print streams carry no `page` meta at all (`ParsePrintstream.swift`'s
    // `parsePrintstream` never reads a dot command), so this is the nil-geometry branch of
    // `printedCap`/`printedTop`/`printedLead` -- the full page and the fixed top/lead every
    // print-to-disk capture always used, matching the Python reference's own
    // `core.parse_printstream(b'line one\r\nline two\r\n')`.
    let file = try loadGeometryVectors()
    let doc = parsePrintstream(bytes("line one\r\nline two\r\n"))
    #expect(doc.page == nil, "printstream: page must be nil")
    #expect(printedCap(doc) == file.printstream.printedCap, "printstream: printed_cap")
    #expect(printedTop(doc) == file.printstream.printedTop, "printstream: printed_top")
    #expect(printedLead(doc) == file.printstream.printedLead, "printstream: printed_lead")
}
