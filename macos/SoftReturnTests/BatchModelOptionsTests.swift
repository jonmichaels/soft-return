import CtrlKD
import Foundation
import PDFKit
import Testing
@testable import SoftReturn

/// A throwaway directory under the temp root, removed by the caller's `defer`.
private func makeTempDirectory(_ label: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SoftReturnBatchOptions-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Job 375 item C4 (b24 completion): the Options-column controls (headers/toc/
// inlineStyling/pictures) the Export As sheet gained in job 373, now on the Batch window too.
// `BatchModel.headers`/`.toc`/`.inlineStyling`/`.pictures` are the model-level half of that —
// `BatchWindowController.optionsBox`'s own doc comment covers the SwiftUI controls
// themselves (identical labels/enable-disable rules to `ExportAccessoryView`'s Options
// column), which is UI plumbing this file's own established house style (model-level
// verification, not a SwiftUI accessibility-tree walk — no existing Batch test in this file
// does that for `formats`/`notes` either) does not re-test a second way.

/// A synthetic WS4 document carrying a running head — same `highBitWords`-encoded-body shape
/// `Job313ExportPDFTests.sparseTopLeftDocumentBytes` and
/// `AppKitRenderedPDFHonorsEmitOptionsTests.headersAndTOCDocumentBytes` already established,
/// duplicated here (both are `private`/file-local to their own files) so this file's own
/// override test has no cross-file dependency.
private func batchHeadersFixtureBytes() -> [UInt8] {
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
    let hard: [UInt8] = [0x0D, 0x0A]
    var doc: [UInt8] = []
    for dot in [".pl 66", ".mt 5", ".mb 8", ".po 8", ".lh 8", ".cw 12", ".he Batch Running Head"] {
        doc += Array(dot.utf8) + hard
    }
    doc += highBitWords("Body prose paragraph for content that runs on for a good while so "
        + "the text percentage and high bit density both clear detect's own thresholds safely.") + hard
    doc += [0x1A]
    return doc
}

@Test @MainActor func batchModelOptionsInitializeFromSettingsSharedCurrentValues() throws {
    // `BatchModel`'s four Options properties read `SettingsStore.shared` at property-init
    // time, the SAME pattern `style`/`fontName`/`fontSize`/`formats` already use just above
    // them — this pins that pattern extends to all four new ones, matching whatever
    // `SettingsStore.shared` reports right now rather than a hardcoded assumption (other
    // tests in this same process may have already touched the real shared store).
    let model = BatchModel()
    #expect(model.headers == SettingsStore.shared.defaultHeaders)
    #expect(model.toc == SettingsStore.shared.defaultTOC)
    #expect(model.inlineStyling == SettingsStore.shared.defaultInlineStyling)
    #expect(model.pictures == SettingsStore.shared.defaultPictures)
    #expect(model.pageNumbers == SettingsStore.shared.defaultPageNumbers)
}

/// Job 521 (N9, b33 sentence-spacing UI): UNLIKE the five properties above, `sentenceSpacing`
/// has no Settings item at all (Jon's ruling) — it must always start at the plain literal
/// `.auto`, never a `SettingsStore.shared` read.
@Test @MainActor func batchModelSentenceSpacingAlwaysStartsAtAutoNotSettings() throws {
    let model = BatchModel()
    #expect(model.sentenceSpacing == .auto)
}

@Test @MainActor func batchRunHonorsAPerRunHeadersOverrideWithoutPersistingToSettings() async throws {
    let sourceDir = try makeTempDirectory("options-override-source")
    defer { try? FileManager.default.removeItem(at: sourceDir) }
    try Data(batchHeadersFixtureBytes()).write(to: sourceDir.appendingPathComponent("SOURCE.WS"))

    let settingsBefore = SettingsStore.shared.defaultHeaders

    let model = BatchModel()
    model.add(urls: [sourceDir], includeSubfolders: false)
    model.formats = [.pdf]
    model.style = .modern
    // The override: the OPPOSITE of whatever Settings currently reports, so this test proves
    // the override took effect regardless of what a prior test left `SettingsStore.shared` at.
    model.headers = !settingsBefore

    await model.run(progress: {})
    #expect(model.convertedCount == 1)
    #expect(model.failedCount == 0)

    let pdfURL = sourceDir.appendingPathComponent("SOURCE.pdf")
    #expect(FileManager.default.fileExists(atPath: pdfURL.path))
    let pdfText = PDFDocument(url: pdfURL)?.string ?? ""
    if model.headers {
        #expect(pdfText.contains("Batch Running Head"), "headers overridden ON must show the running head")
    } else {
        #expect(!pdfText.contains("Batch Running Head"), "headers overridden OFF must suppress the running head")
    }

    #expect(SettingsStore.shared.defaultHeaders == settingsBefore,
            "a per-run Batch override must never write back to SettingsStore.shared")
}

/// Job 520 (N5, b33 page-numbering UI): `BatchModel.pageNumbers` reaching the actual
/// `ExportEngine.render` call, the model-level half of the Batch window's own new pulldown.
/// `batchHeadersFixtureBytes` carries no page-numbering dot command of its own, so per the
/// b33 ruling ("auto: ... if the document has no page-numbering dot command at all,
/// numbering is OFF") `.auto` and `.on` must disagree — the same "compare produced bytes"
/// technique `AppKitRenderedPDFHonorsEmitOptionsTests.modernPDFPicturesFlagChangesExportedBytes`
/// already uses for a flag with no unique, greppable text of its own. `style = .printed`
/// (not the Modern/Native default) so the run goes through the library's own PDF emitter —
/// the one place `EmitOptions.pageNumbers` is honored (see `ExportEngine.render`'s own doc
/// comment: `appKitRenderedPDF` does not take this flag).
@Test @MainActor func batchRunHonorsAPerRunPageNumbersOverrideWithoutPersistingToSettings() async throws {
    let autoDir = try makeTempDirectory("pagenumbers-override-auto")
    defer { try? FileManager.default.removeItem(at: autoDir) }
    try Data(batchHeadersFixtureBytes()).write(to: autoDir.appendingPathComponent("SOURCE.WS"))

    let onDir = try makeTempDirectory("pagenumbers-override-on")
    defer { try? FileManager.default.removeItem(at: onDir) }
    try Data(batchHeadersFixtureBytes()).write(to: onDir.appendingPathComponent("SOURCE.WS"))

    let settingsBefore = SettingsStore.shared.defaultPageNumbers

    let autoModel = BatchModel()
    autoModel.add(urls: [autoDir], includeSubfolders: false)
    autoModel.formats = [.pdf]
    autoModel.style = .printed
    autoModel.pageNumbers = .auto
    await autoModel.run(progress: {})
    #expect(autoModel.convertedCount == 1)

    let onModel = BatchModel()
    onModel.add(urls: [onDir], includeSubfolders: false)
    onModel.formats = [.pdf]
    onModel.style = .printed
    onModel.pageNumbers = .on
    await onModel.run(progress: {})
    #expect(onModel.convertedCount == 1)

    let autoBytes = try Data(contentsOf: autoDir.appendingPathComponent("SOURCE.pdf"))
    let onBytes = try Data(contentsOf: onDir.appendingPathComponent("SOURCE.pdf"))
    let message = "forcing page numbers ON on a document with no page-numbering dot command must "
        + "change the printed PDF's own bytes (per the b33 ruling: auto + no dot command == off)"
    #expect(onBytes != autoBytes, "\(message)")

    #expect(SettingsStore.shared.defaultPageNumbers == settingsBefore,
            "a per-run Batch override must never write back to SettingsStore.shared")
}

