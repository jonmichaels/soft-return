import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// Window restoration: the encode/decode round trip of the restorable state (headless, no
/// window and no real state-restoration machinery involved), the preference's default value,
/// and — the part a screenshot cannot show — that turning the preference off actually stops
/// `DocumentWindowController` from writing anything at quit time.

@MainActor
private func throwawaySettings() -> SettingsStore {
    SettingsStore(defaults: UserDefaults(suiteName: "SoftReturnTests.\(UUID().uuidString)")!)
}

@MainActor
private func makeDocumentState() throws -> DocumentState {
    let url = Oracle.fixturesDirectory.appendingPathComponent("no-dot-commands.ws4")
    let bytes = [UInt8](try Data(contentsOf: url))
    return try DocumentState(data: bytes, settings: throwawaySettings())
}

/// A coder that just remembers what was encoded under each key — enough to test the gating
/// and the shape of what gets written, without any of `NSKeyedArchiver`'s own machinery.
private final class RecordingCoder: NSCoder {
    private var storage: [String: Any] = [:]
    override func encode(_ object: Any?, forKey key: String) { storage[key] = object }
    override func decodeObject(forKey key: String) -> Any? { storage[key] }
    var encodedKeys: Set<String> { Set(storage.keys) }
}

// MARK: - Preference default

@Test @MainActor func restoreWindowsOnLaunchDefaultsToOn() {
    #expect(throwawaySettings().restoreWindowsOnLaunch,
            "a one-afternoon user should not lose their windows without having asked to")
}

@Test @MainActor func restoreWindowsOnLaunchPersistsAcrossReload() {
    let name = "SoftReturnTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    SettingsStore(defaults: defaults).restoreWindowsOnLaunch = false
    #expect(SettingsStore(defaults: defaults).restoreWindowsOnLaunch == false)
}

// MARK: - Encode/decode round trip

@Test @MainActor func windowRestorableStateRoundTripsThroughJSON() throws {
    let state = try makeDocumentState()
    state.style.setManually(.modern)
    state.zoom.setManually(.percent(150))
    state.display.setManually(.continuousScroll)
    _ = state.setVariant(.printstream)
    state.setPageSize(.a4)

    let original = WindowRestorableState(documentState: state, scrollOrigin: CGPoint(x: 12, y: 340))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WindowRestorableState.self, from: data)

    #expect(decoded == original)
    #expect(decoded.style == .modern)
    #expect(decoded.zoom == .percent(150))
    #expect(decoded.display == .continuousScroll)
    #expect(decoded.variant == .printstream)
    #expect(decoded.variantIsManual)
    #expect(decoded.pageSize == .a4)
    #expect(decoded.pageSizeIsManual)
    #expect(decoded.scrollX == 12)
    #expect(decoded.scrollY == 340)
}

/// Detected/default values round-trip too, but `apply(to:)` must not promote them to Manual —
/// only a value the user actually picked should come back marked that way.
@Test @MainActor func applyingRestorableStateOnlyReappliesManualVariantAndPageSize() throws {
    let state = try makeDocumentState()
    #expect(state.variant.provenance == .detected)
    #expect(state.pageSize.provenance != .manual)

    let restorable = WindowRestorableState(documentState: state, scrollOrigin: .zero)
    #expect(!restorable.variantIsManual)
    #expect(!restorable.pageSizeIsManual)

    let fresh = try makeDocumentState()
    restorable.apply(to: fresh)
    // Untouched: `apply` did not force a manual variant or page size onto a state that never
    // had one, which would misreport a merely-detected value as user-chosen.
    #expect(fresh.variant.provenance == .detected)
    #expect(fresh.pageSize.provenance != .manual)
}

@Test @MainActor func applyingRestorableStateReappliesStyleZoomAndDisplayWithProvenance() throws {
    let state = try makeDocumentState()
    state.style.setManually(.modern)
    state.zoom.setManually(.actual)
    // display left at its default provenance deliberately, to prove provenance survives
    // both ways round the trip, not just the manual case.
    let restorable = WindowRestorableState(documentState: state, scrollOrigin: .zero)

    let fresh = try makeDocumentState()
    restorable.apply(to: fresh)
    #expect(fresh.style.value == .modern)
    #expect(fresh.style.provenance == .manual)
    #expect(fresh.zoom.value == .actual)
    #expect(fresh.zoom.provenance == .manual)
    #expect(fresh.display.provenance == state.display.provenance)
}

// MARK: - The toggle gates writing

@Test @MainActor func toggleOffStopsTheWindowFromWritingAnyRestorableState() throws {
    let state = try makeDocumentState()
    let settings = throwawaySettings()
    settings.restoreWindowsOnLaunch = false
    let controller = DocumentWindowController(state: state, settings: settings)
    let window = try #require(controller.window)

    #expect(window.isRestorable == false,
            "the window itself should not be restorable when the preference is off")

    let coder = RecordingCoder()
    controller.window(window, willEncodeRestorableState: coder)
    #expect(coder.encodedKeys.isEmpty,
            "turning the preference off must stop ANY restorable state from being written")
}

@Test @MainActor func toggleOnWritesRestorableState() throws {
    let state = try makeDocumentState()
    let settings = throwawaySettings()
    settings.restoreWindowsOnLaunch = true
    let controller = DocumentWindowController(state: state, settings: settings)
    let window = try #require(controller.window)

    #expect(window.isRestorable)

    let coder = RecordingCoder()
    controller.window(window, willEncodeRestorableState: coder)
    #expect(coder.encodedKeys.contains(WindowRestorationCoding.stateKey))

    let decoded = WindowRestorationCoding.decode(from: coder)
    #expect(decoded != nil, "what was written must be readable back")
}
