import AppKit
import CtrlKD
import PDFKit
import Testing
@testable import SoftReturn

/// Job 313A (b19, Jon's ruling 2026-08-14: "When you export, you would expect to get the
/// same thing you are looking at.") — verification that PDF export reuses Cmd-P's own print
/// render path per current view, rather than growing a third renderer.
///
/// `ExportEngine.render`'s `viewStyle` parameter is the mechanism: passed the document's
/// actual current/default `ViewStyle`, PDF export additionally special-cases `.native` (Modern
/// was already special-cased before this job) to go through `appKitRenderedPDF` — the exact
/// `DocumentRenderer.render` + `PagedDocumentView` construction
/// `DocumentWindowController.makePrintOperation` also builds for Cmd-P — instead of the
/// library's literal engine PDF bytes.
///
/// Job 322 (b20, item 1) — Jon field-confirmed 2026-08-15 that EVERY `appKitRenderedPDF`
/// export (Modern, and Native-view-current's `.native` carve-out identically) came out
/// 180°-flipped, and had done so since the function was born (job 263). The regression test
/// this job replaces (the old `printPathPDFBytes` helper below) never caught it because it
/// reconstructed the EXACT SAME hand-rolled `CGPDFContext` + manual flip transform
/// `appKitRenderedPDF` itself used, so both sides of the pixel-compare were equally flipped —
/// a broken instrument agreeing with itself. THE TEST LAW going forward: no assertion in this
/// file may build its ground truth by re-deriving `appKitRenderedPDF`'s own drawing code.
/// Two independent ground truths back every orientation-sensitive assertion below:
///   1. `ExportPDFOrientationEvidence.printOperationPDF` — a REAL `NSPrintOperation`, run
///      headlessly (`jobDisposition = .save`, no dialog) straight through
///      `DocumentWindowController.makePrintOperation`, the untouched Cmd-P path Jon field-
///      verified correct. Entirely different AppKit machinery from `appKitRenderedPDF`
///      (the print system's own pagination/PDF generation, not `dataWithPDF(inside:)` or
///      `CGPDFContext`) — it cannot share `appKitRenderedPDF`'s bug by construction.
///   2. Orientation invariants on the exported page's own rasterized pixels: opening text
///      must sit in the page's TOP half, left-margin content in the LEFT half. This needs no
///      second renderer at all — it reads the exported bytes and nothing else — and catches a
///      Y-flip and an X-mirror independently.
@MainActor
private enum ExportPDFOrientationEvidence {
    static let oldtimesURL = OracleByteParityTests.ws7Directory.appendingPathComponent("OLDTIMES.WS")

    enum ProbeError: Error { case missing(String) }

    /// A tiny synthetic WS4 document — two short lines flush left near the top of a full
    /// 66-line page, everything else left blank. `OLDTIMES.WS` (a real short story) turned
    /// out to be the WRONG fixture for a density-based top/bottom check: its title block
    /// (three short, sparse lines) carries LESS ink than the dense prose paragraph below it
    /// on page 1, so "top half has more ink than bottom half" is false for a document that is
    /// genuinely right-side-up — verified against `printOperationPDF`'s ground truth, which
    /// agrees with the export on that exact shape (both bottom-heavy), not a disagreement this
    /// file exists to catch. This fixture sidesteps the ambiguity by construction: with only
    /// two lines of text on a 66-line page, "opening text sits in the top portion" is a
    /// property of the DOCUMENT, not a coincidence of how dense any one fixture's prose is.
    static var sparseTopLeftDocumentBytes: [UInt8] {
        let hard: [UInt8] = [0x0D, 0x0A]
        func highBitWords(_ text: String) -> [UInt8] {
            var out: [UInt8] = []
            let chars = Array(text.unicodeScalars)
            for (index, scalar) in chars.enumerated() {
                var byte = UInt8(scalar.value & 0x7F)
                let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
                let isWordChar = CharacterSet.alphanumerics.contains(scalar)
                let nextIsWordChar = next.map { CharacterSet.alphanumerics.contains($0) } ?? false
                if isWordChar && !nextIsWordChar { byte |= 0x80 }
                out.append(byte)
            }
            return out
        }
        var doc: [UInt8] = []
        for dot in [".pl 66", ".mt 5", ".mb 8", ".po 8", ".lh 8", ".cw 12"] {
            doc += Array(dot.utf8) + hard
        }
        doc += highBitWords("TOP LEFT MARKER") + hard
        doc += highBitWords("SECOND LINE HERE") + hard
        doc += [0x1A]
        return doc
    }

