import AppKit
import CtrlKD
import Foundation
import PDFKit
import Testing
@testable import SoftReturn

/// Job 375 item C2 (b24 completion): before this job, `ExportEngine.appKitRenderedPDF` (the
/// AppKit text-stack PDF path — Modern PDF export, and job 313A's Native-view carve-out) never
/// touched `EmitOptions` at all, so none of the job 373 export-sheet flags (headers/TOC/
/// pictures/inline styling) had any effect on a Modern or Native-view PDF. Every consumer —
/// the Export As sheet (Modern/Native UI export), AppleScript's native+modern `export`
/// command, and the Batch window — calls the SAME `ExportEngine.render`, so fixing it here
/// fixes all of them; see `WSDocument+Scripting.swift`'s own `headers:`/`toc:`/
/// `inlineStyling:`/`pictures:` pass-through and `BatchModel.swift`'s reliance on `render`'s
/// own Settings-backed defaults for the two real call sites this file exercises directly.
///
/// `inlineStyling` is NOT covered here — a disclosed gap, not an oversight. See
/// `ExportEngine.appKitRenderedPDF`'s own doc comment: the engine's own PDF writer does not
/// gate driver colour on this flag either (`EmitOptions.inlineStyling`'s own doc comment,
/// "never gates... nor PDF"), Modern's AppKit view has no colour-rendering mechanism to gate
/// in the first place ("Modern has no colour ops at all"), and the SIZE half would require
/// reconstructing which font a run would use WITHOUT an inline change — no shared engine
/// primitive exposes that distinction, and guessing at it would be exactly the view-side
/// reimplementation this codebase's "consume the engine's verdict" discipline forbids.
@Suite struct AppKitRenderedPDFHonorsEmitOptionsTests {

