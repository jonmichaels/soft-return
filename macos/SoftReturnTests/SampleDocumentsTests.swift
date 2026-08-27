import AppKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// Job 374 (b24, SAMPLES IN-APP): `SampleDocuments` is data-driven off a bundled resource
/// folder, so these tests build a throwaway `Bundle` around a scratch directory rather than
/// depending on the real app bundle's own `SampleDocuments/` (which now ships three
/// public-domain `.WS` files as of job 400's F11 refresh — see that folder's own README —
/// exercised directly by `realAppBundleShipsTheBundledSamplesAndBuildsAMenuItem` below).
@MainActor
private final class FakeDocumentController: DocumentOpening {
    var documents: [NSDocument] = []
    private(set) var openedURLs: [URL] = []
    func openDocument(withContentsOf url: URL, display: Bool,
                      completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        openedURLs.append(url)
        completionHandler(nil, false, nil)
    }
}

private func scratchBundle(files: [String: String]) throws -> Bundle {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SampleDocumentsTests-\(UUID().uuidString)")
    let sampleDirectory = root.appendingPathComponent("SampleDocuments")
    try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
    for (name, contents) in files {
        try Data(contents.utf8).write(to: sampleDirectory.appendingPathComponent(name))
    }
    return try #require(Bundle(url: root))
}

@Suite struct SampleDocumentsTests {

    // MARK: - items()

