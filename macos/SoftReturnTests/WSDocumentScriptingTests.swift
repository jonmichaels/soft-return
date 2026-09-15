import AppKit
import CtrlKD
import SoftReturnShared
import Foundation
import Testing
@testable import SoftReturn

/// `WSDocument`'s `scripting*` properties — `SoftReturn.sdef`'s `document` class, one
/// test per property row of the dictionary's table. Two shapes: a document with no
/// window controller attached (`setStateForTesting`, the `#if DEBUG` seam
/// `WSDocument.swift` documents for exactly this) exercises the state-only fallback
/// path every getter/setter falls back to; a document that went through
/// `makeWindowControllers()` (the same call `read(from:ofType:)` makes) exercises the
/// live path that actually re-renders, matching what a script driving an open document
/// window sees.
@Suite struct WSDocumentScriptingTests {

    @MainActor
    private static func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "WSDocumentScriptingTests.\(UUID().uuidString)")!)
    }

    @MainActor
    private static func makeDocument(fixture: String = "dropped-chapter.ws4") throws -> WSDocument {
        let url = Oracle.fixturesDirectory.appendingPathComponent(fixture)
        let bytes = [UInt8](try Data(contentsOf: url))
        let state = try DocumentState(data: bytes, settings: throwawaySettings())
        let document = WSDocument()
        document.setStateForTesting(state)
        return document
    }

    // MARK: - variant

    @Test @MainActor func scriptingVariantReadsTheCurrentlyResolvedVariant() throws {
        let document = try Self.makeDocument()
        let code = try #require(ScriptingEnumCoding.code(for: document.state.variant.value))
        #expect(document.scriptingVariant.uint32Value == code)
    }

    @Test @MainActor func settingScriptingVariantForcesAReparseLikeCLIsForce() throws {
        let document = try Self.makeDocument()
        document.scriptingVariant = ScriptingCodes.nsNumber("SRvt")   // text
        #expect(document.state.variant.value == .text)
        #expect(document.state.variant.provenance == .manual)
    }

    // MARK: - style

    @Test @MainActor func settingScriptingStyleUpdatesTheRenderStyle() throws {
        let document = try Self.makeDocument()
        document.scriptingStyle = ScriptingCodes.nsNumber("SRsp")   // printed
        #expect(document.state.style.value == .printed)
        #expect(document.scriptingStyle.uint32Value == ScriptingCodes.fourCharCode("SRsp"))

        document.scriptingStyle = ScriptingCodes.nsNumber("SRsm")   // modern
        #expect(document.state.style.value == .modern)
    }

    /// Job 313B (Jon's ruling 2026-08-14, superseding job 265): `native` is a real,
    /// settable/readable scripting style now — reading while the (state-only, no window)
    /// document is Native reports "native" honestly, and setting it back to native round
    /// trips, exactly like printed/modern already do above.
    @Test @MainActor func scriptingStyleRoundTripsNativeHonestly() throws {
        let document = try Self.makeDocument()
        document.scriptingStyle = ScriptingCodes.nsNumber("SRsn")   // native
        #expect(document.state.style.value == .native)
        #expect(document.scriptingStyle.uint32Value == ScriptingCodes.fourCharCode("SRsn"))
    }

    // MARK: - page count (read-only) — falls back to DocumentOperations without a window

    @Test @MainActor func scriptingPageCountMatchesDocumentOperationsWithoutAWindowController() throws {
        let document = try Self.makeDocument()
        let expected = try DocumentOperations.pageCount(
            data: document.state.data, variant: document.state.variant.value)
        #expect(document.scriptingPageCount == expected)
    }

    @Test @MainActor func scriptingPageCountMatchesTheLiveWindowControllerWhenOneExists() throws {
        let document = try Self.makeDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        #expect(document.scriptingPageCount == controller.pageTotal)
    }

    // MARK: - current page — 1-based, the Go menu as a property

    @Test @MainActor func scriptingCurrentPageIsOneWithNoWindowController() throws {
        let document = try Self.makeDocument()
        #expect(document.scriptingCurrentPage == 1)
    }

    @Test @MainActor func scriptingCurrentPageTracksTheWindowControllersGoMenuState() throws {
        let document = try Self.makeDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        #expect(document.scriptingCurrentPage == controller.currentPage + 1)

        document.scriptingCurrentPage = 1
        #expect(controller.currentPage == 0)
    }

    // MARK: - zoom — fit / actual size / a percentage number

    @Test @MainActor func scriptingZoomRoundTripsFit() throws {
        let document = try Self.makeDocument()
        document.scriptingZoom = ScriptingCodes.nsNumber("SRzf")
        #expect(document.state.zoom.value == .fit)
        #expect(document.scriptingZoom.uint32Value == ScriptingCodes.fourCharCode("SRzf"))
    }

    @Test @MainActor func scriptingZoomRoundTripsActualSize() throws {
        let document = try Self.makeDocument()
        document.scriptingZoom = ScriptingCodes.nsNumber("SRza")
        #expect(document.state.zoom.value == .actual)
    }

    @Test @MainActor func scriptingZoomRoundTripsAPlainPercentageNumber() throws {
        let document = try Self.makeDocument()
        document.scriptingZoom = NSNumber(value: 150)
        #expect(document.state.zoom.value == .percent(150))
        #expect(document.scriptingZoom.intValue == 150)
    }

    // MARK: - page size

    @Test @MainActor func scriptingPageSizeRoundTripsAllThreeNamedSizes() throws {
        let document = try Self.makeDocument()
        for (code, size): (String, NamedPageSize) in [
            ("SRpl", .usLetter), ("SRpg", .usLegal), ("SRp4", .a4),
        ] {
            document.scriptingPageSize = ScriptingCodes.nsNumber(code)
            #expect(document.state.pageSize.value == size)
        }
    }

    // MARK: - modern font / modern size

    @Test @MainActor func scriptingModernFontIsReadWrite() throws {
        let document = try Self.makeDocument()
        document.scriptingModernFont = "Georgia"
        #expect(document.state.modernFontName == "Georgia")
        #expect(document.scriptingModernFont == "Georgia")
    }

    @Test @MainActor func scriptingModernSizeIsReadWrite() throws {
        let document = try Self.makeDocument()
        document.scriptingModernSize = NSNumber(value: 16)
        #expect(document.state.modernFontSize == 16)
        #expect(document.scriptingModernSize.intValue == 16)
    }

    // MARK: - show invisibles

    @Test @MainActor func scriptingShowInvisiblesTogglesTheSameFlagTheViewMenuDoes() throws {
        let document = try Self.makeDocument()
        #expect(document.scriptingShowInvisibles == false)
        document.scriptingShowInvisibles = true
        #expect(document.state.showInvisibles == true)
        #expect(document.scriptingShowInvisibles == true)
    }
}

