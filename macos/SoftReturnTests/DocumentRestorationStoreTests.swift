import AppKit
import Testing
@testable import SoftReturn

/// The fallback half of window restoration: see `DocumentRestorationStore`'s own doc comment
/// for why AppKit's own secure state restoration is not enough on its own. These tests never
/// touch the real `NSDocumentController` or open a real window — `FakeDocumentController`
/// stands in wherever `reopenIfNeeded` would otherwise drive one, and every file involved is
/// a scratch temp file, never a real document.
@MainActor
private func throwawaySettings() -> (SettingsStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: "DocumentRestorationStoreTests.\(UUID().uuidString)")!
    return (SettingsStore(defaults: defaults), defaults)
}

private func scratchDocumentURL(name: String = "LETTER.ws4") throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DocumentRestorationStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data("PLAIN TEXT DOCUMENT\r\nSecond line.\r\n".utf8).write(to: url)
    return url
}

@MainActor
private final class FakeDocumentController: DocumentOpening {
    var documents: [NSDocument]
    private(set) var openedURLs: [URL] = []
    init(documents: [NSDocument] = []) { self.documents = documents }

    func openDocument(withContentsOf url: URL, display: Bool,
                      completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        openedURLs.append(url)
        completionHandler(nil, false, nil)
    }
}

// MARK: - Persist / resolve round trip

@Test @MainActor func persistingWritesBookmarksThatResolveBackToTheSameFile() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let url = try scratchDocumentURL()

    DocumentRestorationStore.persist(urls: [url], settings: settings, defaults: defaults)
    let resolved = DocumentRestorationStore.resolvedURLs(defaults: defaults)

    #expect(resolved.count == 1)
    #expect(resolved.first?.path == url.path)
}

@Test @MainActor func persistingWithThePreferenceOffStoresNothing() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = false
    let url = try scratchDocumentURL()

    DocumentRestorationStore.persist(urls: [url], settings: settings, defaults: defaults)

    #expect(DocumentRestorationStore.resolvedURLs(defaults: defaults).isEmpty)
}

@Test @MainActor func turningThePreferenceOffClearsWhatWasPreviouslyStored() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let url = try scratchDocumentURL()
    DocumentRestorationStore.persist(urls: [url], settings: settings, defaults: defaults)
    #expect(!DocumentRestorationStore.resolvedURLs(defaults: defaults).isEmpty)

    settings.restoreWindowsOnLaunch = false
    DocumentRestorationStore.persist(urls: [url], settings: settings, defaults: defaults)

    #expect(DocumentRestorationStore.resolvedURLs(defaults: defaults).isEmpty,
            "a preference turned off must stop remembering anything, not just stop writing new URLs")
}

@Test @MainActor func persistingAnEmptyListClearsAPreviouslyStoredDocument() throws {
    // A quit with nothing open must not leave a stale document to reopen next launch.
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let url = try scratchDocumentURL()
    DocumentRestorationStore.persist(urls: [url], settings: settings, defaults: defaults)

    DocumentRestorationStore.persist(urls: [], settings: settings, defaults: defaults)

    #expect(DocumentRestorationStore.resolvedURLs(defaults: defaults).isEmpty)
}

// MARK: - Eager persistence (open/close, not just quit)

@Test @MainActor func openingThenClosingADocumentUpdatesTheStoredListWithoutATerminateCall() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let first = try scratchDocumentURL(name: "FIRST.ws4")
    let second = try scratchDocumentURL(name: "SECOND.ws4")
    let controller = FakeDocumentController()
    let firstDoc = NSDocument()
    firstDoc.fileURL = first

    controller.documents = [firstDoc]
    DocumentRestorationStore.persistOpenDocuments(settings: settings, defaults: defaults,
                                                   documentController: controller)
    #expect(Set(DocumentRestorationStore.resolvedURLs(defaults: defaults).map(\.path)) == [first.path])

    let secondDoc = NSDocument()
    secondDoc.fileURL = second
    controller.documents = [firstDoc, secondDoc]
    DocumentRestorationStore.persistOpenDocuments(settings: settings, defaults: defaults,
                                                   documentController: controller)
    #expect(Set(DocumentRestorationStore.resolvedURLs(defaults: defaults).map(\.path))
            == Set([first, second].map(\.path)))

    // Closing `firstDoc`: it is still in `controller.documents` at this point (removal is
    // `close()`'s job, which has not run) — `excluding` is how the close path leaves it out.
    DocumentRestorationStore.persistOpenDocuments(excluding: firstDoc, settings: settings,
                                                   defaults: defaults, documentController: controller)
    #expect(Set(DocumentRestorationStore.resolvedURLs(defaults: defaults).map(\.path)) == [second.path])
}