    static func sparseTopLeftState() throws -> DocumentState {
        let defaults = UserDefaults(suiteName: "ExportPDFOrientationEvidence.\(UUID().uuidString)")!
        return try DocumentState(data: sparseTopLeftDocumentBytes, settings: SettingsStore(defaults: defaults))
    }

    /// Ground truth #1 — see this file's own top doc comment. Drives a real `WSDocument` /
    /// `DocumentWindowController` end to end and captures the SAME `NSPrintOperation`
    /// `makePrintOperation` hands Cmd-P, redirected to a temp file instead of a dialog
    /// (`jobDisposition = .save` + `jobSavingURL`, the standard headless "Save as PDF"
    /// recipe — `NSPrintInfo.dictionary()`'s own doc comment: "Changes to this dictionary
    /// will be reflected in the values returned by subsequent invocations of other of this
    /// class' methods", so mutating it in place before reading it back is the documented way
    /// to set an attribute with no dedicated property, same shape as `jobSavingURL`).
    static func printOperationPDF(_ state: DocumentState, viewStyle: ViewStyle) throws -> Data {
        state.style.setManually(viewStyle)
        let document = WSDocument()
        document.setStateForTesting(state)
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController,
            "document produced no DocumentWindowController")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("job322-print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let printInfo = NSPrintInfo()
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tempURL as NSURL
        let settings = printInfo.dictionary() as? [NSPrintInfo.AttributeKey: Any] ?? [:]

        let operation = controller.makePrintOperation(settings: settings)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw ProbeError.missing("NSPrintOperation.run() returned false — no file written")
        }
        return try Data(contentsOf: tempURL)
    }

    /// Ground truth #2 — see this file's own top doc comment. Rasterizes `page` and reports
    /// what fraction of each half's own pixel budget is "ink" (non-near-white), split both
    /// ways: top/bottom catches a Y-flip, left/right catches an X-mirror, and neither needs
    /// a second render of anything — it is a property of the bytes already in hand.
    static func inkHalves(of page: PDFPage) throws -> (top: Double, bottom: Double, left: Double, right: Double) {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { throw ProbeError.missing("page has empty bounds") }
        let thumbSize = NSSize(width: 500, height: 500 * bounds.height / bounds.width)
        guard let tiff = page.thumbnail(of: thumbSize, for: .mediaBox).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            throw ProbeError.missing("could not rasterize page for orientation check")
        }
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        guard width > 1, height > 1 else { throw ProbeError.missing("rasterized page is empty") }
        var topInk = 0, bottomInk = 0, leftInk = 0, rightInk = 0
        let halfY = height / 2, halfX = width / 2
        for y in 0..<height {
            for x in 0..<width {
                let color = (bitmap.colorAt(x: x, y: y) ?? .white).usingColorSpace(.deviceRGB) ?? .white
                let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                guard luminance < 0.85 else { continue } // near-white paper, not ink
                if y < halfY { topInk += 1 } else { bottomInk += 1 }
                if x < halfX { leftInk += 1 } else { rightInk += 1 }
            }
        }
        let halfPixels = Double(width * height) / 2
        return (Double(topInk) / halfPixels, Double(bottomInk) / halfPixels,
                Double(leftInk) / halfPixels, Double(rightInk) / halfPixels)
    }
}

// MARK: - Job 322: orientation — an exported page must never read upside-down or mirrored

