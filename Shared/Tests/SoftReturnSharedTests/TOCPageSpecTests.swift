import CtrlKD
import Foundation
import Testing
@testable import SoftReturnShared

/// The table-of-contents page's content and look, as the platforms both read it.
@Suite @MainActor struct TOCPageSpecTests {
    @Test func theLookIsGeorgia14WithTightSpacingInBlackInk() {
        #expect(TOCPageSpec.bodyFontName == "Georgia")
        #expect(TOCPageSpec.headingFontName == "Georgia-Bold")
        #expect(TOCPageSpec.fontSize == 14)
        #expect(abs(TOCPageSpec.paragraphSpacing - 4.9) < 1e-9)
        #expect(TOCPageSpec.ink == (0, 0, 0))
    }

    @Test func onlyTheTwoHeadingsAreHeadings() {
        #expect(TOCPageSpec.isHeading("TABLE OF CONTENTS"))
        #expect(TOCPageSpec.isHeading("INDEX"))
        #expect(!TOCPageSpec.isHeading("Index"))
        #expect(!TOCPageSpec.isHeading("  INDEX"))
        #expect(!TOCPageSpec.isHeading(""))
    }

    @Test func aDocumentWithoutEntriesHasNoPage() throws {
        let suite = "TOCPageSpecTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = try DocumentState(data: Array("Just text.\r\n".utf8), settings: SettingsStore(defaults: defaults))
        #expect(TOCPageSpec.lines(for: state.document) == nil)
    }

    @Test func entriesCompileToHeadedLinesWithBlankLinesAsASpace() throws {
        let bytes = Array((".tc Chapter One\r\nBody.\r\n.tc2 A Section\r\nMore.\r\n.ix wordstar\r\nEnd.\r\n").utf8)
        let lines = try #require(TOCPageSpec.lines(for: parseWS(bytes)))
        #expect(lines.first == TOCPageSpec.Line(text: "TABLE OF CONTENTS", isHeading: true))
        #expect(lines.contains(TOCPageSpec.Line(text: "Chapter One", isHeading: false)))
        #expect(lines.contains(TOCPageSpec.Line(text: "  A Section", isHeading: false)))
        #expect(lines.contains(TOCPageSpec.Line(text: "INDEX", isHeading: true)))
        #expect(lines.contains(TOCPageSpec.Line(text: " ", isHeading: false)), "a blank line keeps its height")
        #expect(!lines.contains { $0.text.isEmpty })
        #expect(lines.filter(\.isHeading).count == 2)
    }
}
