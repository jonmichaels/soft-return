import AppKit
import CtrlKD
import Foundation
import PDFKit
import Testing
@testable import SoftReturn

/// THE PRIVATE-CORPUS GATE. `TestDocs/` — Jon's own real multipage literary papers (`ws4/`)
/// and Sawyer's real published WordStar articles (`ws7/`, `oracle/*.json`) — lives in the
/// PRIVATE canonical tree only (`docs/KNOWN-ISSUES-REGISTER.md`'s standing rule, quoted
/// verbatim by several test files: "TestDocs never leave this private repo"). Job 534 proved
/// the public birth candidate strips `TestDocs/` itself (correctly) but left dozens of
/// surviving test files reading it as though it were always there — some via a safe
/// `try?`-swallow that quietly degrades to a Skip, some via a bare `try`/force-unwrap that
/// throws, and two shared test-infrastructure files it deleted outright
/// (`PixelOracleAppEngineTests.swift`, `MultipageMarginTests.swift`) whose enums 8 OTHER
/// surviving files still call, which doesn't even compile.
///
/// Job 535's ruling (Jon): unarmed = skip cleanly BY DESIGN, documented, never a failure.
/// Armed = fail loud, exactly like every other assertion in this repo — a corpus that's
/// present but broken/partial is a real bug, not something to wave through as a Skip.
/// Every private-corpus-dependent test in this tree routes its root resolution through this
/// one file so there is exactly one place that decides armed-vs-not.
enum PrivateCorpusSupport {
    /// Armed by `CTRLKD_PRIVATE_CORPUS` (an out-of-band copy of `TestDocs/`, same env var
    /// name the engine repo's own private-corpus gate already uses — `WSChangeTests.swift`,
    /// `OracleByteParityTests.corpusRoot` — so one variable arms every private-corpus gate in
    /// both repos at once) if set, else the in-repo `TestDocs/` directory if it exists (the
    /// PRIVATE canonical tree, where this strip never happened — job 534/535: keeps that tree
    /// running completely unchanged, no env var required). `nil` when neither applies — the
    /// public birth candidate, bare, is the exact shape this resolves to.
    ///
    /// Note this is a DIFFERENT corpus than `OracleByteParityTests.corpusRoot`/
    /// `OutputParityTests.corpusRoot` (Tier 2): those name the much larger, never-committed-
    /// anywhere full Sawyer archive (2,257+ files) that a MANIFEST checks byte-parity against.
    /// This one names the small, curated `TestDocs/` tree (`ws4/`, `ws7/`, `oracle/`) that
    /// ships INSIDE the private repo. Reusing the same env var name for both is deliberate
    /// (one variable, "point me at private stuff you don't have"), but they resolve to
    /// differently-shaped directories — a person arming this gate points it at a `TestDocs`-
    /// shaped copy, not the full archive.
    static var testDocsRoot: URL? {
        if let env = ProcessInfo.processInfo.environment["CTRLKD_PRIVATE_CORPUS"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let inRepo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoftReturnTests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root (job 531: macos/ restructure)
            .appendingPathComponent("TestDocs")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inRepo.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return inRepo
    }

    /// `true` exactly when a private corpus is available — every test gated by this file
    /// checks this (directly via `.enabled(if:)`, or indirectly by a fixture list that goes
    /// empty when this is `false`) before treating a missing document as anything other than
    /// an expected, documented Skip.
    static var isArmed: Bool { testDocsRoot != nil }

    /// Non-optional convenience for call sites that build a path unconditionally (no crash —
    /// it's just string/URL construction) and rely on a SEPARATE gate (`.enabled(if: isArmed)`
    /// on the `@Test`, or a `try?`-guarded directory listing) to keep the unarmed case from
    /// ever actually reading through it. Points at a deliberately nonexistent path when
    /// unarmed, so an ungated read fails loudly instead of silently resolving to somewhere
    /// real on disk.
    static var testDocsDirectory: URL {
        testDocsRoot ?? URL(fileURLWithPath: "/private-corpus-not-armed/TestDocs")
    }

    static var ws7Directory: URL { testDocsDirectory.appendingPathComponent("ws7") }
    static var ws4Directory: URL { testDocsDirectory.appendingPathComponent("ws4") }
    static var oracleDirectory: URL { testDocsDirectory.appendingPathComponent("oracle") }

    /// The skip reason every `.enabled(if: PrivateCorpusSupport.isArmed)` trait in this tree
    /// should cite — one value (typed `Comment`, what `.enabled(if:_:)` actually takes — a
    /// plain `String` does not implicitly convert), so `grep`ing for why a run shows a batch
    /// of Skips always lands on the same explanation.
    static let skipReason: Comment =
        "private-corpus-gated: TestDocs/ unavailable (CTRLKD_PRIVATE_CORPUS unset, no in-repo TestDocs/) — see docs/TESTING.md"
}

// MARK: - Armed-mode vacuity guards

/// Job 535: the flip side of "unarmed must skip, never fail" is "armed must actually see a
/// real corpus, never silently pass zero fixtures." Every OTHER file in this tree that lists
/// `TestDocs/ws7`/`ws4`/`oracle` builds its list via `(try? …) ?? []`, which is the right
/// shape for `@Test(arguments:)` (an empty array degrades to a clean Skip) but would ALSO
/// swallow a genuinely broken/partial corpus while armed into that same silent-empty shape.
/// This suite is the one place that checks the raw corpus directories directly and fails
/// loud if armed produces nothing — it runs (and only runs) when `isArmed`, mirroring every
/// other gate in this file.
@Suite struct PrivateCorpusArmedVacuityGuardTests {
    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func ws7DirectoryIsNotEmptyWhenArmed() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: PrivateCorpusSupport.ws7Directory.path)
        #expect(!names.isEmpty,
                "vacuity guard: armed (CTRLKD_PRIVATE_CORPUS or in-repo TestDocs/) but TestDocs/ws7 produced zero fixtures")
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func ws4DirectoryIsNotEmptyWhenArmed() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: PrivateCorpusSupport.ws4Directory.path)
        #expect(!names.isEmpty,
                "vacuity guard: armed but TestDocs/ws4 produced zero fixtures")
    }

    @Test(.enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
    func oracleManifestsAreNotEmptyWhenArmed() throws {
        #expect(!OracleManifest.files.isEmpty,
                "vacuity guard: armed but TestDocs/oracle/python-printed-manifest.json parsed to zero entries")
        #expect(!OutputManifest.files.isEmpty,
                "vacuity guard: armed but TestDocs/oracle/output-manifest-v12.json parsed to zero entries")
    }
}

