import CtrlKD
import Foundation

/// Everything about one document window worth putting back the way it was: the value AND
/// the provenance for style/zoom/display (so a restored window still reads "(Default)"
/// rather than lying that the user chose it), the variant and page size ONLY when the user
/// actually chose them by hand (the detected/default answers are cheap to recompute fresh
/// from the reopened file and settings, and restoring a stale detected value could disagree
/// with a re-parse), and the scroll position — the one piece of "cheap" state the spec asks
/// for that has no provenance of its own.
///
/// Deliberately a plain `Codable` struct rather than writing straight into an `NSCoder`:
/// that is what makes "encode/decode of the restorable state" testable headlessly, with no
/// window and no real state-restoration machinery, and it is the one payload
/// `DocumentWindowController` hands to `NSCoder` as a single blob.
struct WindowRestorableState: Codable, Equatable {
    var style: ViewStyle
    var styleProvenance: SettingProvenance
    var display: PageDisplay
    var displayProvenance: SettingProvenance
    var zoom: ZoomSetting
    var zoomProvenance: SettingProvenance
    var variant: Variant
    var variantIsManual: Bool
    var pageSize: NamedPageSize?
    var pageSizeIsManual: Bool
    var scrollX: Double
    var scrollY: Double
    /// Job 314: whether the Inspector (View ▸ Show Document Info) was open — restored panels
    /// follow the same "put it back the way it was" contract as everything else here.
    /// Defaulted so decoding a blob written before this job's field existed still succeeds
    /// (closed, the safe default) rather than failing the whole restore.
    var showDocumentInfo: Bool = false

    @MainActor
    init(documentState: DocumentState, scrollOrigin: CGPoint, showDocumentInfo: Bool = false) {
        style = documentState.style.value
        styleProvenance = documentState.style.provenance
        display = documentState.display.value
        displayProvenance = documentState.display.provenance
        zoom = documentState.zoom.value
        zoomProvenance = documentState.zoom.provenance
        variant = documentState.variant.value
        variantIsManual = documentState.variant.provenance == .manual
        pageSize = documentState.pageSize.value
        pageSizeIsManual = documentState.pageSize.provenance == .manual
        scrollX = Double(scrollOrigin.x)
        scrollY = Double(scrollOrigin.y)
        self.showDocumentInfo = showDocumentInfo
    }

    /// Put this state back onto a freshly reopened document. Variant and page size only
    /// reapply when they were the user's own choice — `setVariant`/`setPageSize` always mark
    /// `.manual`, which would misreport a merely-detected or default value as something the
    /// user picked.
    @MainActor
    func apply(to documentState: DocumentState) {
        documentState.style = Resolved(style, styleProvenance)
        documentState.display = Resolved(display, displayProvenance)
        documentState.zoom = Resolved(zoom, zoomProvenance)
        if variantIsManual {
            // Job 220 (finding C): best-effort — if the file on disk changed since last quit
            // and no longer parses under the remembered variant, the reopened window just
            // falls back to the auto-detected one rather than restoration itself failing; a
            // dropped restoration preference is acceptable (see this type's own doc comment).
            _ = documentState.setVariant(variant)
        }
        if pageSizeIsManual, let pageSize {
            documentState.setPageSize(pageSize)
        }
    }
}

// MARK: - Codable-through-NSCoder

/// `CtrlKD.Variant` and `SettingProvenance` are plain-string enums with no Codable
/// conformance of their own; both get the standard library's free `RawRepresentable`
/// synthesis, exactly the pattern `SettingsStore.swift` already uses for `ViewStyle`,
/// `PageDisplay` and `NamedPageSize`.
extension Variant: Codable {}
extension SettingProvenance: Codable {}

/// One key, one JSON blob, gated by `SettingsStore.restoreWindowsOnLaunch` — see
/// `DocumentWindowController.window(_:willEncodeRestorableState:)`.
enum WindowRestorationCoding {
    static let stateKey = "SR.documentWindowState"

    static func encode(_ state: WindowRestorableState, into coder: NSCoder) {
        // Restoration best-effort: a dropped view-state blob just means the reopened window
        // falls back to defaults, the same acceptable outcome as the system never restoring
        // the window at all (see this file's own doc comment on that being a real, normal path).
        guard let data = try? JSONEncoder().encode(state) else { return }
        coder.encode(data, forKey: stateKey)
    }

    static func decode(from coder: NSCoder) -> WindowRestorableState? {
        guard let data = coder.decodeObject(forKey: stateKey) as? Data else { return nil }
        // Same best-effort contract as `encode` above — a blob from an older/incompatible
        // build decodes to nil, which the caller already treats as "nothing to restore".
        return try? JSONDecoder().decode(WindowRestorableState.self, from: data)
    }
}