@Test @MainActor func closingTheLastDocumentLeavesAnEmptyNotStaleList() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let url = try scratchDocumentURL()
    let controller = FakeDocumentController()
    let doc = NSDocument()
    doc.fileURL = url
    controller.documents = [doc]
    DocumentRestorationStore.persistOpenDocuments(settings: settings, defaults: defaults,
                                                   documentController: controller)
    #expect(!DocumentRestorationStore.resolvedURLs(defaults: defaults).isEmpty)

    DocumentRestorationStore.persistOpenDocuments(excluding: doc, settings: settings,
                                                   defaults: defaults, documentController: controller)

    #expect(DocumentRestorationStore.resolvedURLs(defaults: defaults).isEmpty,
            "the last window closing must leave an empty list, not a stale one")
}

@Test @MainActor func eagerPersistenceStillRespectsThePreferenceGate() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = false
    let url = try scratchDocumentURL()
    let controller = FakeDocumentController()
    let doc = NSDocument()
    doc.fileURL = url
    controller.documents = [doc]

    DocumentRestorationStore.persistOpenDocuments(settings: settings, defaults: defaults,
                                                   documentController: controller)

    #expect(DocumentRestorationStore.resolvedURLs(defaults: defaults).isEmpty)
}

// MARK: - Reopen gating

@Test @MainActor func reopenDoesNothingWhenThePreferenceIsOff() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let url = try scratchDocumentURL()
    DocumentRestorationStore.persist(urls: [url], settings: settings, defaults: defaults)
    settings.restoreWindowsOnLaunch = false
    let controller = FakeDocumentController()

    DocumentRestorationStore.reopenIfNeeded(settings: settings, defaults: defaults, documentController: controller)

    #expect(controller.openedURLs.isEmpty)
}

@Test @MainActor func reopenDoesNothingWhenADocumentIsAlreadyOpen() throws {
    // The system already restored (or -SoftReturnOpenDocument already opened something) —
    // this fallback must not open the same document a second time.
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let url = try scratchDocumentURL()
    DocumentRestorationStore.persist(urls: [url], settings: settings, defaults: defaults)
    let controller = FakeDocumentController(documents: [NSDocument()])

    DocumentRestorationStore.reopenIfNeeded(settings: settings, defaults: defaults, documentController: controller)

    #expect(controller.openedURLs.isEmpty)
}

@Test @MainActor func reopenOpensEveryStoredURLWhenNothingIsOpenAndThePreferenceIsOn() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let first = try scratchDocumentURL(name: "FIRST.ws4")
    let second = try scratchDocumentURL(name: "SECOND.ws4")
    DocumentRestorationStore.persist(urls: [first, second], settings: settings, defaults: defaults)
    let controller = FakeDocumentController()

    DocumentRestorationStore.reopenIfNeeded(settings: settings, defaults: defaults, documentController: controller)

    #expect(Set(controller.openedURLs.map(\.path)) == Set([first, second].map(\.path)))
}

@Test @MainActor func reopenDoesNothingWithNoStoredDocumentsEvenWhenThePreferenceIsOn() throws {
    let (settings, defaults) = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let controller = FakeDocumentController()

    DocumentRestorationStore.reopenIfNeeded(settings: settings, defaults: defaults, documentController: controller)

    #expect(controller.openedURLs.isEmpty)
}