// MARK: - PixelOracleAppEngine / MultipageMargins — restored for this public snapshot
//
// Restored verbatim from commit 9e126aa (job-535, the verified public birth tree) for
// public-v4-candidate. This tree strips PixelOracleAppEngineTests.swift and
// MultipageMarginTests.swift (both private-corpus-tier files, docs/TESTING.md /
// Monorepo-Layout-Proposal.md section 3.3), but surviving public/sawyer-armed files still
// call these two shim types: `PixelOracleAppEngine.renderApp`/`renderEngine` (used by
// TitleAscenderTests, PrintedStructuralParityTests) and `MultipageMargins.testDocsDirectory`
// (used by AppleEventDispatchTests, AppleEventLifecycleBreadcrumbsTests,
// AppleEventVirginDispatchTests, ConvertCommandReceiverDispatchTests, ExportCommandTests,
// PageSettingsPickerTests). The private canonical tree does NOT carry
// this shim — it has the two full original files instead (docs/TESTING.md, job-536) — so this
// block is a public-snapshot-only restoration, not a permanent addition to the private tree.

/// PIXEL ORACLE — first customer: the app's real view pipeline vs the engine's real
/// `emitPDF`. Job 223's original adapter, `SoftReturnTests/PixelOracleAppEngineTests.swift`,
/// was deleted whole by the private-material strip (`41d858e`) along with `TestDocs/` itself
/// — correctly, since its own two tests carried a HARD (non-skippable) vacuity guard that
/// would have turned "corpus absent" into a loud failure in the public tree. But the enum's
/// `renderApp`/`renderEngine`/`rasterizePDF` are still called by two surviving files
/// (`TitleAscenderTests`, `PrintedStructuralParityTests`) that DO gate their own callers
/// correctly (`.enabled(if: PrivateCorpusSupport.isArmed)`) — this is only the helper surface
/// those two files actually need, not a restoration of the deleted file's own test methods
/// (`regionDiffEnumeration`, `selfCheckOracleActuallySeesAnImage`, the PIX-resolution-status
/// gate) or its `approvedUnresolvedSkipList`, none of which any surviving caller reaches.
@MainActor
enum PixelOracleAppEngine {
    /// Points-to-pixels for both raster paths — fixed, not the process's actual (headless,
    /// often 1x) screen backing scale, so the comparison grid is identical regardless of what
    /// display (if any) this session has.
    static let scale: CGFloat = 2.0

    enum CaptureError: Error, CustomStringConvertible {
        case noPDFDocument
        case noPage(Int)
        case noBitmap(String)
        var description: String {
            switch self {
            case .noPDFDocument: return "engine emitPDF bytes did not parse as a PDFDocument"
            case .noPage(let i): return "engine PDF has no page \(i)"
            case .noBitmap(let where_): return "\(where_): could not build a bitmap"
            }
        }
    }