/// Batch 27 item 1: a long document opened with NO window is still parsed. Batch 26 started the deferred
/// parse from `makeWindowControllers`, so a document of 64 KB or more read without one — the path a script's
/// `open`, `export` or `AppleEventSelfSendProbe` takes (`openDocument(withContentsOf:display: false)`) — never
/// parsed, and its state stayed the empty placeholder. Both tests open -HOLYMAC.WS (538 KB) through
/// `NSDocumentController.makeDocument(withContentsOf:ofType:)`: `read`, and no window.
@Suite(.tags(.corpus), .serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
@MainActor
struct WindowlessOpenTests {
    /// -HOLYMAC.WS copied into a fresh scratch folder, and the folder, for removal.
    private static func holymacCopy() throws -> (folder: URL, document: URL) {
        let source = try #require(PrivateCorpusSupport.sawyerArchiveRoot)
            .appendingPathComponent("MACROS/HOLYMAC/-HOLYMAC.WS")
        try #require(FileManager.default.fileExists(atPath: source.path), "no -HOLYMAC.WS in the Sawyer archive")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowlessOpenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("-HOLYMAC.WS")
        try FileManager.default.copyItem(at: source, to: copy)
        return (folder, copy)
    }

    private static func openWithoutAWindow(_ url: URL) throws -> WSDocument {
        let opened = try NSDocumentController.shared.makeDocument(withContentsOf: url,
                                                                  ofType: "me.beforeti.wordstar-document")
        let document = try #require(opened as? WSDocument)
        #expect(document.windowControllers.isEmpty, "the document was given a window")
        #expect(document.state.isAwaitingParse,
                "-HOLYMAC.WS is over the \(WSDocument.backgroundParseThreshold)-byte threshold, so read defers its parse")
        return document
    }

    /// Nobody asks: the background parse still runs, and the document is parsed within the minute.
    @Test func aLongDocumentOpenedWithoutAWindowParsesInTheBackground() throws {
        let (folder, url) = try Self.holymacCopy()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try Self.openWithoutAWindow(url)
        let deadline = Date().addingTimeInterval(60)
        while document.state.isAwaitingParse, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(!document.state.isAwaitingParse, "the parse never returned for a document with no window")
        #expect(!document.state.document.blocks.isEmpty, "the adopted document is empty")
        #expect(document.state.variant.value == document.state.detection.variant)
        let pages = try DocumentOperations.pageCount(data: document.state.data, variant: document.state.variant.value)
        print("WINDOWLESS-OPEN background: blocks \(document.state.document.blocks.count), variant \(document.state.variant.value), pages \(pages)")
        #expect(pages > 250, "-HOLYMAC.WS paginated to \(pages) pages")
    }

    /// A script reaches the document before its background parse returns: it is parsed on the spot, and the
    /// scripting properties and the export command read the real document, never the placeholder.
    @Test func aScriptReachingALongDocumentBeforeItsParseGetsItParsed() throws {
        let (folder, url) = try Self.holymacCopy()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try Self.openWithoutAWindow(url)
        let pageCount = document.scriptingPageCount
        #expect(!document.state.isAwaitingParse, "reading a scripting property left the document unparsed")
        #expect(!document.state.document.blocks.isEmpty, "the document a script read is empty")
        let detected = try #require(ScriptingEnumCoding.code(for: document.state.detection.variant))
        #expect(document.scriptingVariant.uint32Value == detected)
        print("WINDOWLESS-OPEN script: blocks \(document.state.document.blocks.count), variant \(document.state.variant.value), page count \(pageCount)")
        #expect(pageCount > 250, "the scripting page count read \(pageCount)")
        let parsed = try document.ensureParsed()
        #expect(parsed === document.state)
        // The background parse, returning afterwards, changes nothing.
        let settle = Date().addingTimeInterval(5)
        while Date() < settle { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        #expect(document.state.variant.value == document.state.detection.variant)
    }
}
