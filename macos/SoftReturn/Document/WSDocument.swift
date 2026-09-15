import AppKit
import CtrlKD
import SoftReturnShared

/// One open file.
///
/// A viewer: `isDocumentEdited` is never true, there is no save path, and the only way
/// bytes leave is Export, which always goes through a panel the user drove. `NSDocument` is
/// still the right base class — it is what gives Open Recent, the proxy icon, the
/// document-per-window lifecycle, and multi-file open, all of which the spec marks [SYS].
@MainActor
final class WSDocument: NSDocument {
    /// Everything about how this document is currently displayed. Built in `read`, so it is
    /// non-nil for the entire life of a document that opened successfully.
    private(set) var state: DocumentState!

    override class var autosavesInPlace: Bool { false }

    /// Nothing here is editable, so nothing is ever dirty.
    override var isDocumentEdited: Bool { false }

    // MARK: - Reading

    /// `NSDocument` declares this `nonisolated` because a document type CAN opt into
    /// concurrent reading. This one does not — `canConcurrentlyReadDocuments(ofType:)`
    /// defaults to false, so AppKit calls this on the main thread — which is what makes
    /// `assumeIsolated` sound here rather than a wish. Opting into concurrent reads later
    /// would mean revisiting this, and the compiler would not catch it, so: don't, without
    /// moving `DocumentState` off the main actor first.
    /// Opening by URL, so the execute bit can be cleared before anything else happens.
    ///
    /// This is the hook for the Gatekeeper problem: an extensionless file with the execute
    /// bit is refused by macOS as an unverifiable program. By the time we are here the user
    /// has already chosen this file, so repairing it is user-initiated and legal in the
    /// sandbox — and after this the file simply double-clicks, forever, with no dialog and
    /// nothing for the user to learn. See ExecutableBitRepair.
    override func read(from url: URL, ofType typeName: String) throws {
        ExecutableBitRepair.clearIfNeeded(at: url)
        try read(from: try Data(contentsOf: url), ofType: typeName)
    }

    /// Batch 26 (#271 M7): files at least this large are parsed off the main thread, starting the moment
    /// they are read (`startDeferredParse`). A smaller file parses here, before any window exists, in
    /// less time than a window takes to appear — and keeps the standard "can't open" alert with no
    /// window at all. -HOLYMAC.WS (538 KB) took 1.0 s here in a Debug build, a whole second of a
    /// frozen app before anything showed.
    ///
    /// Batch 27: the deferral is a WINDOW's concern, not the document's. Batch 26 started the parse from
    /// `makeWindowControllers`, so a long document opened with no window — `openDocument(withContentsOf:
    /// display: false)`, as a script's export or `AppleEventSelfSendProbe` does it — never parsed at all,
    /// and a script read the empty placeholder. The parse now starts in `read`, window or not, and
    /// anything that needs the document without a window to wait in takes it from `ensureParsed()`.
    static var backgroundParseThreshold = 64 * 1024

