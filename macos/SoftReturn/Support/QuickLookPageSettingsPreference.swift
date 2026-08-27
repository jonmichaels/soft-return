import Foundation

/// Job 203 (b10 leg 4): the app-group channel that lets the document window's footer "Use
/// as Default for Quick Look" item reach the two extensions (`SoftReturnQuickLook`,
/// `SoftReturnThumbnail`) that have no per-file Page Settings UI of their own — a Finder
/// spacebar preview or icon thumbnail has no window to carry a choice in.
///
/// Same app-group suite as `SpotlightIndexQueue` (`RC448RH3EN.softreturn`, the b8 group) and
/// the same failure-proof shape: a missing container (entitlement not provisioned), a
/// missing key (nothing ever set), or an unrecognized preset name (a newer app wrote a name
/// this build doesn't know) all resolve to `nil` — "no override, render exactly as before
/// this feature existed" — never a crash or a thrown error. A Quick Look render can never be
/// allowed to fail on account of reading a preference.
enum QuickLookPageSettingsPreference {
    static let groupIdentifier = SpotlightIndexQueue.groupIdentifier
    private static let key = "pageSettingsDefaultPreset"

    private static func containerDefaults(groupIdentifier: String) -> UserDefaults? {
        UserDefaults(suiteName: groupIdentifier)
    }

    /// Called from the app (the main process) only — the two extensions never write this
    /// key, only read it. `nil` clears the key entirely rather than writing an empty string,
    /// so `resolvedDefault` sees exactly the same "nothing set" state as a fresh install.
    static func setDefault(_ preset: DocumentOperations.PageSettingsPreset?,
                           defaults: UserDefaults? = QuickLookPageSettingsPreference
                               .containerDefaults(groupIdentifier: QuickLookPageSettingsPreference.groupIdentifier)) {
        if let preset {
            defaults?.set(preset.rawValue, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    /// `nil` means "no override" — an absent key, an unrecognized name, or no app-group
    /// container at all are indistinguishable to a caller and mean the same thing: render as
    /// if this feature had never been touched. `defaults` is injectable so a test (or the
    /// byte-parity gate's own "bare invocation" reconstruction, which must stay unaffected by
    /// whatever this session's REAL shared container happens to hold) can force a
    /// deterministic "nothing set" read by passing `nil` outright.
    static func resolvedDefault(defaults: UserDefaults? = QuickLookPageSettingsPreference
                                     .containerDefaults(groupIdentifier: QuickLookPageSettingsPreference.groupIdentifier)
    ) -> DocumentOperations.PageSettingsPreset? {
        guard let name = defaults?.string(forKey: key) else { return nil }
        return DocumentOperations.PageSettingsPreset(rawValue: name)
    }
}