    @Test func itemsListsOnlyWordStarFamilyFilesTitleSorted() throws {
        let bundle = try scratchBundle(files: [
            "PREFACE.WS": "preface text",
            "CHAPTER1.WS": "chapter one text",
            "README.md": "not a sample",
            ".DS_Store": "finder noise",
        ])
        let items = SampleDocuments.items(bundle: bundle)
        #expect(items.map(\.title) == ["CHAPTER1", "PREFACE"],
                "only .WS-family files, sorted by title, README/.DS_Store excluded")
    }

    @Test func itemsRecognizesTheFullWordStarExtensionFamily() throws {
        let bundle = try scratchBundle(files: [
            "A.ws": "x", "B.WS4": "x", "C.wsd": "x", "D.wsm": "x", "E.ws-bak": "x",
            "F.txt": "x",
        ])
        let items = SampleDocuments.items(bundle: bundle)
        #expect(items.map(\.title).sorted() == ["A", "B", "C", "D", "E"])
    }

    @Test func itemsReturnsEmptyWhenTheResourceFolderIsMissing() throws {
        let emptyRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SampleDocumentsTests-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: emptyRoot))
        #expect(SampleDocuments.items(bundle: bundle).isEmpty)
    }

    /// The REAL, currently-shipping state (see `SoftReturn/Resources/SampleDocuments/README.md`)
    /// — the app's own bundle, not a scratch one, confirming the bundled public-domain
    /// samples build a real Help ▸ Open Sample Document submenu end to end. Job 400 (F11):
    /// `DARKNESS.WS` dropped from the bundle, three samples shipped. Job 407: `LYING.WS`
    /// (Jon-authored in WS7) joins the bundle, back to four.
    @Test @MainActor func realAppBundleShipsTheBundledSamplesAndBuildsAMenuItem() throws {
        let items = SampleDocuments.items(bundle: .main)
        #expect(items.map(\.title) == ["LYING", "OCAPTAIN", "TWAINLET", "WARPRAYR"])
        let menuItem = try #require(SampleDocuments.buildMenuItem(bundle: .main))
        #expect(menuItem.title == "Open Sample Document")
        let submenu = try #require(menuItem.submenu)
        #expect(submenu.items.map(\.title) == ["LYING", "OCAPTAIN", "TWAINLET", "WARPRAYR"],
                "Help ▸ Open Sample Document must list all four bundled samples")
    }

    /// Job 400 (F11, sample bundle refresh): Jon's authored files are the shipped ground
    /// truth now, so this opens each one through the REAL `NSDocument` path
    /// (`WSDocument.read(from:ofType:)` — exactly what Help ▸ Open Sample Document's copy-
    /// then-open drives, `SampleDocuments.open` above), confirming each detects as a real
    /// WordStar variant (not `.binary`, i.e. not a parse failure dressed up as success) and
    /// renders non-empty content in all three views: Native/Modern (the AppKit model
    /// `DocumentRenderer.render` produces for both) and Printed (the engine's own `emitPDF`
    /// bytes — `DocumentWindowController`'s separate PDFKit path, never `DocumentRenderer`).
    @Test @MainActor func everyBundledSampleOpensDetectsAndRendersInEveryView() throws {
        for item in SampleDocuments.items(bundle: .main) {
            let document = WSDocument()
            try document.read(from: item.url, ofType: "public.data")
            let state = try #require(document.state, "\(item.title) built no DocumentState")

            #expect(state.variant.value != .binary,
                    "\(item.title) detected as binary, not a real WordStar variant")

            let native = DocumentRenderer.render(state, style: .printed)
            #expect(native.text.length > 0, "\(item.title) rendered empty Native content")

            let modern = DocumentRenderer.render(state, style: .modern)
            #expect(modern.text.length > 0, "\(item.title) rendered empty Modern content")

            let printedPDF = emitPDF(state.document, mode: .printed)
            #expect(!printedPDF.isEmpty, "\(item.title) produced empty Printed-view PDF bytes")
        }
    }

    /// Job 407 (F11, sample set to 4): `LYING.WS` bundles a real WordStar footnote — Twain's
    /// own "Did not take the prize." aside — restoring the footnote-feature coverage
    /// `DARKNESS.WS` carried before job 400 dropped it from the shipped bundle (see
    /// [[soft-return-job400-sample-bundle-adjustments]]). Opens the bundled file through the
    /// same real `WSDocument.read(from:ofType:)` NSDocument path as the sanity test above,
    /// then checks the footnote reaches both reporting surfaces that read `doc.notes`
    /// (`DocumentInfoWindowController.noteCounts` and `DocumentOperations.diagnose`'s own
    /// `Info.swift`-built `notes.footnote` field — see `Info.swift:125`) and that its text
    /// actually paints as ink in the note area of the Printed render (`DocumentRenderer
    /// .render(_:style:.printed)`, the same call `DocumentWindowController`'s Printed PDFKit
    /// path and `emitPDF` both build pagination from — `docToPagelines` defaults to
    /// `EmitOptions.defaultNotes`, which includes `.footnote`).
    @Test @MainActor func lyingWSBundledFootnoteReachesDocumentInfoAndThePrintedPage() throws {
        let item = try #require(SampleDocuments.items(bundle: .main).first { $0.title == "LYING" },
                                 "LYING.WS must be bundled")
        let document = WSDocument()
        try document.read(from: item.url, ofType: "public.data")
        let state = try #require(document.state, "LYING built no DocumentState")

        let footnotes = state.document.notes.filter { $0.kind == .footnote }
        #expect(footnotes.count == 1, "LYING.WS must carry exactly 1 footnote")

        let diagnosis = DocumentOperations.diagnose(data: state.data, path: item.url.path)
        guard case .object(let fields) = diagnosis.info, case .object(let notes)? = fields["notes"],
              case .int(let footnoteCount)? = notes["footnote"] else {
            Issue.record("diagnose's info tree carried no notes.footnote field")
            return
        }
        #expect(footnoteCount == 1, "DocumentOperations.diagnose must report the same footnote count")

        let printed = DocumentRenderer.render(state, style: .printed)
        #expect(printed.text.string.contains("Did not take the prize"),
                "the footnote's own text must paint as visible ink in the Printed render's note area")

        // Job 423 (view item a, intake item 6): the Modern on-screen view dropped the whole
        // note appendix from job 263 onward (`DocumentRenderer.renderModern`'s own
        // `.noteSeparator, .note` case, previously a silent `continue`) — closed this job.
        // b28 note 7 (Jon's ruling): the bracket convention this test used to pin
        // (`modernNoteToks`'s own `PDFModernLayout.swift` convention) was REVERTED — Modern's
        // appendix entry now reads "1. <text>", no brackets, no superscript on the label.
        // Job 502 (Jon's ruling: footnotes sit at the page FOOT, dash-separated, like
        // Printed): a footnote's own entry no longer joins `modern.text` at all — it is
        // pre-styled and handed back in `modernFootnoteEvents` for `PagedDocumentView` to
        // reserve room for and draw at its real page's own foot (see that field's own doc
        // comment). Checked there instead; `modern.text` must NOT carry it any more.
        let modern = DocumentRenderer.render(state, style: .modern)
        #expect(!modern.text.string.contains("Did not take the prize"),
                "job 502: the footnote's own text must no longer paint inline in the flat Modern flow")
        let footnoteEntry = try #require(
            modern.modernFootnoteEvents.flatMap(\.entries).first { $0.string.contains("Did not take the prize") },
            "the footnote's own text must reach modernFootnoteEvents for its page-foot block")
        #expect(footnoteEntry.string.contains("1. Did not take the prize"),
                "the Modern note appendix must carry the b28 label convention (arabic + period, no brackets)")
        #expect(!footnoteEntry.string.contains("[1] Did not take the prize"),
                "the bracket convention must be gone (b28 note 7)")
    }

    // MARK: - buildMenuItem()

    @Test @MainActor func buildMenuItemReturnsNilWhenNoSamplesAreBundled() throws {
        let bundle = try scratchBundle(files: [:])
        #expect(SampleDocuments.buildMenuItem(bundle: bundle) == nil)
    }

    @Test @MainActor func buildMenuItemListsEachSampleAsASubmenuItemCarryingItsURL() throws {
        let bundle = try scratchBundle(files: ["PREFACE.WS": "x", "CHAPTER1.WS": "x"])
        let menuItem = try #require(SampleDocuments.buildMenuItem(bundle: bundle))
        #expect(menuItem.title == "Open Sample Document")
        let submenu = try #require(menuItem.submenu)
        #expect(submenu.items.map(\.title) == ["CHAPTER1", "PREFACE"])
        for entry in submenu.items {
            let represented = try #require(entry.representedObject as? SampleDocuments.Item)
            #expect(represented.title == entry.title)
            #expect(entry.action == #selector(AppDelegate.openSampleDocument(_:)))
        }
    }

    // MARK: - open() — copy-on-open

    @Test @MainActor func openCopiesToATempLocationAndOpensTheCopyNotTheOriginal() throws {
        let bundle = try scratchBundle(files: ["PREFACE.WS": "original bytes"])
        let item = try #require(SampleDocuments.items(bundle: bundle).first)
        let controller = FakeDocumentController()

        SampleDocuments.open(item, documentController: controller)

        let openedURL = try #require(controller.openedURLs.first)
        #expect(openedURL != item.url, "must open a COPY, never the bundled original's own URL")
        #expect(openedURL.lastPathComponent == item.url.lastPathComponent)
        #expect(openedURL.path.contains(NSTemporaryDirectory())
                || openedURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                "the copy must live under a temp directory")
        let copiedBytes = try Data(contentsOf: openedURL)
        #expect(copiedBytes == Data("original bytes".utf8))
        let originalBytes = try Data(contentsOf: item.url)
        #expect(originalBytes == Data("original bytes".utf8), "the bundled original must be untouched")
    }

    @Test @MainActor func openingTheSameSampleTwiceNeverCollidesOnDisk() throws {
        let bundle = try scratchBundle(files: ["PREFACE.WS": "x"])
        let item = try #require(SampleDocuments.items(bundle: bundle).first)
        let controller = FakeDocumentController()

        SampleDocuments.open(item, documentController: controller)
        SampleDocuments.open(item, documentController: controller)

        #expect(controller.openedURLs.count == 2)
        #expect(controller.openedURLs[0] != controller.openedURLs[1],
                "each open must land in its own fresh temp location")
    }
}