    /// Job 535: routes through `PrivateCorpusSupport` — see that file's own doc comment.
    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    /// WordStar's own bit-7-on-the-last-letter-of-a-word wordwrap convention —
    /// `Job313ExportPDFTests.sparseTopLeftDocumentBytes`'s own helper, duplicated here (that
    /// one is `private` to its own file): without it, a short, mostly-dot-command fixture's
    /// `hi` (high-bit byte) count reads as zero, and `Detect.swift`'s own `txt >= 90 && hard
    /// >= 2` rule reads the whole thing as a raw PRINTSTREAM (dot commands as literal text,
    /// no `.he`/`.tc`/`.pl` interpretation at all) instead of a real WordStar document.
    private static func highBitWords(_ text: String) -> [UInt8] {
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

    /// A synthetic WS4 document with a running head AND a `.tc` entry, small enough that
    /// both land on the same (only) page — same dot-command-header shape
    /// `Job313ExportPDFTests.sparseTopLeftDocumentBytes` already established for a real
    /// `.he`/page-geometry fixture. The `.he`/`.tc` TEXT arguments stay plain ASCII
    /// (unencoded) — this suite string-matches them verbatim, and only the BODY prose needs
    /// to carry the high-bit density that keeps `detect()` off the printstream branch.
    static var headersAndTOCDocumentBytes: [UInt8] {
        let hard: [UInt8] = [0x0D, 0x0A]
        var doc: [UInt8] = []
        for dot in [".pl 66", ".mt 5", ".mb 8", ".po 8", ".lh 8", ".cw 12",
                    ".he Running Head Marker", ".tc Chapter One"] {
            doc += Array(dot.utf8) + hard
        }
        doc += highBitWords("Body prose paragraph for content that runs on for a good while so "
            + "the text percentage and high bit density both clear detect's own thresholds safely.") + hard
        doc += [0x1A]
        return doc
    }

    @MainActor
    private static func headersAndTOCState() throws -> DocumentState {
        let defaults = UserDefaults(suiteName: "AppKitRenderedPDFHonorsEmitOptionsTests.\(UUID().uuidString)")!
        return try DocumentState(data: headersAndTOCDocumentBytes, settings: SettingsStore(defaults: defaults))
    }

    @MainActor
    private static func previewState() throws -> DocumentState {
        let url = Self.ws7Directory.appendingPathComponent("PREVIEW.WS")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "AppKitRenderedPDFHonorsEmitOptionsTests.\(UUID().uuidString)")!
        return try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults), docPath: url.path)
    }

    @MainActor
    private static func pdfString(_ bytes: [UInt8]) throws -> String {
        let doc = try #require(PDFDocument(data: Data(bytes)), "export produced unreadable PDF bytes")
        return doc.string ?? ""
    }

    // MARK: - headers

    @Test @MainActor func modernPDFHeadersFlagTogglesTheRunningHeadText() throws {
        let state = try Self.headersAndTOCState()
        let on = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                         notes: NoteSelection(), style: .modern, headers: true, toc: false)
        let off = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                          notes: NoteSelection(), style: .modern, headers: false, toc: false)
        let onText = try Self.pdfString(try #require(on.first).bytes)
        let offText = try Self.pdfString(try #require(off.first).bytes)
        #expect(onText.contains("Running Head Marker"), "headers on must show the running head")
        #expect(!offText.contains("Running Head Marker"), "headers off must suppress the running head")
    }

    @Test @MainActor func nativeCarveOutPDFHeadersFlagTogglesTheRunningHeadText() throws {
        let state = try Self.headersAndTOCState()
        let on = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                         notes: NoteSelection(), style: .printed, viewStyle: .native,
                                         headers: true, toc: false)
        let off = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                          notes: NoteSelection(), style: .printed, viewStyle: .native,
                                          headers: false, toc: false)
        let onText = try Self.pdfString(try #require(on.first).bytes)
        let offText = try Self.pdfString(try #require(off.first).bytes)
        #expect(onText.contains("Running Head Marker"), "headers on must show the running head")
        #expect(!offText.contains("Running Head Marker"), "headers off must suppress the running head")
    }

    // MARK: - toc

    @Test @MainActor func modernPDFTOCFlagTogglesTheCompiledSection() throws {
        let state = try Self.headersAndTOCState()
        let on = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                         notes: NoteSelection(), style: .modern, headers: false, toc: true)
        let off = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                          notes: NoteSelection(), style: .modern, headers: false, toc: false)
        let onText = try Self.pdfString(try #require(on.first).bytes)
        let offText = try Self.pdfString(try #require(off.first).bytes)
        #expect(onText.contains("TABLE OF CONTENTS") && onText.contains("Chapter One"),
                "toc on must append the compiled TOC section")
        #expect(!offText.contains("TABLE OF CONTENTS"), "toc off must produce no TOC section at all")
    }

    @Test @MainActor func tocOffOnADocumentWithNoEntriesNeverAppendsAnEmptySection() throws {
        let defaults = UserDefaults(suiteName: "AppKitRenderedPDFHonorsEmitOptionsTests.\(UUID().uuidString)")!
        let bytes = Array("Plain prose, no dot commands at all, nothing special.\r\n".utf8)
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
        let withToc = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                              notes: NoteSelection(), style: .modern, toc: true)
        let text = try Self.pdfString(try #require(withToc.first).bytes)
        #expect(!text.contains("TABLE OF CONTENTS"), "a document with no .tc/.ix entries gets no TOC section")
    }

    // MARK: - pictures

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func modernPDFPicturesFlagChangesExportedBytes() throws {
        let state = try Self.previewState()
        #expect(state.pixResults.contains { $0.ok }, "PREVIEW.WS's own .PIX tag should have resolved")
        let embed = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                            notes: NoteSelection(), style: .modern, docPath: state.docPath,
                                            pictures: .embed)
        let off = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                          notes: NoteSelection(), style: .modern, docPath: state.docPath,
                                          pictures: .off)
        #expect(try #require(embed.first).bytes != (try #require(off.first).bytes),
                "resolving PREVIEW.WS's picture must change the Modern PDF's own bytes")
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func modernViewRenderDropsTheImageAttachmentWhenPicturesFlagIsOff() throws {
        let state = try Self.previewState()
        let with = DocumentRenderer.render(state, style: .modern,
                                           exportFlags: DocumentRenderer.ExportFlags(pictures: true))
        let without = DocumentRenderer.render(state, style: .modern,
                                              exportFlags: DocumentRenderer.ExportFlags(pictures: false))
        func hasRealImageAttachment(_ text: NSAttributedString) -> Bool {
            var found = false
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                guard let attachment = value as? NSTextAttachment,
                      let image = attachment.image, image.size.width > 0, image.size.height > 0
                else { return }
                found = true
                stop.pointee = true
            }
            return found
        }
        #expect(hasRealImageAttachment(with.text), "pictures on must still draw the resolved image")
        #expect(!hasRealImageAttachment(without.text), "pictures off must drop the image attachment entirely")
    }

    // MARK: - default state matches Settings

    /// Job 373's own ruled defaults (headers ON, TOC OFF, inline styling ON, Pictures Embed)
    /// are `SettingsStore`'s init-time fallback, but `SettingsStore.shared` is a real,
    /// process-wide `UserDefaults`-backed singleton other tests in this same run may have
    /// already touched — pinning this suite's own assertion to whatever `SettingsStore
    /// .shared` reports RIGHT NOW (rather than hardcoding true/false/true/.embed) tests the
    /// WIRING (omitting a flag really does fall back to Settings), which is this test's own
    /// job, without being a hostage to test-execution order.
    @Test @MainActor func omittingEveryFlagMatchesWhateverSettingsCurrentlyReports() throws {
        let state = try Self.headersAndTOCState()
        let implicit = try ExportEngine.render(document: state.document, state: state, formats: [.pdf],
                                               notes: NoteSelection(), style: .modern)
        let explicitFromSettings = try ExportEngine.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(), style: .modern,
            headers: SettingsStore.shared.defaultHeaders, toc: SettingsStore.shared.defaultTOC,
            inlineStyling: SettingsStore.shared.defaultInlineStyling, pictures: SettingsStore.shared.defaultPictures)
        // Text content, not raw bytes: `appKitRenderedPDF` goes through PDFKit's
        // `dataWithPDF(inside:)`, which stamps a live CreationDate/ModDate into every PDF it
        // produces — two separately-generated exports of the IDENTICAL content are never
        // byte-identical for that reason alone (unlike the library's own zero-dependency PDF
        // writer; see this file's own `printedViewPDFExportStaysTheLiteralEngineBytes`,
        // which relies on exactly that determinism and only for the literal-engine-bytes
        // path). The `!=`/pixel-probe style every other assertion in this file already uses
        // is this same accommodation.
        let implicitText = try Self.pdfString(try #require(implicit.first).bytes)
        let explicitText = try Self.pdfString(try #require(explicitFromSettings.first).bytes)
        #expect(implicitText == explicitText,
                "an export with every flag omitted must match SettingsStore.shared's own current values")
    }

    @Test @MainActor func freshSettingsStoreDefaultsAreHeadersOnTOCOffInlineOnPicturesEmbed() throws {
        let defaults = UserDefaults(suiteName: "AppKitRenderedPDFHonorsEmitOptionsTests.\(UUID().uuidString)")!
        let fresh = SettingsStore(defaults: defaults)
        #expect(fresh.defaultHeaders == true, "ruled default: headers ON")
        #expect(fresh.defaultTOC == false, "ruled default: TOC OFF")
        #expect(fresh.defaultInlineStyling == true, "ruled default: inline styling ON")
        #expect(fresh.defaultPictures == .embed, "ruled default: Pictures Embed")
    }
}