@Test @MainActor func nativeViewPDFExportIsUprightNotFlipped() throws {
    let state = try ExportPDFOrientationEvidence.sparseTopLeftState()
    state.style.setManually(.native)
    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: .printed, viewStyle: .native)
    let bytes = Data(try #require(products.first { $0.format == .pdf }).bytes)
    let page = try #require(PDFDocument(data: bytes)?.page(at: 0))

    let ink = try ExportPDFOrientationEvidence.inkHalves(of: page)
    #expect(ink.top > ink.bottom,
            "top-half ink \(ink.top) is not greater than bottom-half ink \(ink.bottom) — the native-view PDF export reads upside-down")
    #expect(ink.left > ink.right,
            "left-half ink \(ink.left) is not greater than right-half ink \(ink.right) — the native-view PDF export reads mirrored")
}

@Test @MainActor func modernPDFExportIsUprightNotFlipped() throws {
    let state = try ExportPDFOrientationEvidence.sparseTopLeftState()
    state.style.setManually(.modern)
    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(), style: .modern)
    let bytes = Data(try #require(products.first { $0.format == .pdf }).bytes)
    let page = try #require(PDFDocument(data: bytes)?.page(at: 0))

    let ink = try ExportPDFOrientationEvidence.inkHalves(of: page)
    #expect(ink.top > ink.bottom,
            "top-half ink \(ink.top) is not greater than bottom-half ink \(ink.bottom) — the Modern PDF export reads upside-down")
    #expect(ink.left > ink.right,
            "left-half ink \(ink.left) is not greater than right-half ink \(ink.right) — the Modern PDF export reads mirrored")
}

