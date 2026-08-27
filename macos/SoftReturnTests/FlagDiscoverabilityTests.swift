import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Job 373 (b24 FLAG UI), discoverability rule ("someone can say: there's a TOC here, I
/// should turn it on" — `Info.swift`'s own repeated doc comment): the app's Document Info
/// window must show flag-governed content — TOC/index entry counts, headers/footers
/// declared, `.PIX` tags (resolved or not), inline color/size usage — regardless of the
/// export flags' own current state. `DocumentOperations.diagnose` never takes
/// `headers`/`toc`/`inlineStyling`/`pictures` as parameters AT ALL, which is structurally
/// what "regardless of flag state" means here; the one real gap this job found is that
/// `diagnose` never received the caller's already-resolved `pixResults`, so every `.PIX` tag
/// reported pessimistically "unresolved" even when the document's own sibling image
/// resolved fine everywhere else (Native/Modern/Printed views, per job 371's PIX IN VIEWS).
@Suite struct FlagDiscoverabilityTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    // MARK: - pixResults wiring (the real gap this job fixed)

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func diagnoseWithoutPixResultsReportsEveryTagUnresolved() throws {
        let url = Self.ws7Directory.appendingPathComponent("PREVIEW.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let diagnosis = DocumentOperations.diagnose(data: bytes, path: url.path)

        guard case .object(let fields) = diagnosis.info, case .array(let pix)? = fields["pix"] else {
            Issue.record("PREVIEW.WS should declare a pix field with at least one tag")
            return
        }
        #expect(!pix.isEmpty)
        for entry in pix {
            guard case .object(let tag) = entry else { continue }
            #expect(tag["resolved"] == .bool(false),
                    "without pixResults, diagnose must fall back to the pessimistic unresolved report")
        }
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func diagnoseWithRealPixResultsReportsTheActualResolvedState() throws {
        let url = Self.ws7Directory.appendingPathComponent("PREVIEW.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let doc = try DocumentOperations.open(data: bytes).document
        let pixResults = DocumentPictures.resolve(doc, docPath: url.path)
        #expect(pixResults.contains { $0.ok }, "PREVIEW.WS's own WORDSTAR.PIX sibling should resolve")

        let diagnosis = DocumentOperations.diagnose(data: bytes, path: url.path, pixResults: pixResults)
        guard case .object(let fields) = diagnosis.info, case .array(let pix)? = fields["pix"] else {
            Issue.record("PREVIEW.WS should declare a pix field")
            return
        }
        #expect(pix.contains { entry in
            guard case .object(let tag) = entry else { return false }
            return tag["resolved"] == .bool(true)
        }, "with the real pixResults, at least one tag must report resolved: true")
    }

    // MARK: - The real window: DocumentInfoWindowController.refresh threads state.pixResults

    @MainActor
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func documentInfoPanelShowsTheResolvedPixState() throws {
        let url = Self.ws7Directory.appendingPathComponent("PREVIEW.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "FlagDiscoverabilityTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
        #expect(state.pixResults.contains { $0.ok })

        let document = WSDocument()
        document.setStateForTesting(state)
        document.fileURL = url
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)

        let panel = controller.documentInfoWindowControllerCreatingIfNeeded()
        panel.refresh(from: controller)

        // `InspectorRows` renders a resolved pix entry's own fields as sorted key:value rows
        // under a "pix" sub-header — "resolved" -> "true" must appear somewhere in there,
        // not the pessimistic "false" a missing pixResults would produce.
        let content = try #require(panel.window?.contentView)
        let diagnoseStack = try #require(
            RenderProbeKit.descendants(content)
                .first { $0.accessibilityIdentifier() == "document-info-diagnose-list" } as? NSStackView)
        let allText = diagnoseStack.arrangedSubviews.compactMap { view -> String? in
            guard let row = view as? NSStackView, row.arrangedSubviews.count == 2,
                  let value = row.arrangedSubviews[1] as? NSTextField
            else { return nil }
            return value.stringValue
        }
        // `InfoValueListRenderer.scalar` renders a bool as "Yes"/"No", not "true"/"false" —
        // "Yes" right before the resolved tag's own basename ("WORDSTAR.PIX") is the signal.
        #expect(allText.contains("Yes"), "the panel's own Diagnose rows should show resolved: Yes somewhere: \(allText)")
        #expect(allText.contains("WORDSTAR.PIX"))
    }

    // MARK: - TOC/headers/inline styling are structurally flag-independent

    /// `diagnose`'s signature carries no `headers`/`toc`/`inlineStyling`/`pictures`
    /// parameter at all — this is what "regardless of flag state" means structurally. This
    /// test just confirms the fields a person needs to discover ("turn TOC on") are actually
    /// present for a document that has them, using the same synthetic fixture
    /// `FlagUIPlumbingTests.tocFixtureBytes` builds (a `.tc`/`.ix` pair).
    @Test func diagnoseReportsTOCAndIndexCountsForADocumentThatHasThem() throws {
        var data: [UInt8] = [0x1d, 0x04, 0x00, 0x00, 0x04, 0x00, 0x1d]  // ws7Block(0x00)
        data += Array("Prose padding for detection, a perfectly ordinary sentence.".utf8) + [0x0d, 0x0a]
        data += Array(".tc Chapter One".utf8) + [0x0d, 0x0a]
        data += Array(".ix Keyword".utf8) + [0x0d, 0x0a]
        data += Array("Closing prose line keeps the byte ratio looking like text.".utf8) + [0x0d, 0x0a]

        let diagnosis = DocumentOperations.diagnose(data: data)
        guard case .object(let fields) = diagnosis.info, case .object(let tocIndex)? = fields["toc_index"] else {
            Issue.record("a document with .tc/.ix entries should report a toc_index field")
            return
        }
        #expect(tocIndex["toc_entries"] == .int(1))
        #expect(tocIndex["index_entries"] == .int(1))
    }
}
