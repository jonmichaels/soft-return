import CryptoKit
import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// What survived `OutputParityTests` when the `output-manifest-v*.json` recordings were
/// retired (2026-09-07, planning JOB 2(a)).
///
/// That suite did two different jobs under one name. Most of it compared the app's three
/// conversion surfaces against a manifest — a THIRD recording of a truth ctrl-kd's own
/// `tests/answer_key.json` and `sr`'s parity suite already held — and the predictable thing
/// happened twice (jobs 423 and 426): the manifest went stale against an engine that had
/// legitimately moved, and the suite reported an engine-vs-stale-oracle gap as an app
/// defect. `AppAnswerKeyParityTests` now does that job against the ONE answer key, across
/// the same three surfaces.
///
/// The tests here are the ones that never read the manifest at all, kept verbatim rather
/// than deleted with it: a structural guard, the ruling that keeps Modern PDF honest, and
/// one spot-check per option axis. They are about the app's own export BEHAVIOUR — which
/// knob does what — not about matching recorded bytes, so they are orthogonal to whichever
/// oracle is in force.
@Suite struct ExportSurfaceTests {

    static var ws7Directory: URL { PrivateCorpusSupport.ws7Directory }

    static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    enum SurfaceError: Error { case noBytesProduced(String) }

    @MainActor
    static func exportEngineBytes(fixtureName: String, format: ExportFormat, mode: EmitMode) throws -> [UInt8] {
        let fixtureURL = Self.ws7Directory.appendingPathComponent(fixtureName)
        let bytes = [UInt8](try Data(contentsOf: fixtureURL))
        let defaults = UserDefaults(suiteName: "ExportSurfaceTests.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults))
        let title = (fixtureName as NSString).deletingPathExtension
        let products = try ExportEngine.render(
            document: state.document, state: state, formats: [format], notes: NoteSelection(),
            style: mode == .modern ? .modern : .printed, title: title, docPath: fixtureURL.path)
        guard let product = products.first else {
            throw SurfaceError.noBytesProduced("\(fixtureName) \(format.rawValue).\(mode.rawValue)")
        }
        return product.bytes
    }

    // MARK: - Structural guard

    /// If this ever starts failing, someone added `.layout` to `ExportFormat` — extend
    /// `AppAnswerKeyParityTests`' own cell list to cover it rather than leaving the layout
    /// cells permanently unexercised on the ExportEngine surface.
    @Test func exportEngineHasNoLayoutRoute() {
        #expect(ExportFormat(rawValue: "layout") == nil,
                "ExportFormat gained a .layout case — the answer-key cell list needs updating")
    }

    // MARK: - The Modern PDF ruling