// MARK: - Current view NATIVE -> exported PDF matches a REAL print operation, not a rebuilt one

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func nativeViewPDFExportIsNoLongerTheLiteralEngineBytes() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    state.style.setManually(.native)

    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: .printed, viewStyle: .native)
    let exported = try #require(products.first { $0.format == .pdf }).bytes
    #expect(Array(exported.prefix(4)) == Array("%PDF".utf8), "native-view export is not a PDF")

    let literalEngineBytes = [UInt8](emitPDF(state.document, mode: .printed, options: EmitOptions()))
    #expect(exported != literalEngineBytes,
            "native-view PDF export unexpectedly matches the literal engine PDF byte-for-byte — the b19A print-path carve-out is not taking effect")
}

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func nativeViewPDFExportMatchesARealPrintOperationsPageCountTextSizeAndOrientation() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    state.style.setManually(.native)

    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: .printed, viewStyle: .native)
    let exportedBytes = Data(try #require(products.first { $0.format == .pdf }).bytes)
    let exportedDoc = try #require(PDFDocument(data: exportedBytes))

    // A second, independently built `DocumentState` — the print-operation ground truth must
    // never share the exported state's object graph.
    let printState = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    let printBytes = try ExportPDFOrientationEvidence.printOperationPDF(printState, viewStyle: .native)
    let printDoc = try #require(PDFDocument(data: printBytes))

    #expect(exportedDoc.pageCount == printDoc.pageCount,
            "exported \(exportedDoc.pageCount) pages, the real print operation produced \(printDoc.pageCount)")
    for index in 0..<min(exportedDoc.pageCount, printDoc.pageCount) {
        let exportedPage = try #require(exportedDoc.page(at: index))
        let printPage = try #require(printDoc.page(at: index))
        #expect(exportedPage.string == printPage.string,
                "page \(index + 1) text differs between the export and a real print operation")
        #expect(exportedPage.bounds(for: .mediaBox) == printPage.bounds(for: .mediaBox),
                "page \(index + 1) size differs between the export and a real print operation")
    }

    // Not a strict pixel-compare here: `dataWithPDF(inside:)` and a real `NSPrintOperation`
    // are genuinely different AppKit rendering techniques (different rasterizer/AA path for
    // the SAME content), so demanding near-pixel-equality would be testing an implementation
    // detail neither side promises. Ink-halves proximity is the right bar — it says "same
    // rough layout, same orientation," which is what this test exists to prove.
    let exportedInk = try ExportPDFOrientationEvidence.inkHalves(of: try #require(exportedDoc.page(at: 0)))
    let printInk = try ExportPDFOrientationEvidence.inkHalves(of: try #require(printDoc.page(at: 0)))
    #expect(abs(exportedInk.top - printInk.top) < 0.05,
            "page 1 top-half ink \(exportedInk.top) vs print operation's \(printInk.top) — export may be flipped or otherwise mis-laid-out")
    #expect(abs(exportedInk.bottom - printInk.bottom) < 0.05,
            "page 1 bottom-half ink \(exportedInk.bottom) vs print operation's \(printInk.bottom) — export may be flipped or otherwise mis-laid-out")
    #expect(abs(exportedInk.left - printInk.left) < 0.05,
            "page 1 left-half ink \(exportedInk.left) vs print operation's \(printInk.left) — export may be mirrored or otherwise mis-laid-out")
    #expect(abs(exportedInk.right - printInk.right) < 0.05,
            "page 1 right-half ink \(exportedInk.right) vs print operation's \(printInk.right) — export may be mirrored or otherwise mis-laid-out")

    // Font faces: the bundled Courier Prime substitution (job 306/311/312), not the library
    // emitter's Courier — a raw PDF font-resource check, same spirit as
    // `ModernViewerStyleTests`' `familyName` assertions but at the PDF-bytes level since this
    // path never builds an `NSAttributedString` a test could inspect directly.
    let pdfString = String(decoding: exportedBytes, as: UTF8.self)
    #expect(pdfString.contains("CourierPrime"),
            "exported native PDF's font resources do not mention CourierPrime — Courier Prime substitution may not have carried into the print-path PDF export")
}

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func modernPDFExportMatchesARealPrintOperationsPageCountTextAndSize() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    state.style.setManually(.modern)

    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(), style: .modern)
    let exportedBytes = Data(try #require(products.first { $0.format == .pdf }).bytes)
    let exportedDoc = try #require(PDFDocument(data: exportedBytes))

    let printState = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    let printBytes = try ExportPDFOrientationEvidence.printOperationPDF(printState, viewStyle: .modern)
    let printDoc = try #require(PDFDocument(data: printBytes))

    #expect(exportedDoc.pageCount == printDoc.pageCount,
            "exported \(exportedDoc.pageCount) pages, the real print operation produced \(printDoc.pageCount)")
    for index in 0..<min(exportedDoc.pageCount, printDoc.pageCount) {
        let exportedPage = try #require(exportedDoc.page(at: index))
        let printPage = try #require(printDoc.page(at: index))
        #expect(exportedPage.string == printPage.string,
                "page \(index + 1) text differs between the Modern export and a real print operation")
        #expect(exportedPage.bounds(for: .mediaBox) == printPage.bounds(for: .mediaBox),
                "page \(index + 1) size differs between the Modern export and a real print operation")
    }

    // See the native-view sibling test above for why this is ink-halves proximity, not a
    // strict pixel-compare.
    let exportedInk = try ExportPDFOrientationEvidence.inkHalves(of: try #require(exportedDoc.page(at: 0)))
    let printInk = try ExportPDFOrientationEvidence.inkHalves(of: try #require(printDoc.page(at: 0)))
    #expect(abs(exportedInk.top - printInk.top) < 0.05,
            "page 1 top-half ink \(exportedInk.top) vs print operation's \(printInk.top) — export may be flipped or otherwise mis-laid-out")
    #expect(abs(exportedInk.bottom - printInk.bottom) < 0.05,
            "page 1 bottom-half ink \(exportedInk.bottom) vs print operation's \(printInk.bottom) — export may be flipped or otherwise mis-laid-out")
    #expect(abs(exportedInk.left - printInk.left) < 0.05,
            "page 1 left-half ink \(exportedInk.left) vs print operation's \(printInk.left) — export may be mirrored or otherwise mis-laid-out")
    #expect(abs(exportedInk.right - printInk.right) < 0.05,
            "page 1 right-half ink \(exportedInk.right) vs print operation's \(printInk.right) — export may be mirrored or otherwise mis-laid-out")
}

