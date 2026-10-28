import CtrlKD
import Foundation

/// The app group the app shares with its Quick Look extensions. The Mac's is the team-prefixed group from batch 8
/// (`SpotlightIndexQueue` uses it too); the iPhone's is the `group.` one registered for the app and both of its
/// extensions.
public enum AppGroup {
    #if os(macOS)
    public static let identifier = "RC448RH3EN.softreturn"
    #else
    public static let identifier = "group.me.beforeti.softreturn"
    #endif
}

/// Quick Look's thumbnails, on both platforms.
public enum QuickLookThumbnail {
    /// No thumbnail is drawn past this many pixels on a side, whatever size is asked for.
    public static let maxDimension: CGFloat = 1024
}

/// Job 203 (b10 leg 4): the app-group channel that carries the app's defaults to its Quick Look extensions, which have
/// no per-file Page Settings UI of their own — a spacebar preview or an icon thumbnail has no window to carry a choice
/// in. The Mac's document footer "Use as Default for Quick Look" item and Settings write the page-settings preset; both
/// apps write their default quirks (`keepQuirkDefaultsCurrent`). Every extension, and the iPhone's own thumbnails,
/// read both.
///
/// Failure-proof: a missing container (entitlement not provisioned), a missing key (nothing ever set), or an
/// unrecognized preset name (a newer app wrote a name this build doesn't know) all resolve to "no override, render as
/// shipped" — never a crash or a thrown error. A Quick Look render can never be allowed to fail on account of reading
/// a preference.
public enum QuickLookPageSettingsPreference {
    public static let groupIdentifier = AppGroup.identifier
    private static let key = "pageSettingsDefaultPreset"
    private static let quirksKey = "quirkDefaults"
    private static let printedByKey = "printedBy"

    /// The app group's suite, or nil where the app has no group (not provisioned).
    public static var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: groupIdentifier)
    }

    /// Called from the app (the main process) only — the extensions never write this
    /// key, only read it. `nil` clears the key entirely rather than writing an empty string,
    /// so `resolvedDefault` sees exactly the same "nothing set" state as a fresh install.
    public static func setDefault(_ preset: DocumentOperations.PageSettingsPreset?,
                           defaults: UserDefaults? = QuickLookPageSettingsPreference.groupDefaults) {
        if let preset {
            defaults?.set(preset.rawValue, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    /// Batch 46 (Jon's quirks rulings; Athena: Quick Look uses the app default only): the app's default quirks, for
    /// the two extensions. Written by the app at launch and whenever Settings changes them.
    public static func setQuirkDefaults(_ quirks: QuirkChoices,
                                 defaults: UserDefaults? = QuickLookPageSettingsPreference.groupDefaults) {
        guard let data = try? JSONEncoder().encode(quirks) else { return }
        defaults?.set(data, forKey: quirksKey)
    }

    /// Which WordStar prints a WS4 file (`SettingsStore.printedBy`), for the two extensions. Written by the app at
    /// launch and whenever Settings changes it.
    public static func setPrintedBy(_ printedBy: PrintedBy,
                                    defaults: UserDefaults? = QuickLookPageSettingsPreference.groupDefaults) {
        defaults?.set(printedBy.rawValue, forKey: printedByKey)
    }

    /// The app's choice of which WordStar prints a WS4 file, or WordStar 4 when nothing is stored or it is unknown.
    public static func resolvedPrintedBy(defaults: UserDefaults? = QuickLookPageSettingsPreference.groupDefaults
    ) -> PrintedBy {
        defaults?.string(forKey: printedByKey).flatMap(PrintedBy.init(rawValue:)) ?? .own
    }

    /// The app's default quirks, or what shipped when nothing is stored or it cannot be read.
    public static func resolvedQuirkDefaults(defaults: UserDefaults? = QuickLookPageSettingsPreference.groupDefaults
    ) -> QuirkChoices {
        guard let data = defaults?.data(forKey: quirksKey),
              let quirks = try? JSONDecoder().decode(QuirkChoices.self, from: data) else { return .shipped }
        return quirks
    }

    /// `nil` means "no override" — an absent key, an unrecognized name, or no app-group
    /// container at all are indistinguishable to a caller and mean the same thing: render as
    /// if this feature had never been touched. `defaults` is injectable so a test (or the
    /// byte-parity gate's own "bare invocation" reconstruction, which must stay unaffected by
    /// whatever this session's REAL shared container happens to hold) can force a
    /// deterministic "nothing set" read by passing `nil` outright.
    public static func resolvedDefault(defaults: UserDefaults? = QuickLookPageSettingsPreference.groupDefaults
    ) -> DocumentOperations.PageSettingsPreset? {
        guard let name = defaults?.string(forKey: key) else { return nil }
        return DocumentOperations.PageSettingsPreset(rawValue: name)
    }
}

extension QuickLookPageSettingsPreference {
    /// The app group's copy of `settings`' default quirks, written now and again whenever they change. Each app calls
    /// it once, at launch.
    @MainActor
    public static func keepQuirkDefaultsCurrent(from settings: SettingsStore = .shared) {
        setQuirkDefaults(settings.quirkDefaults)
        quirkObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.quirkDefaultsDidChange, object: settings, queue: .main) { _ in
                MainActor.assumeIsolated { setQuirkDefaults(SettingsStore.shared.quirkDefaults) }
            }
        // and which WordStar prints a WS4 file, the same way
        setPrintedBy(settings.printedBy)
        printedByObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.printedByDidChange, object: settings, queue: .main) { _ in
                MainActor.assumeIsolated { setPrintedBy(SettingsStore.shared.printedBy) }
            }
    }

    @MainActor private static var quirkObserver: (any NSObjectProtocol)?
    @MainActor private static var printedByObserver: (any NSObjectProtocol)?
}
