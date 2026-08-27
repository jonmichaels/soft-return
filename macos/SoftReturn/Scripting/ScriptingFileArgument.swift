import Foundation

/// Decodes an sdef `type="file"` argument into a `URL`. Cocoa Scripting's own coercion
/// normally hands an `NSURL` for a `POSIX file`/`file`/alias literal, but a script can
/// also pass a bare string path, so every shape gets a chance before this gives up —
/// pure and independent of any live Apple Event, so it is directly unit-testable with
/// fakes standing in for what Cocoa would have decoded.
enum ScriptingFileArgument {
    enum DecodeError: Error, LocalizedError {
        case notAFileReference(Any?)

        var errorDescription: String? {
            switch self {
            case .notAFileReference(let value):
                return "Expected a file reference, got \(String(describing: value))."
            }
        }
    }

    static func url(from raw: Any?) throws -> URL {
        switch raw {
        case let url as URL:
            return url
        case let nsurl as NSURL:
            return nsurl as URL
        case let path as String:
            return URL(fileURLWithPath: path)
        case let descriptor as NSAppleEventDescriptor:
            // `NSAppleEventDescriptor.fileURLValue` (native, macOS 10.11+) coerces directly to a
            // file URL — `typeFileURL` and `typeAlias` both resolve through it. An earlier,
            // hand-rolled replacement here (`coerce(toDescriptorType: typeFileURL)` then
            // `.stringValue`) shadowed this native property with the same name and never actually
            // worked: `typeFileURL` has no registered coercion to `TEXT`, so that path always
            // failed, silently falling through to the raw `.stringValue` fallback below it — which
            // for a file-ish descriptor returns an HFS colon-path ("Macintosh HD:private:tmp:a"),
            // not a POSIX path, so `URL(fileURLWithPath:)` built a nonsense URL instead of
            // throwing. Job 185's hardening pass caught this empirically (`ScriptingFileArgumentTests`);
            // using the native property directly avoids both failure modes.
            if let fileURL = descriptor.fileURLValue {
                return fileURL
            }
            throw DecodeError.notAFileReference(descriptor)
        default:
            throw DecodeError.notAFileReference(raw)
        }
    }

    /// Reads a decoded file argument's bytes through the URL (not a path string), per job
    /// 208's candidate fix — `Data(contentsOf:)` rather than
    /// `FileManager.default.contents(atPath:)`. Job 220 (finding C): throws the real
    /// underlying error (missing file, access denied, ...) instead of collapsing every
    /// failure to `nil` — a bare `try?` here is exactly the silence finding C flags: a read
    /// failure used to surface as nothing more specific than "unreadable", which for
    /// `convert` meant "produced nothing" with no reason why. Callers decide how to report it
    /// (`DiagnoseCommand`/`ImportPageSettingsCommand` fold the reason into their scriptError;
    /// `ConvertCommand`'s per-file batch loop still just counts it failed, per job 216's
    /// ruled reply shape).
    static func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// A `list="yes"` file argument — `convert`'s direct parameter, files and/or folders.
    static func urls(from raw: Any?) throws -> [URL] {
        switch raw {
        case let array as [Any]:
            return try array.map(url(from:))
        case let array as NSArray:
            return try array.map { try url(from: $0) }
        case let descriptor as NSAppleEventDescriptor where descriptor.descriptorType == typeAEList:
            // A raw, undecoded `typeAEList` — every item coerced independently, since a real
            // event can mix `typeFileURL` and `typeAlias` items in the same list (`{POSIX file
            // "...", (POSIX file "..." as alias)}`). AE list indices are 1-based.
            guard descriptor.numberOfItems > 0 else { return [] }
            return try (1...descriptor.numberOfItems).map { try url(from: descriptor.atIndex($0)) }
        case .some:
            return [try url(from: raw)]
        case nil:
            return []
        }
    }
}
