import CtrlKD
import Foundation
import Testing
import TestSupport
@testable import SoftReturnShared

/// Document Info's rows and the WordStar version names.
@Suite @MainActor struct DocumentInfoTests {
    static func state(_ text: String) throws -> (DocumentState, UserDefaults, String) {
        let suite = "DocumentInfoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (try DocumentState(data: Array(text.utf8), settings: SettingsStore(defaults: defaults)), defaults, suite)
    }

    @Test func theEightFileRowsComeInTheFixedOrder() {
        let rows = DocumentInfo.fileRows(url: nil, kind: "Plain text", location: nil, pageSize: "US Letter", pages: "3")
        #expect(rows.map(\.label) == DocumentInfo.fileLabels)
        #expect(rows.map(\.label) == ["File Name", "Kind", "Size", "Where", "Created", "Modified", "Page Size", "Pages"])
        #expect(rows.first { $0.label == "Kind" }?.value == "Plain text")
        #expect(rows.last?.value == "3")
        // No file: every figure about the file reads "—".
        for label in ["File Name", "Size", "Where", "Created", "Modified"] {
            #expect(rows.first { $0.label == label }?.value == "—", "\(label)")
        }
    }

    @Test func aFileReportsItsNameSizeAndTheWhereTheCallerGave() throws {
        let scratch = try TestScratch(prefix: "DocumentInfoTests")
        defer { scratch.remove() }
        let file = scratch.url.appendingPathComponent("OLDTIMES.WS")
        try Data(repeating: 0x41, count: 2048).write(to: file)

        let mac = DocumentInfo.getInfoRows(url: file, kind: "k", location: scratch.url.path)
        #expect(mac.first { $0.label == "File Name" }?.value == "OLDTIMES.WS")
        #expect(mac.first { $0.label == "Where" }?.value == scratch.url.path)
        #expect(mac.first { $0.label == "Size" }?.value != "—")
        #expect(mac.first { $0.label == "Created" }?.value != "—")
        #expect(mac.first { $0.label == "Modified" }?.value != "—")

        let phone = DocumentInfo.getInfoRows(url: file, kind: "k", location: "On My iPhone")
        #expect(phone.first { $0.label == "Where" }?.value == "On My iPhone")
    }

    @Test func aWindowWithNoFileShowsAllEightRowsAsDashes() {
        let rows = DocumentInfo.emptyFileRows()
        #expect(rows.map(\.label) == DocumentInfo.fileLabels)
        #expect(rows.allSatisfy { $0.value == "—" })
    }

    @Test func documentRowsCountWordsCharactersAndNotes() throws {
        let (state, defaults, suite) = try Self.state("One two three.\r\nFour five.\r\n")
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = DocumentInfo.documentRows(state: state, style: .native)
        #expect(rows.map(\.label) == ["Word Count", "Character Count", "Fonts", "Notes", "Margins"])
        #expect(rows[0].value == "5")
        #expect((Int(rows[1].value) ?? 0) >= 24)
        #expect(rows[2].value == "—")
        #expect(rows[3].value == "Footnotes 0 · Endnotes 0 · Annotations 0 · Comments 0")
    }

    @Test func versionNamesComeInThreeLengths() {
        #expect(Variant.allCasesInOrder.map(\.shortName) == ["WS4", "WS5+", "Printstream", "Text", "Binary"])
        #expect(Variant.allCasesInOrder.map(\.longName) == [
            "WordStar 4", "WordStar 5+", "WordStar print stream", "Plain text", "Binary data",
        ])
        #expect(Variant.allCasesInOrder.map(\.kindName) == [
            "WordStar 4 document", "WordStar 5+ document", "WordStar print stream", "Plain text", "Not a document",
        ])
    }
}

private extension Variant {
    static let allCasesInOrder: [Variant] = [.ws4, .ws5plus, .printstream, .text, .binary]
}