    /// The parse under way for a document opened awaiting one.
    private var deferredParse: Task<Void, Never>?
    /// Everyone waiting on that parse — the document's own windows (`deferredParseFinished`), a test —
    /// each told once, when it settles.
    private var parseObservers: [@MainActor @Sendable (Error?) -> Void] = []
    /// Whether the deferred parse has settled, and the "can't open" error it settled with, if any.
    private var deferredParseSettled = false
    private var deferredParseError: Error?

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let bytes = [UInt8](data)
        try MainActor.assumeIsolated {
            if bytes.count >= Self.backgroundParseThreshold {
                state = DocumentState(awaitingParseOf: bytes, settings: .shared, docPath: fileURL?.path ?? "")
                // Batch 27: now, whether or not a window will ever show this document.
                startDeferredParse { [weak self] error in
                    self?.deferredParseFinished(error)
                }
                return
            }
            do {
                // #271 M7: the engine's detect and parse, and the document's pictures.
                state = try PerformanceSignposts.measure("open.parse") {
                    try DocumentState(data: bytes, settings: .shared, docPath: fileURL?.path ?? "")
                }
            } catch {
                throw Self.cannotOpenError(fileName: fileURL?.lastPathComponent, underlying: error)
            }
        }
    }

    /// A viewer never writes back over what it opened. Export is the only way out, and it
    /// writes somewhere else entirely.
    override func write(to url: URL, ofType typeName: String) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
            NSLocalizedDescriptionKey: "Soft Return doesn’t save changes.",
            NSLocalizedRecoverySuggestionErrorKey:
                "This is a viewer. Use File ▸ Export As… to write a converted copy.",
        ])
    }

    /// The standard alert for a file we cannot read — its text lives in `CannotOpenError`
    /// (Shared/), so the iPhone app says exactly the same thing.
    private static func cannotOpenError(fileName: String?, underlying: Error) -> NSError {
        CannotOpenError.make(fileName: fileName, underlying: underlying)
    }

    #if DEBUG
    /// Test seam. In production a document only ever gets its state from
    /// `read(from:ofType:)`; tests need one without a file, and reaching in with
    /// `setValue(_:forKey:)` does not work — `state` is a plain Swift property with no
    /// `@objc`, so KVC raises NSUnknownKeyException at runtime rather than failing to
    /// compile. Named so nobody mistakes it for a production path.
    func setStateForTesting(_ newState: DocumentState) {
        state = newState
    }
    #endif

    // MARK: - Windows

    override func makeWindowControllers() {
        // #271 M7: the app's own open is progressive — a long Native document shows its first pages
        // at once and renders the rest while the window answers.
        addWindowController(DocumentWindowController(state: state, progressiveOpen: true))
        // Eager half of restoration persistence — see `DocumentRestorationStore
        // .persistOpenDocuments`. `applicationWillTerminate` alone is not reliable: this app
        // opts into sudden/automatic termination, and macOS skips that callback on those
        // quits.
        DocumentRestorationStore.persistOpenDocuments(settings: .shared)
        // job-145 Part A: viewing a document is the one signal this app can give Spotlight
        // that the file is worth indexing now, since the app never writes to it (mds reindexes
        // on write events, which never happen here).
        SpotlightFileIndexer.requestIndex(for: fileURL, category: "index-on-open")
        // Batch 27: a parse that already failed, with no window then to say so in, says so now.
        if let error = deferredParseError {
            MainRunLoop.perform { [weak self] in
                self?.deferredParseFinished(error)
            }
        }
    }

    /// Batch 26 (#271 M7): parses a document opened awaiting its parse (`read`) on another thread, adopts
    /// the result on the main thread, then calls `finished` — with nil, or the "can't open" error the parse
    /// would have raised in `read`. Batch 27: `read` starts it, so a later call only adds `finished` to the
    /// parse already under way; once that parse has settled, `finished` hears how on the next turn. A
    /// document that never awaited a parse (a short file) never calls it.
    func startDeferredParse(finished: @escaping @MainActor @Sendable (Error?) -> Void) {
        guard state.isAwaitingParse, !deferredParseSettled else {
            if deferredParseSettled {
                let error = deferredParseError
                MainRunLoop.perform { finished(error) }
            }
            return
        }
        parseObservers.append(finished)
        guard deferredParse == nil else { return }
        let bytes = state.data
        let docPath = state.docPath
        let fileName = fileURL?.lastPathComponent
        let start = DispatchTime.now().uptimeNanoseconds
        deferredParse = Task.detached(priority: .userInitiated) {
            let result = Result { try DocumentState.parsed(from: bytes, docPath: docPath) }
            MainRunLoop.perform { [weak self] in
                self?.completeDeferredParse(result, startedAt: start, fileName: fileName)
            }
        }
    }

    private func completeDeferredParse(_ result: Result<DocumentState.Parsed, any Error>, startedAt start: UInt64,
                                       fileName: String?) {
        deferredParse = nil
        // `ensureParsed()` got there first, and told everyone.
        guard !deferredParseSettled else { return }
        PerformanceSignposts.record("open.parse", startedAt: start)
        switch result {
        case .success(let parsed):
            state.adopt(parsed)
            settleDeferredParse(nil)
        case .failure(let error):
            settleDeferredParse(Self.cannotOpenError(fileName: fileName, underlying: error))
        }
    }

    /// Batch 27: the document parsed, now. A document still awaiting its background parse is parsed here,
    /// synchronously, for every caller with no window to wait in — a script's property or export, a test —
    /// and everyone waiting on the parse is told, as if the background parse had returned. A parse that
    /// failed throws the "can't open" error, every time it is asked.
    @discardableResult
    func ensureParsed() throws -> DocumentState {
        if let deferredParseError { throw deferredParseError }
        guard state.isAwaitingParse else { return state }
        do {
            let bytes = state.data
            let docPath = state.docPath
            let parsed = try PerformanceSignposts.measure("open.parse") {
                try DocumentState.parsed(from: bytes, docPath: docPath)
            }
            state.adopt(parsed)
            settleDeferredParse(nil)
            return state
        } catch {
            let cannotOpen = Self.cannotOpenError(fileName: fileURL?.lastPathComponent, underlying: error)
            settleDeferredParse(cannotOpen)
            throw cannotOpen
        }
    }

    private func settleDeferredParse(_ error: Error?) {
        deferredParseSettled = true
        deferredParseError = error
        let observers = parseObservers
        parseObservers = []
        for observer in observers {
            observer(error)
        }
    }

    /// The app's own end to a deferred parse: every window shows the document, or — the bytes were not a
    /// document after all — the windows close and the standard "can't open" alert says why. A document with
    /// no window keeps the error for whoever asks for it (`ensureParsed`), and shows no alert of its own.
    private func deferredParseFinished(_ error: Error?) {
        let controllers = windowControllers.compactMap { $0 as? DocumentWindowController }
        if let error {
            guard !controllers.isEmpty else { return }
            close()
            NSDocumentController.shared.presentError(error)
            return
        }
        for controller in controllers {
            controller.documentDidFinishParsing()
        }
    }

    /// Nothing prints while the document is still being parsed: there is nothing to print yet.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if state?.isAwaitingParse == true, item.action == #selector(printDocument(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Persists the open-document list with THIS document excluded before calling through —
    /// see `DocumentRestorationStore.persistOpenDocuments` for why that ordering (not after
    /// `super.close()`) is what keeps every remaining document's security-scoped access live
    /// long enough to bookmark it.
    override func close() {
        DocumentRestorationStore.persistOpenDocuments(excluding: self, settings: .shared)
        super.close()
    }

    // MARK: - Printing

    /// Print what you see: the same page views, at paper size. No custom options and no
    /// Page Setup — both deliberate, per the spec.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any])
        throws -> NSPrintOperation
    {
        #if DEBUG
        NSLog("SR-PRINT WSDocument.printOperation entered — windowControllers=%d [%@]",
              windowControllers.count,
              windowControllers.map { String(describing: type(of: $0)) }.joined(separator: ", "))
        #endif
        guard let controller = windowControllers.first as? DocumentWindowController else {
            // A DISTINCT message. The bare NSFeatureUnsupportedError this used to throw
            // carried no userInfo, so AppKit rendered it with exactly the same "the
            // application does not support printing" text as its own default — which meant
            // the app could not tell us whether this override ran and its guard failed, or
            // whether the override was never reached at all. Those are very different bugs.
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
                NSLocalizedDescriptionKey:
                    "Soft Return couldn’t find this document’s window to print from.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "This is a bug in Soft Return, not a problem with the document. The "
                    + "document has \(windowControllers.count) window controller(s) and none "
                    + "is the expected kind. Close the document and open it again.",
            ])
        }
        return controller.makePrintOperation(settings: printSettings)
    }
}
