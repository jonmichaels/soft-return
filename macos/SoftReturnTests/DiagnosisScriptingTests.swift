import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// `DiagnosisScripting.record(from:)` — turning `DocumentOperations.DiagnosisResult`
/// into the `diagnosis` record `SoftReturn.sdef` promises. `comments present` and
/// `margins` are read out of `DiagnosisResult.info` the way `documentInfo`'s own doc
/// comment describes its `notes`/`page` fields (`notes.comment`, `page.*_lines`/
/// `page.po_cols`) — these tests pin that reading against hand-built `InfoValue` trees
/// so a change to either shape is caught here, independent of any real fixture file.
@Suite struct DiagnosisScriptingTests {

    private static func info(notesComment: Int?, page: [String: InfoValue]?) -> InfoValue {
        var fields: [String: InfoValue] = [:]
        if let notesComment {
            fields["notes"] = .object([
                "footnote": .int(0), "endnote": .int(0),
                "annotation": .int(0), "comment": .int(notesComment),
            ])
        }
        if let page {
            fields["page"] = .object(page)
        }
        return .object(fields)
    }

    @Test func recordCarriesVariantDotCommandsAndUnknownCodesThrough() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 5, dotCommands: [".pl", ".mt"], unknownCodeCount: 2,
            info: Self.info(notesComment: 0, page: nil))
        let record = DiagnosisScripting.record(from: result)

        #expect((record["variant"] as? NSNumber)?.uint32Value == ScriptingEnumCoding.code(for: .ws4))
        #expect(record["pages"] as? Int == 5)
        #expect(record["dotCommands"] as? [String] == [".pl", ".mt"])
        #expect(record["unknownCodes"] as? Int == 2)
    }

    @Test func recordOmitsPagesWhenPageCountIsNil() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .binary, pageCount: nil, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: nil, page: nil))
        let record = DiagnosisScripting.record(from: result)
        #expect(record["pages"] == nil)
    }

    /// `.binary` has no enumerator in the ruled `variant` list (ws4/ws5plus/printstream/
    /// text) — the CLI's own `--variant` excludes it too ("forcing this is not a
    /// convertible file is not an override anyone wants"). The field is simply absent
    /// rather than smuggling in a code nothing in the dictionary declares.
    @Test func recordOmitsVariantEntirelyForBinaryBytes() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .binary, pageCount: nil, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: nil, page: nil))
        #expect(DiagnosisScripting.record(from: result)["variant"] == nil)
    }

    @Test func commentsPresentIsTrueOnlyWhenTheCommentCountIsPositive() {
        let withComments = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 1, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: 2, page: nil))
        let withoutComments = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 1, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: 0, page: nil))
        let missingNotesField = DocumentOperations.DiagnosisResult(
            variant: .binary, pageCount: nil, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: nil, page: nil))

        #expect(DiagnosisScripting.record(from: withComments)["commentsPresent"] as? Bool == true)
        #expect(DiagnosisScripting.record(from: withoutComments)["commentsPresent"] as? Bool == false)
        #expect(DiagnosisScripting.record(from: missingNotesField)["commentsPresent"] as? Bool == false)
    }

    @Test func marginsReadsThePageObjectIntoAPageSettingsRecord() throws {
        let result = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 1, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: 0, page: [
                "mt_lines": .double(3.0), "mb_lines": .double(6.0), "po_cols": .double(8.0),
                "hm_lines": .double(1.0), "fm_lines": .double(1.0), "pl_lines": .double(66.0),
                "size_name": .string("Letter"),   // a field diagnose ignores for margins
            ]))
        let record = DiagnosisScripting.record(from: result)
        let margins = try #require(record["margins"] as? [String: Any])
        #expect(margins["marginTop"] as? Double == 3.0)
        #expect(margins["marginBottom"] as? Double == 6.0)
        #expect(margins["pageOffset"] as? Double == 8.0)
    }

    @Test func marginsIsAbsentWhenThereIsNoPageObjectAtAll() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .binary, pageCount: nil, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: nil, page: nil))
        #expect(DiagnosisScripting.record(from: result)["margins"] == nil)
    }

    // MARK: - descriptor (job 207: the reply-packagable typed record)

    @Test func descriptorCarriesVariantDotCommandsAndUnknownCodesThrough() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 5, dotCommands: [".pl", ".mt"], unknownCodeCount: 2,
            info: Self.info(notesComment: 0, page: nil))
        let descriptor = DiagnosisScripting.descriptor(from: result)

        #expect(descriptor.descriptorType == ScriptingCodes.fourCharCode("SRrd"))
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd1"))?.enumCodeValue == ScriptingEnumCoding.code(for: .ws4))
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd2"))?.int32Value == 5)
        let dotCommands = descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd3"))
        #expect(dotCommands?.numberOfItems == 2)
        #expect(dotCommands?.atIndex(1)?.stringValue == ".pl")
        #expect(dotCommands?.atIndex(2)?.stringValue == ".mt")
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd4"))?.int32Value == 2)
    }

    @Test func descriptorOmitsPagesWhenPageCountIsNil() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .binary, pageCount: nil, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: nil, page: nil))
        let descriptor = DiagnosisScripting.descriptor(from: result)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd2")) == nil)
    }

    @Test func descriptorOmitsVariantEntirelyForBinaryBytes() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .binary, pageCount: nil, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: nil, page: nil))
        let descriptor = DiagnosisScripting.descriptor(from: result)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd1")) == nil)
    }

    @Test func descriptorCommentsPresentIsTrueOnlyWhenTheCommentCountIsPositive() {
        let withComments = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 1, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: 2, page: nil))
        let withoutComments = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 1, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: 0, page: nil))

        #expect(DiagnosisScripting.descriptor(from: withComments)
            .forKeyword(ScriptingCodes.fourCharCode("SRd5"))?.booleanValue == true)
        #expect(DiagnosisScripting.descriptor(from: withoutComments)
            .forKeyword(ScriptingCodes.fourCharCode("SRd5"))?.booleanValue == false)
    }

    @Test func descriptorMarginsNestsAPageSettingsRecord() throws {
        let result = DocumentOperations.DiagnosisResult(
            variant: .ws4, pageCount: 1, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: 0, page: [
                "mt_lines": .double(3.0), "mb_lines": .double(6.0), "po_cols": .double(8.0),
                "hm_lines": .double(1.0), "fm_lines": .double(1.0), "pl_lines": .double(66.0),
            ]))
        let descriptor = DiagnosisScripting.descriptor(from: result)
        let margins = try #require(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd6")))
        #expect(margins.descriptorType == ScriptingCodes.fourCharCode("SRrp"))
        #expect(margins.forKeyword(ScriptingCodes.fourCharCode("SRr1"))?.doubleValue == 3.0)
        #expect(margins.forKeyword(ScriptingCodes.fourCharCode("SRr2"))?.doubleValue == 6.0)
        #expect(margins.forKeyword(ScriptingCodes.fourCharCode("SRr3"))?.doubleValue == 8.0)
    }

    @Test func descriptorMarginsIsAbsentWhenThereIsNoPageObjectAtAll() {
        let result = DocumentOperations.DiagnosisResult(
            variant: .binary, pageCount: nil, dotCommands: [], unknownCodeCount: 0,
            info: Self.info(notesComment: nil, page: nil))
        let descriptor = DiagnosisScripting.descriptor(from: result)
        #expect(descriptor.forKeyword(ScriptingCodes.fourCharCode("SRd6")) == nil)
    }

    // MARK: - against a real fixture, through DocumentOperations itself

    @Test func recordMatchesADocumentOperationsDiagnoseCallOnARealFixture() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("narrow.ws4")
        let data = [UInt8](try Data(contentsOf: url))
        let diagnosis = DocumentOperations.diagnose(data: data)

        let record = DiagnosisScripting.record(from: diagnosis)

        #expect((record["variant"] as? NSNumber)?.uint32Value == ScriptingEnumCoding.code(for: .ws4))
        #expect(record["dotCommands"] as? [String] == diagnosis.dotCommands)
        #expect(record["unknownCodes"] as? Int == diagnosis.unknownCodeCount)
        // narrow.ws4 sets .mt/.mb/.po itself (DocumentOperationsTests), so margins must
        // have made it through.
        #expect(record["margins"] != nil)
    }
}
