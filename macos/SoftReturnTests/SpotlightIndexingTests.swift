import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// `SpotlightIndexing` is the shared-layer logic behind Spotlight indexing: the
/// transformation from a WordStar-era file's bytes to `CSSearchableItemAttributeSet`-shaped
/// values. It used to also back a `com.apple.spotlight.import` appex
/// (`SoftReturnSpotlightImporter/ImportProvider.swift`) — removed in job 181 Part 2, since
/// Apple DTS confirms that extension point is registered but never invoked by the OS (see
/// `.claude/skills/macos-document-app/references/09-spotlight-importers.md`); the classic
/// `SoftReturnImporter` `.mdimporter` (untouched by that job) is the mechanism that actually
/// works and carries its own copy of this same logic (`ImporterCore.swift`, which cannot
/// import this app-target module either — see that file's doc comment).
///
/// What's proven headlessly, honestly, here: the transformation from bytes to
/// `CSSearchableItemAttributeSet`-shaped values is correct, unit-tested directly. What is
/// NOT proven, and cannot be proven in this sandbox: that `mdimport`/Spotlight actually
/// indexes a fixture through `SoftReturnImporter.mdimporter` and the index round-trips
/// through `mdfind` — that is console-bound, per `09-spotlight-importers.md`'s diagnosis
/// ladder.
@Suite struct SpotlightIndexingTests {

    @Test func indexesTitleTextContentPageCountAndVariantForAWS4Fixture() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        let attributes = try SpotlightIndexing.attributes(forFilename: url.lastPathComponent, data: data)

        #expect(attributes.title == "dropped-chapter.ws4")
        #expect(!attributes.textContent.isEmpty)
        // Modern-mode plain text strips WordStar's own control bytes — no soft-return
        // marker byte (0x8D) should survive into what Spotlight indexes as words.
        #expect(!attributes.textContent.unicodeScalars.contains { $0.value == 0x8D })
        #expect(attributes.pageCount >= 1)
        #expect(attributes.variant == .ws4)
        #expect(attributes.keywords.contains("ws4"))
    }

    @Test func keywordsCarryEveryDotCommandTheFileUsed() throws {
        // narrow.ws4 sets .cw/.lh/.mb/.mt/.pl/.po — a fixture that actually has dot
        // commands to carry into keywords, unlike boundary.ws4 (which has none).
        let url = Oracle.fixturesDirectory.appendingPathComponent("narrow.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        let attributes = try SpotlightIndexing.attributes(forFilename: url.lastPathComponent, data: data)
        let opened = try DocumentOperations.open(data: data)

        #expect(!opened.document.dotCommands.isEmpty)
        // Every dot command CtrlKD observed shows up as a keyword — nothing dropped, and
        // nothing invented that the parse didn't actually see.
        for command in opened.document.dotCommands {
            #expect(attributes.keywords.contains(command),
                    "keywords is missing dot command \(command)")
        }
    }

    @Test func aFileWithNoDotCommandsIndexesOnlyTheVariantKeyword() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("no-dot-commands.ws4")
        let data = [UInt8](try Data(contentsOf: url))

        let attributes = try SpotlightIndexing.attributes(forFilename: url.lastPathComponent, data: data)

        #expect(attributes.keywords == [attributes.variant.rawValue])
    }

    @Test func aFileThatWontParseThrowsRatherThanIndexingGarbage() {
        // Nine text-like bytes with no WordStar evidence at all: `detect` calls this
        // `.text`, which `parse` accepts — so reach for actual binary noise instead, the
        // shape `WiringTests.swift`'s own `Sample` helpers use for "not convertible."
        let bytes: [UInt8] = (0..<64).map { _ in 0x00 }

        #expect(throws: SpotlightIndexing.IndexingError.self) {
            _ = try SpotlightIndexing.attributes(forFilename: "noise.ws4", data: bytes)
        }
    }
}
