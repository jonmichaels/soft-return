import CtrlKD
import Foundation

/// The file → `CSSearchableItemAttributeSet`-shaped values the Spotlight importer indexes.
///
/// Kept here, in the app target, rather than in an importer appex: Tuist's graph linter
/// refuses a unit-test target that depends on an app-extension target (see
/// `QuickLookExtensionTests.swift`'s doc comment for the exact error) — the same restriction
/// that made the now-removed `com.apple.spotlight.import` appex (`SoftReturnSpotlightImporter`,
/// deleted in job 181 Part 2; Apple DTS confirms that extension point is never invoked by the
/// OS) carry its own hand-mirrored copy of this logic rather than import this module. So the
/// actual transformation logic lives here, where `SoftReturnTests` can reach and test it
/// headlessly via `@testable import SoftReturn`. The classic `SoftReturnImporter`
/// `.mdimporter` — the mechanism that actually works — carries its own mirrored copy for the
/// same reason (`ImporterCore.swift`).
///
/// Built entirely on `DocumentOperations`: this is what "the shared layer" looks like from
/// the indexing side. Spotlight, the App Intents, and (later) an AppleScript implementation
/// all ask the same `open`/`convert` functions for the same answers.
public enum SpotlightIndexing {

    /// What gets attached to a `CSSearchableItemAttributeSet` for one file. Plain values,
    /// not the CoreSpotlight type itself — CoreSpotlight isn't available to every caller of
    /// this type (a unit test doesn't want to construct a live attribute set just to make an
    /// assertion), and the appex is the only place that ever turns this into one.
    public struct Attributes: Equatable, Sendable {
        /// The filename, extension included — the closest thing to a title an on-disk
        /// WordStar-era file has; the format carries no in-band title field of its own.
        public let title: String
        /// Modern-mode plain text — searchable words, not control bytes. See
        /// `DocumentOperations.plainTextContent`.
        public let textContent: String
        /// The library's own pagination count. See `DocumentOperations.pageCount`.
        public let pageCount: Int
        /// What the detector said. Spotlight indexes what a file actually IS — there is no
        /// UI here to force a variant, unlike the app's own "Force Variant" menu.
        public let variant: Variant
        /// Keywords a search should also match: the variant name, plus — for `ws4`/`ws5+`
        /// only — every distinct dot command the file used, so "hm" or "pl" finds the file
        /// that set one, the same evidence `--diagnose`'s `dot_commands` reports.
        public let keywords: [String]
    }

    public enum IndexingError: Error, LocalizedError, Sendable {
        case notConvertible(variant: Variant, reason: String)

        public var errorDescription: String? {
            switch self {
            case .notConvertible(let variant, let reason):
                return "Not a convertible WordStar-era document (detected \(variant.rawValue): \(reason))."
            }
        }
    }

    /// Build the attributes Spotlight should index for the file at `filename`, from its raw
    /// `data`.
    ///
    /// `filename` travels separately from `data` because a caller (the appex) already has
    /// the URL Spotlight handed it — re-deriving a name from bytes would be nonsensical, and
    /// the title is exactly the one thing CtrlKD cannot supply on its own.
    public static func attributes(forFilename filename: String, data: [UInt8]) throws -> Attributes {
        do {
            let opened = try DocumentOperations.open(data: data)
            let text = try DocumentOperations.plainTextContent(data: data)
            let pages = try DocumentOperations.pageCount(data: data)

            var keywords = [opened.detection.variant.rawValue]
            if opened.detection.variant == .ws4 || opened.detection.variant == .ws5plus {
                keywords += Set(opened.document.dotCommands).sorted()
            }

            return Attributes(
                title: filename, textContent: text, pageCount: pages,
                variant: opened.detection.variant, keywords: keywords)
        } catch let DocumentOperations.OperationError.notConvertible(variant, reason) {
            throw IndexingError.notConvertible(variant: variant, reason: reason)
        }
    }
}
