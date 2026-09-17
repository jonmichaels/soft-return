import Foundation

/// Batch 46 (Jon's option 2, 2026-09-16): a document's own quirk choices, kept by the app — never in the document. Keyed
/// to the file's identity on its volume, with the volume's UUID beside it:
/// - the kernel's document identifier (`URLResourceKey.documentIdentifierKey`), when the file has one: it follows the
///   file through a move or rename on the volume, survives restarts and safe saves, and is not carried by a copy. The
///   kernel assigns one only to a file something tracks, so most files have none (QuirkOverrideStoreTests);
/// - otherwise the file's number on the volume (`FileAttributeKey.systemFileNumber`, `st_ino`), which also follows a
///   rename or move on the volume and is not carried by a copy, but not a safe save by another app;
/// - otherwise the path.
/// A file moved to another volume, replaced by a copy or saved over by another app loses its choices and opens on the
/// app's defaults; that is tolerated, by ruling.
///
/// Both apps use it: all three are Foundation on macOS and iOS alike.
@MainActor
public final class QuirkOverrideStore {
    public static let shared = QuirkOverrideStore()

    private let defaults: UserDefaults
    static let storageKey = "quirks.documentOverrides"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The file's identity as a stored key, or nil for a URL that names no readable file.
    public nonisolated static func key(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.documentIdentifierKey, .volumeUUIDStringKey])
        let volume = values?.volumeUUIDString ?? "no-volume-uuid"
        if let identifier = values?.documentIdentifier {
            return "document:\(volume):\(identifier)"
        }
        if let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber {
            return "file:\(volume):\(number.uint64Value)"
        }
        return "path:\(url.standardizedFileURL.resolvingSymlinksInPath().path)"
    }

    private var all: [String: [String: Bool]] {
        get { defaults.dictionary(forKey: Self.storageKey) as? [String: [String: Bool]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.storageKey) }
    }

    /// The choices stored for `url`'s file; none when nothing is stored or the file cannot be identified.
    public func overrides(for url: URL?) -> [String: Bool] {
        guard let url, let key = Self.key(for: url) else { return [:] }
        return all[key] ?? [:]
    }

    /// Stores `overrides` for `url`'s file; none removes the entry.
    public func setOverrides(_ overrides: [String: Bool], for url: URL?) {
        guard let url, let key = Self.key(for: url) else { return }
        var stored = all
        stored[key] = overrides.isEmpty ? nil : overrides
        all = stored
    }
}
