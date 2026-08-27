import CtrlKD
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