    /// The accepted PDF+Modern divergence (`ExportEngine.render`'s own doc comment) must stay
    /// real: the app's Modern PDF is AppKit-rendered, in the user's chosen font, and is NOT
    /// the library's own Modern PDF. If the two ever match byte-for-byte, `modernPDF` has
    /// silently regressed to the library emitter — a real loss (Courier only, never the
    /// user's font) that would otherwise masquerade as a pass.
    ///
    /// Now stated against the LIBRARY'S OWN output rather than against a recorded manifest
    /// cell, which is what it always meant and no longer depends on any oracle file existing.
    /// This is also why `pdf.modern` is deliberately absent from the answer-key grid — see
    /// `docs/KNOWN-ISSUES-REGISTER.md`, where that exclusion is recorded as a decision.
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason)) @MainActor
    func exportEnginePDFModernIsADocumentedAppKitDivergence() throws {
        let fixtureName = "OLDTIMES.WS"
        let fixtureURL = Self.ws7Directory.appendingPathComponent(fixtureName)
        let raw = [UInt8](try Data(contentsOf: fixtureURL))
        let library = emitPDF(parseWS(raw), mode: .modern)
        let app = try Self.exportEngineBytes(fixtureName: fixtureName, format: .pdf, mode: .modern)

        #expect(!app.isEmpty, "ExportEngine's Modern PDF export must not be empty")
        #expect(!library.isEmpty, "the library's own Modern PDF must not be empty either")
        #expect(Self.sha256Hex(app) != Self.sha256Hex(library), """
            ExportEngine's Modern PDF is byte-identical to the library's own — re-verify \
            modernPDF is still routing through AppKit rather than the library emitter
            """)
    }

    // MARK: - Option axis spot-checks (one non-default check per axis)

    /// A real `..`-syntax comment note (`Document.swift`'s `NoteOrigin.dotDot`) — forced
    /// `.ws4` since plain-ASCII auto-detection is not guaranteed to land on the dot-command
    /// parser.
    private static let commentMarkerText = "a genuinely WordStar-native comment note"
    private static func commentNoteDocumentBytes() -> [UInt8] {
        let source = """
            A line before the mark, plain and unremarkable.
            ..This line plants \(commentMarkerText).
            A line after the mark.
            """
        return [UInt8](source.utf8)
    }

    private static func documentOperationsString(
        bytes: [UInt8], format: String, notes: Set<NoteKind> = EmitOptions.defaultNotes,
        noteRefs: NoteRefs = .word
    ) throws -> String {
        let options = DocumentOperations.ConversionOptions(
            formats: [format], mode: .modern, variant: .ws4, notes: notes, noteRefs: noteRefs)
        let result = try DocumentOperations.convert(data: bytes, options: options)
        return String(decoding: result.first?.bytes ?? [], as: UTF8.self)
    }

    /// Axis: notes on/off. Bare `sr` resolves to `EmitOptions.defaultNotes` (footnote/
    /// endnote/annotation, never comment — WordStar itself never printed a comment); `sr
    /// --comments FILE` resolves to `.allNotes`. `EmitOptions.notes`' own doc comment:
    /// "Excluding a kind removes its inline marker too, not just the trailing entry."
    @Test func notesAxisDefaultHidesACommentAllNotesShowsIt() throws {
        let bytes = Self.commentNoteDocumentBytes()
        let bareDefault = try Self.documentOperationsString(bytes: bytes, format: "text")
        let comments = try Self.documentOperationsString(bytes: bytes, format: "text", notes: EmitOptions.allNotes)
        #expect(!bareDefault.contains(Self.commentMarkerText),
                "bare sr (EmitOptions.defaultNotes) must never show a comment-kind note")
        #expect(comments.contains(Self.commentMarkerText),
                "sr --comments (.allNotes) must show it in the trailing Comments section")
    }

    /// Axis: `--note-refs`. `word` and `prefixed` only differ where a format actually reads
    /// `EmitOptions.noteRefs` — `text`/`markdown` ignore it — so this checks `html`.
    /// `EmitHTML.swift`'s `htmlBodySpan`: a comment's inline anchor is entirely absent under
    /// `word` (M9, "markless") and a visible `role="doc-noteref">c1<` anchor under
    /// `prefixed` (ruling 2026-08-06 M8).
    @Test func noteRefsAxisWordSuppressesPrefixedShowsACommentAnchor() throws {
        let bytes = Self.commentNoteDocumentBytes()
        let word = try Self.documentOperationsString(bytes: bytes, format: "html", notes: EmitOptions.allNotes, noteRefs: .word)
        let prefixed = try Self.documentOperationsString(bytes: bytes, format: "html", notes: EmitOptions.allNotes, noteRefs: .prefixed)
        #expect(!word.contains("role=\"doc-noteref\""),
                "word scheme must show no inline anchor for a markless comment note")
        #expect(prefixed.contains("role=\"doc-noteref\">c1<"),
                "prefixed scheme must label the comment note's inline anchor \"c1\"")
    }

    /// Axis: `--page-settings`. The CLI's own named `sawyer` preset, applied through the
    /// identical `DocumentOperations.PageSettingsPreset.sawyer` a real AppleScript `page
    /// settings` argument resolves to (`PageSettingsScripting.resolve`).
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func pageSettingsAxisSawyerPresetChangesPrintedPDFGeometry() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.ws7Directory.appendingPathComponent("OLDTIMES.WS")))
        let bare = try DocumentOperations.convert(
            data: bytes, options: DocumentOperations.ConversionOptions(formats: ["pdf"], mode: .printed))
        let sawyer = try DocumentOperations.convert(
            data: bytes, options: DocumentOperations.ConversionOptions(
                formats: ["pdf"], mode: .printed,
                pageSettings: DocumentOperations.PageSettingsPreset.sawyer.settings))
        #expect(bare.first?.bytes != sawyer.first?.bytes,
                "sr --page-settings sawyer must change the printed PDF's geometry vs. the bare default")
    }
}