    /// App side: the REAL view pipeline (`DocumentWindowController` -> `PagedDocumentView` ->
    /// `PageTextView`), Printed style, Continuous Scroll — captured through
    /// `pagedView.cacheDisplay`, not each `PageTextView` alone, since running heads/feet and
    /// the grey-desk/white-paper fill are drawn by `PagedDocumentView` itself.
    static func renderApp(fixtureURL: URL) throws -> [PixelOracleKit.PageImage] {
        let bytes = [UInt8](try Data(contentsOf: fixtureURL))
        let defaults = UserDefaults(suiteName: "PixelOracleAppEngine.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults),
                                       docPath: fixtureURL.path)
        let controller = DocumentWindowController(state: state)
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.showWindow(nil)
        controller.setStyle(.printed)
        controller.setDisplay(.continuousScroll)
        guard let content = controller.window?.contentView else {
            throw CaptureError.noBitmap("window.contentView")
        }
        guard let scrollView = RenderProbeKit.descendants(content)
            .compactMap({ $0 as? NSScrollView }).first
        else { throw CaptureError.noBitmap("NSScrollView") }
        scrollView.magnification = 1.0
        content.layoutSubtreeIfNeeded()

        let pagedView = controller.pagedView
        var images: [PixelOracleKit.PageImage] = []
        for index in 0..<pagedView.pageCount {
            let rect = pagedView.rect(ofPage: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            let pixelsWide = max(1, Int((rect.width * scale).rounded()))
            let pixelsHigh = max(1, Int((rect.height * scale).rounded()))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw CaptureError.noBitmap("page \(index)") }
            bitmap.size = rect.size
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                pagedView.cacheDisplay(in: rect, to: bitmap)
            }
            images.append(PixelOracleKit.PageImage(
                label: "p\(index + 1)", bitmap: bitmap, pointSize: rect.size))
        }
        controller.close()
        return images
    }

    /// Reference side: the engine's real PDF bytes (`emitPDF(doc, mode: .printed)`),
    /// rasterized through PDFKit's own `PDFPage.thumbnail(of:for:)`. Resolves `.PIX` tags via
    /// `DocumentPictures.resolve` — the SAME resolver `DocumentState.init`/`ExportEngine.render`
    /// call — and threads the result into `EmitOptions.pixResults` so this reference side
    /// embeds exactly what a real Printed export would.
    static func renderEngine(fixtureURL: URL) throws -> [PixelOracleKit.PageImage] {
        let bytes = [UInt8](try Data(contentsOf: fixtureURL))
        let document = try parse(bytes, variant: nil)
        let pixResults = DocumentPictures.resolve(document, docPath: fixtureURL.path)
        let pdfBytes = emitPDF(document, mode: .printed, options: EmitOptions(pixResults: pixResults))
        return try rasterizePDF(pdfBytes)
    }

    /// PDF bytes -> one `PageImage` per page, via PDFKit's own `PDFPage.thumbnail(of:for:)` —
    /// factored out of `renderEngine` so a caller with PDF bytes from some OTHER `EmitOptions`
    /// rasterizes them identically rather than re-deriving this loop.
    static func rasterizePDF(_ pdfBytes: [UInt8]) throws -> [PixelOracleKit.PageImage] {
        guard let pdfDocument = PDFDocument(data: Data(pdfBytes)) else { throw CaptureError.noPDFDocument }
        var images: [PixelOracleKit.PageImage] = []
        for index in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: index) else { throw CaptureError.noPage(index) }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { throw CaptureError.noPage(index) }
            let pixelSize = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox)
            guard let tiff = thumbnail.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff)
            else { throw CaptureError.noBitmap("engine page \(index)") }
            images.append(PixelOracleKit.PageImage(
                label: "p\(index + 1)", bitmap: bitmap, pointSize: bounds.size))
        }
        return images
    }
}

// MARK: - MultipageMargins — restored, minimal surface (job 534/535)

/// `MultipageMarginTests.swift` (job 476's multipage pixel-truth oracle, 608 lines) was
/// deleted whole by the same strip, `TestDocs/`-dependent top to bottom. Six surviving files
/// (`AppleEventDispatchTests`, `AppleEventLifecycleBreadcrumbsTests`,
/// `AppleEventVirginDispatchTests`, `ConvertCommandReceiverDispatchTests`,
/// `ExportCommandTests`, `PageSettingsPickerTests`) only ever called ONE member of it —
/// `testDocsDirectory`, to build a path to a single named fixture (`ws4/INDIAN.ws` or
/// `ws7/OLDTIMES.WS`) for their own, unrelated tests (Apple Event dispatch, export command
/// decoding, page-settings pickers) — none of them use the file's actual pagination-budget
/// oracle (`captureAllPages`/`classify`/the four evidence/permanent-oracle tests). Restoring
/// only that one property is the smallest correct fix; it now routes through the same shared
/// gate every other file uses instead of its own private `#filePath` walk.
enum MultipageMargins {
    static var testDocsDirectory: URL { PrivateCorpusSupport.testDocsDirectory }
}