/// A synthetic WS4 document carrying a genuine typewriter double space after a
/// sentence-ending period — same shape as `batchHeadersFixtureBytes`, duplicated here so this
/// file's own sentence-spacing test has no cross-file dependency (this codebase's own
/// established convention for these `private`/file-local fixtures).
private func batchSentenceSpacingFixtureBytes() -> [UInt8] {
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
    let hard: [UInt8] = [0x0D, 0x0A]
    var doc: [UInt8] = []
    for dot in [".pl 66", ".mt 5", ".mb 8", ".po 8", ".lh 8", ".cw 12"] {
        doc += Array(dot.utf8) + hard
    }
    doc += highBitWords("First sentence ends here.") + Array("  ".utf8)
        + highBitWords("Second sentence follows for padding so detection thresholds clear safely.") + hard
    doc += [0x1A]
    return doc
}

/// Job 521 (N9, b33 sentence-spacing UI): `BatchModel.sentenceSpacing` reaching the actual
/// `ExportEngine.render` call, the model-level half of the Batch window's own new pulldown.
/// `style = .modern` (whose own `.auto` default collapses the double space) so an explicit
/// `.keep` override is the one that must visibly change the produced text — the opposite
/// direction from the page-numbers test above, but the same "does the override actually
/// reach the render call" property.
@Test @MainActor func batchRunHonorsAPerRunSentenceSpacingOverrideWithoutPersistingToSettings() async throws {
    let autoDir = try makeTempDirectory("sentencespacing-override-auto")
    defer { try? FileManager.default.removeItem(at: autoDir) }
    try Data(batchSentenceSpacingFixtureBytes()).write(to: autoDir.appendingPathComponent("SOURCE.WS"))

    let keepDir = try makeTempDirectory("sentencespacing-override-keep")
    defer { try? FileManager.default.removeItem(at: keepDir) }
    try Data(batchSentenceSpacingFixtureBytes()).write(to: keepDir.appendingPathComponent("SOURCE.WS"))

    let autoModel = BatchModel()
    autoModel.add(urls: [autoDir], includeSubfolders: false)
    autoModel.formats = [.text]
    autoModel.style = .modern
    autoModel.sentenceSpacing = .auto
    await autoModel.run(progress: {})
    #expect(autoModel.convertedCount == 1)

    let keepModel = BatchModel()
    keepModel.add(urls: [keepDir], includeSubfolders: false)
    keepModel.formats = [.text]
    keepModel.style = .modern
    keepModel.sentenceSpacing = .keep
    await keepModel.run(progress: {})
    #expect(keepModel.convertedCount == 1)

    let autoText = try String(contentsOf: autoDir.appendingPathComponent("SOURCE.txt"), encoding: .utf8)
    let keepText = try String(contentsOf: keepDir.appendingPathComponent("SOURCE.txt"), encoding: .utf8)
    #expect(!autoText.contains("  "), "Modern + auto must collapse the double space")
    #expect(keepText.contains("  "), "an explicit per-run keep override must preserve it even on Modern")
}
