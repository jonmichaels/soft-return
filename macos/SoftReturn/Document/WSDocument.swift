import AppKit
import CtrlKD

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

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let bytes = [UInt8](data)
        try MainActor.assumeIsolated {
            do {
                state = try DocumentState(data: bytes, settings: .shared, docPath: fileURL?.path ?? "")
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

    /// The standard alert for a file we cannot read, phrased for someone holding a 1987
    /// floppy rather than a stack trace. The spec asks that it mention the Inspector as the
    /// diagnostic route.
    private static func cannotOpenError(fileName: String?, underlying: Error) -> NSError {
        let name = fileName.map { "“\($0)”" } ?? "That file"
        var reason = "\(name) doesn’t appear to be a WordStar or text document."
        if case ParseError.notConvertible(let variant, _, _) = underlying, variant == .binary {
            reason = "\(name) looks like binary data, not a document."
        }
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
            NSLocalizedDescriptionKey: reason,
            NSLocalizedRecoverySuggestionErrorKey:
                "If you believe it is one, open it anyway and use the bottom bar’s variant "
                + "control to try a specific WordStar format.",
            NSUnderlyingErrorKey: underlying as NSError,
        ])
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
        addWindowController(DocumentWindowController(state: state))
        // Eager half of restoration persistence — see `DocumentRestorationStore
        // .persistOpenDocuments`. `applicationWillTerminate` alone is not reliable: this app
        // opts into sudden/automatic termination, and macOS skips that callback on those
        // quits.
        DocumentRestorationStore.persistOpenDocuments(settings: .shared)
        // job-145 Part A: viewing a document is the one signal this app can give Spotlight
        // that the file is worth indexing now, since the app never writes to it (mds reindexes
        // on write events, which never happen here).
        SpotlightFileIndexer.requestIndex(for: fileURL, category: "index-on-open")
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