// MARK: - Current view PRINTED -> unchanged: the engine's own PDF bytes

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func printedViewPDFExportStaysTheLiteralEngineBytes() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    state.style.setManually(.printed)

    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: .printed, viewStyle: .printed)
    let exported = try #require(products.first { $0.format == .pdf }).bytes

    let literalEngineBytes = [UInt8](emitPDF(state.document, mode: .printed, options: EmitOptions()))
    #expect(exported == literalEngineBytes,
            "printed-view PDF export must stay byte-identical to the engine's own PDF — the b19A carve-out must never apply when the current view genuinely is Printed")
}

// MARK: - Omitting `viewStyle` (batch/scripting callers that predate job 313A) is inert

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func omittingViewStyleLeavesPDFExportUnchanged() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    // Deliberately leave `state.style.value` at its Settings-seeded default (`.native`) but
    // never pass `viewStyle` to `render` — the pre-313 call shape every caller this job does
    // not touch (`ConvertCommand`, `DocumentOperations.convert`) still uses.
    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(), style: .printed)
    let exported = try #require(products.first { $0.format == .pdf }).bytes

    let literalEngineBytes = [UInt8](emitPDF(state.document, mode: .printed, options: EmitOptions()))
    #expect(exported == literalEngineBytes,
            "a caller that omits `viewStyle` must keep getting the literal engine PDF, even when the DocumentState's own `.style.value` happens to be `.native`")
}

// MARK: - Batch: keyed off the batch window's OWN Style pulldown, same mechanism as the window

/// Job 323 (b20 item 3) revised this mechanism: `BatchModel.style` is now the SAME
/// three-case `ViewStyle` pulldown the Export As sheet's accessory offers (Native/Printed/
/// Modern), and `convertOne` passes its CHOSEN value straight through as `viewStyle` for
/// every item — no longer each item's own individually-seeded `state.style.value` (the
/// pre-323 mechanism `batchStyleDefaultViewGetsThePrintPathPDFTheSameWayTheWindowDoes` used
/// to prove). A batch item never opened as a window has no "current view" to defer to; an
/// explicit choice on the batch control is the only signal that exists, the same "the chosen
/// pulldown value, not an ambient default" rule job 323 applies to the single-document sheet.
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func batchStyleNativeChoiceGetsThePrintPathPDFRegardlessOfItemDefault() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)

    // The batch control explicitly set to Native — proves the CHOICE drives the carve-out,
    // not whatever `SettingsStore`'s own default happens to be.
    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: ViewStyle.native.renderStyle, viewStyle: .native)
    let exported = try #require(products.first { $0.format == .pdf }).bytes

    let literalEngineBytes = [UInt8](emitPDF(state.document, mode: .printed, options: EmitOptions()))
    #expect(exported != literalEngineBytes,
            "the batch window's Style pulldown set to Native must get the print-path PDF for every item, the same 'export what you see' rule the window's Export As sheet applies")
}

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func batchStylePrintedChoiceStaysTheLiteralEngineBytesEvenWhenAnItemsOwnDefaultIsNative() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    #expect(state.style.value == .native, "precondition: a synthetic batch item still defaults to Native")

    // The batch control explicitly set to Printed must win over the item's own ambient
    // Native default — exactly the override job 323's ruling fixes for the window's sheet,
    // proven here for batch's own control.
    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: ViewStyle.printed.renderStyle, viewStyle: .printed)
    let exported = try #require(products.first { $0.format == .pdf }).bytes

    let literalEngineBytes = [UInt8](emitPDF(state.document, mode: .printed, options: EmitOptions()))
    #expect(exported == literalEngineBytes,
            "the batch window's Style pulldown set to Printed must stay the literal engine PDF even when an item's own default view is Native")
}

// MARK: - Job 323: the Export As accessory's OWN selection reaches the print-path carve-out

