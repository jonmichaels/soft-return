import Foundation

/// The four public-domain WordStar sample documents bundled into `sr` (`--samples DIR`,
/// S1 — matching the flag of the same name in ctrl-kd). Bundled as SPM resources
/// (`Package.swift`'s `SoftReturnCLI` target) rather than embedded as Swift source, so the
/// bytes on disk here and the bytes `sr` writes are provably the same file, not a
/// hand-transcribed copy of it.
///
/// `Bundle.module` (and therefore `Foundation`) is confined to this one file: every other
/// file in this target, like `CtrlKD` itself, stays Foundation-free.
enum BundledSamples {
    /// Base names (the shared `.WS` extension split off because `Bundle.module.url` takes
    /// name and extension separately) — fixed order, matched everywhere this list is used.
    static let baseNames = ["LYING", "OCAPTAIN", "TWAINLET", "WARPRAYR"]

    /// `["LYING.WS", "OCAPTAIN.WS", "TWAINLET.WS", "WARPRAYR.WS"]` — the filenames
    /// `--samples DIR` actually writes.
    static let filenames = baseNames.map { "\($0).WS" }

    enum SamplesError: Error, CustomStringConvertible {
        case resourceMissing(String)
        var description: String {
            switch self {
            case .resourceMissing(let name):
                return "bundled sample resource missing from this build: \(name)"
            }
        }
    }

    /// The bytes of one bundled sample, read straight off disk from the resource bundle
    /// SPM ships beside the binary. Throws (rather than trapping) if a build ever ships
    /// without it — a packaging defect, not something a user caused, but still better
    /// reported than crashed.
    static func bytes(for baseName: String) throws -> [UInt8] {
        guard let url = Bundle.module.url(forResource: baseName, withExtension: "WS") else {
            throw SamplesError.resourceMissing("\(baseName).WS")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    /// All four, in the fixed order above, as `(filename, bytes)` pairs.
    static func all() throws -> [(name: String, bytes: [UInt8])] {
        try baseNames.map { (name: "\($0).WS", bytes: try bytes(for: $0)) }
    }
}

/// `--samples DIR`: write the four bundled sample documents into `DIR`. The one `sr`
/// action with no FILE positional and no Python analogue — see `ParsedCommand.samples`.
///
/// `DIR` must already exist and be a real, listable directory (checked with
/// `environment.listDirectory` up front) — this flag never creates a directory the way
/// `--outdir` does, so "the directory you named doesn't exist" is one plain sentence
/// instead of the same underlying write error repeated four times. A directory that exists
/// but refuses the write (permission denied, read-only filesystem, full disk) still fails
/// per file, with whatever the real filesystem says, exactly like every other CLI I/O
/// failure (`message(for:)`).
func writeSamples(to dir: String, environment: CLIEnvironment) -> Int32 {
    guard environment.listDirectory(dir) != nil else {
        environment.writeErr("sr: \(dir): no such directory")
        return ExitStatus.fileFailure
    }

    let samples: [(name: String, bytes: [UInt8])]
    do {
        samples = try BundledSamples.all()
    } catch {
        environment.writeErr("sr: \(message(for: error))")
        return ExitStatus.fileFailure
    }

    var status = ExitStatus.ok
    for sample in samples {
        let destination = joinPath(dir, sample.name)
        do {
            try environment.writeFile(destination, sample.bytes)
            environment.writeErr("sr: wrote \(destination)")
        } catch {
            environment.writeErr("sr: \(destination): \(plainWriteFailure(error))")
            status = ExitStatus.fileFailure
        }
    }
    return status
}

/// A write failure, in one plain sentence. `message(for:)` (`Run.swift`) falls through to
/// Foundation's raw `NSError` description for anything that isn't a `ParseError`/
/// `EmitError` — fine for a stray I/O failure buried in a status line, but the whole point
/// of "errors plainly if dir missing/unwritable" is that a permission-denied directory
/// reads as a sentence, not an `NSCocoaErrorDomain Code=513 ... UserInfo={...}` dump.
func plainWriteFailure(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            switch underlying.code {
            case Int(EACCES): return "permission denied"
            case Int(ENOSPC): return "no space left on device"
            case Int(EROFS): return "read-only filesystem"
            case Int(ENOENT): return "no such directory"
            default: break
            }
        }
        switch nsError.code {
        case NSFileWriteNoPermissionError: return "permission denied"
        case NSFileWriteOutOfSpaceError: return "no space left on device"
        case NSFileWriteVolumeReadOnlyError: return "read-only filesystem"
        case NSFileNoSuchFileError: return "no such directory"
        default: break
        }
    }
    return message(for: error)
}
