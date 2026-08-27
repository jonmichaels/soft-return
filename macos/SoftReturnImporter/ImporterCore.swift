import CtrlKD
import Foundation
import OSLog

/// The real work, in Swift: same handful of CtrlKD calls
/// `SpotlightIndexing.attributes(forFilename:data:)` (the app target) and
/// `ImportProvider.update(_:forFileAt:)` (the dead `com.apple.spotlight.import` appex,
/// `SoftReturnSpotlightImporter/ImportProvider.swift`) both make -- copied here rather than
/// shared for the same reason those two already diverge from each other: a CFPlugIn bundle
/// cannot import the app target's module, and cannot depend on an app-extension target
/// either. `SpotlightIndexing` remains the tested, canonical version; if the logic ever needs
/// to change, change it there first and mirror the change into this file and
/// `ImportProvider.swift`.
///
/// `@objc(SRImporterCore)` + `NSObject` so `MDImporterGlue.m` -- the classic CFPlugIn
/// boilerplate that the OS actually calls -- can reach this through the target's generated
/// `SoftReturnImporter-Swift.h`, without hand-writing the parse/convert logic twice in C.
///
/// job-115: `mdworker`'s restricted environment was silently zeroing every attribute -- the
/// identical extraction code passes in-process (`MDImporterExecutedPathTests`), but under
/// `mdworker` the whole call came back empty, no `kMDItemTextContent` and no error either.
/// One unguarded stage failing (or crashing) used to take every other attribute down with it,
/// since the original code computed the whole dictionary in one shot and returned all-or-
/// nothing. Below, each attribute is extracted through its own guard (`attempt(_:url:_:)`), in
/// increasing order of risk -- `textContent` (the attribute Spotlight search lives on) first,
/// then the free `title`, then `pageCount` and `keywords`, which both need a parsed `Document`
/// but are guarded independently of each other. `os_log` brackets every stage so a future
/// `log show` against `me.beforeti.softreturn.importer` can show exactly where a real
/// `mdworker` run stops, even if it stops somewhere `do`/`catch` here can't reach.
@objc(SRImporterCore)
public final class SRImporterCore: NSObject {

    private static let log = Logger(subsystem: "me.beforeti.softreturn.importer", category: "extraction")

    /// The real pageCount computation: `docToPagelines` walks CoreText/font machinery to lay
    /// out pages, the prime suspect for job-115's mdworker-sandbox failure (untested, not
    /// assumed -- see the job-115 write-up).
    ///
    /// `nonisolated(unsafe)`: `GetMetadataForURL` is CFPlugIn's classic single-threaded,
    /// synchronous entry point -- `mdworker` never calls into the same plugin instance
    /// concurrently -- and the only mutator of `pageCounter` below is the test-only setter,
    /// which the executed-path test calls strictly before, never during, a `GetMetadataForURL`
    /// call.
    private nonisolated(unsafe) static let realPageCounter: (Document) throws -> Int = { document in
        max(1, docToPagelines(document, printed: true).count)
    }

    /// The pageCount stage, reached through this injectable seam rather than a direct
    /// `docToPagelines` call, so `MDImporterExecutedPathTests` can force just this one stage
    /// to fail (via `setForcedPageCountFailureForTesting(_:)` below, reached from the test's
    /// executed-path harness through `MDImporterGlue.m`'s `SRImporterSetForcedPageCountFailureForTesting`)
    /// and prove `textContent` survives it. Production always runs `realPageCounter`.
    private nonisolated(unsafe) static var pageCounter: (Document) throws -> Int = SRImporterCore.realPageCounter

    private struct ForcedPageCountFailure: Error, LocalizedError {
        var errorDescription: String? { "job-115 executed-path test: forced pageCount failure" }
    }

    /// Testing-only seam (job-115), called from `MDImporterGlue.m`'s
    /// `SRImporterSetForcedPageCountFailureForTesting` -- which the executed-path test harness
    /// reaches via `dlsym`, the same by-name resolution `SoftReturnImporterFactory` itself is
    /// found through, since the test target cannot import this bundle's module (Tuist's graph
    /// linter refuses it, confirmed the same way `QuickLookExtensionTests` confirmed it for an
    /// app-extension target). Never called by `mdworker`.
    @objc(setForcedPageCountFailureForTesting:)
    public static func setForcedPageCountFailureForTesting(_ value: Bool) {
        pageCounter = value ? { _ in throw ForcedPageCountFailure() } : realPageCounter
    }

    /// Runs `block`, logging and swallowing any error under `stage` so callers can treat the
    /// result as "this one attribute, or nothing" without one stage's failure reaching any
    /// other stage's result.
    private static func attempt<T>(_ stage: String, url: URL, _ block: () throws -> T) -> T? {
        do {
            let value = try block()
            log.info("\(stage, privacy: .public) ok: \(url.path, privacy: .public)")
            return value
        } catch {
            log.error("\(stage, privacy: .public) failed: \(url.path, privacy: .public) - \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Returns `nil` on any failure to read `url` -- `MDImporterGlue.m` treats `nil`
    /// as "leave `attributes` untouched, return false", the documented `GetMetadataForURL`
    /// contract for "this importer has nothing to say about this file". Once the bytes are in
    /// hand, every individual attribute is best-effort (see the class doc comment): a failure
    /// in one never removes an attribute another stage already produced.
    @objc(attributesForFileAtURL:)
    public static func attributes(forFileAt url: URL) -> [String: Any]? {
        let start = DispatchTime.now()
        guard let data = try? Data(contentsOf: url) else {
            log.error("read failed: \(url.path, privacy: .public)")
            return nil
        }
        let bytes = [UInt8](data)
        log.info("begin: \(url.path, privacy: .public) (\(bytes.count, privacy: .public) bytes)")

        var result: [String: Any] = [:]

        // textContent FIRST -- the one attribute Spotlight search actually lives on.
        result["textContent"] = attempt("textContent", url: url) {
            try convert(bytes, to: "text", mode: .modern)
        }

        result["title"] = url.lastPathComponent

        // pageCount and keywords both need a parsed Document, but are guarded independently
        // of each other below: a keywords failure must not take pageCount with it, or vice
        // versa. If parse itself fails, both are skipped -- textContent and title already
        // above are unaffected either way.
        if let document = attempt("parse", url: url, { try parse(bytes) }) {
            result["pageCount"] = attempt("pageCount", url: url) {
                try pageCounter(document)
            }

            result["keywords"] = attempt("keywords", url: url) { () -> [String] in
                let detection = detect(bytes)
                var keywords = [detection.variant.rawValue]
                if detection.variant == .ws4 || detection.variant == .ws5plus {
                    keywords += Set(document.dotCommands).sorted()
                }
                return keywords
            }
        }

        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        if result["textContent"] == nil {
            log.error("done: \(url.path, privacy: .public) keys=\(result.keys.sorted(), privacy: .public) in \(durationMs, privacy: .public)ms")
        } else {
            log.info("done: \(url.path, privacy: .public) keys=\(result.keys.sorted(), privacy: .public) in \(durationMs, privacy: .public)ms")
        }

        return result.isEmpty ? nil : result
    }
}