/// Closes the exact gap Jon's ruling calls out: before job 323, `exportAs` passed
/// `viewStyle: documentState.style.value` (the window's AMBIENT style) unconditionally,
/// never `accessory.selectedStyle` (what the pulldown actually shows) — so an explicit
/// Printed choice on a Native window silently kept getting the Native print-path PDF. These
/// tests drive `ExportAccessoryView.selectedStyle` itself (the exact value
/// `DocumentWindowController+Actions.exportAs` now reads) into `ExportEngine.render`, rather
/// than a hand-picked `ViewStyle` literal, so a regression that reintroduces the ambient-style
/// bug would have to break the accessory's own reported selection to slip past unnoticed.
@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func accessoryExplicitPrintedSelectionExportsEngineBytesEvenWhenTheAccessoryWasHandedNative() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    // The accessory is constructed as if the window were showing Native (its own default),
    // then the pulldown is moved to Printed — the exact "explicit override" scenario the
    // ruling names.
    let accessory = ExportAccessoryView(formats: [.pdf], notes: NoteSelection(), style: .native)
    let popup = try #require(stylePopUpButton(in: accessory))
    popup.selectItem(withTitle: ViewStyle.printed.displayName)
    #expect(accessory.selectedStyle == .printed, "precondition: the pulldown now reports Printed")

    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: accessory.selectedStyle.renderStyle, viewStyle: accessory.selectedStyle)
    let exported = try #require(products.first { $0.format == .pdf }).bytes

    let literalEngineBytes = [UInt8](emitPDF(state.document, mode: .printed, options: EmitOptions()))
    #expect(exported == literalEngineBytes,
            "an explicit Printed pulldown choice must export the literal engine PDF even though the accessory was handed Native at init")
}

@Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
func accessoryExplicitNativeSelectionExportsThePrintPathPDFEvenWhenTheAccessoryWasHandedPrinted() throws {
    let state = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    let accessory = ExportAccessoryView(formats: [.pdf], notes: NoteSelection(), style: .printed)
    let popup = try #require(stylePopUpButton(in: accessory))
    popup.selectItem(withTitle: ViewStyle.native.displayName)
    #expect(accessory.selectedStyle == .native, "precondition: the pulldown now reports Native")

    let products = try ExportEngine.render(
        document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
        style: accessory.selectedStyle.renderStyle, viewStyle: accessory.selectedStyle)
    let exported = try #require(products.first { $0.format == .pdf }).bytes

    let literalEngineBytes = [UInt8](emitPDF(state.document, mode: .printed, options: EmitOptions()))
    #expect(exported != literalEngineBytes,
            "an explicit Native pulldown choice must reach the print-path PDF even though the accessory was handed Printed at init")

    // Orientation ground truth #1 (this file's own header) — not a second flip-prone
    // renderer, a REAL `NSPrintOperation` — confirms the print-path bytes the explicit
    // Native choice produced are the same shape a real print of a Native window gives.
    let exportedDoc = try #require(PDFDocument(data: Data(exported)))
    let printState = try Oracle.state(for: ExportPDFOrientationEvidence.oldtimesURL)
    let printBytes = try ExportPDFOrientationEvidence.printOperationPDF(printState, viewStyle: .native)
    let printDoc = try #require(PDFDocument(data: printBytes))
    #expect(exportedDoc.pageCount == printDoc.pageCount,
            "exported \(exportedDoc.pageCount) pages, the real print operation produced \(printDoc.pageCount)")
}

/// The Style pulldown sits three levels deep (`accessory` → the outer vertical stack → the
/// style row → the popup itself), so a shallow one-level `subviews` scan misses it — this
/// walks the whole tree, same shape `WiringTests.bottomBarControlsAreIdentifiedAndLabelled`
/// uses for the bottom bar's own popups.
@MainActor
private func stylePopUpButton(in view: NSView) -> NSPopUpButton? {
    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    return descendants(view).compactMap { $0 as? NSPopUpButton }
        .first { $0.accessibilityIdentifier() == "export-style-popup" }
}
