import AppKit
import CoreText

/// Job 306 (b18): registers the four vendored Courier Prime faces
/// (`Vendor/CourierPrime/*.ttf`, SIL OFL 1.1, `Vendor/CourierPrime/VENDORED.md`) — Native's
/// courier-class face (`DocumentRenderer.swift`'s `printedMacFontRows`), bundled because
/// Courier New is too pale beside Printed's PDF-rendered Courier (Jon's ruling 2026-08-14).
///
/// `.process` scope ONLY (`CTFontManagerRegisterFontsForURL`'s own distinction from
/// `.persistent`) — available to this running process' font lookups (`NSFont(name:)`,
/// `NSFontManager`) and gone the moment it exits, never written to the system's font
/// registry. Confirmed via probe (job 306 report): once registered this way, `NSFont(name:
/// "Courier Prime", ...)` resolves the Regular face and `NSFontManager.convert(_:toHaveTrait:)`
/// selects the REAL bundled Bold/Italic/BoldItalic members (distinct `fontName` each,
/// `CourierPrime-Bold`/`-Italic`/`-BoldItalic`) rather than synthesizing — the same
/// `printedApplyTraits` mechanism `printedResolvedMacFont` already used for every other Mac
/// font row needs no changes for this one.
///
/// One file, mirrored VERBATIM into `SoftReturn`/`SoftReturnQuickLook`/`SoftReturnThumbnail`
/// — same pattern `QuickLookNativeRenderer.swift`'s own doc comment explains (an appex can't
/// import the app module, so Tuist compiles the same source into every target that needs it).
/// QuickLook and Thumbnail both need their OWN registration call: job 247's mac-viewing ruling
/// means both appexes render through this same Native font mapping, and each appex's bundle
/// (and `Bundle(for:)` resolution below) is a SEPARATE bundle from the host app's, carrying
/// its own copy of the four TTFs (`Project.swift`'s per-target `resources`).
enum CourierPrimeFontRegistration {
    private final class BundleMarker {}

    private static let faceNames = [
        "CourierPrime-Regular", "CourierPrime-Bold", "CourierPrime-Italic", "CourierPrime-BoldItalic",
    ]

    /// `static let`'s own once-only initialization (Swift guarantees this runs exactly once,
    /// thread-safely, on first access) does the actual registration work; `registerIfNeeded()`
    /// below is just a readable call site — callers never need to reason about "have I already
    /// called this."
    private static let registered: Void = {
        let bundle = Bundle(for: BundleMarker.self)
        for name in faceNames {
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // No error handling beyond this: a face that fails to register simply never
            // resolves via `NSFont(name: "Courier Prime", ...)`, and `printedResolvedMacFont`'s
            // existing `primary`/`falt` fallback to Courier New already covers that case —
            // see `DocumentRenderer.swift`'s courier-class row.
        }
    }()

    /// Call once, as early as possible before any Native-style render — the app calls this
    /// from `applicationWillFinishLaunching`; QL/Thumbnail call it at the top of
    /// `QuickLookNativeRenderer.renderedDocument(fromFileBytes:)`, the one shared entry point
    /// both `PreviewProvider` and `ThumbnailProvider` render through.
    static func registerIfNeeded() {
        _ = registered
    }
}
