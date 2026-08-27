import Foundation

/// Quietly makes 1980s files openable again.
///
/// A file with **no extension** and the **execute bit set** resolves to
/// `public.unix-executable`. macOS then hands it to Gatekeeper as a program, Gatekeeper
/// cannot verify it, and the user is told the file may contain malware and offered the
/// Trash. The document is fine — the library parses it happily. The app is never consulted.
///
/// This is not a rare shape. Files off 1980s floppies arrive this way constantly: Dropbox,
/// old archive tools, restored backups and anything that ever round-tripped through a
/// filesystem without permission semantics all set the bit. Every one of those files hits
/// the wall, and the user blames Soft Return, because Soft Return is what they were trying
/// to use.
///
/// Jon's ruling: fix it as simply as possible, and do not make him learn anything. No
/// Terminal, no `chmod` in an alert, no explaining Gatekeeper to somebody who wants to read
/// a letter from 1987. So: clear the bit, say nothing, move on.
enum ExecutableBitRepair {
    /// Is this the shape that Gatekeeper will refuse?
    ///
    /// Both conditions matter. An extensionless file WITHOUT the bit opens fine, and a file
    /// with an extension is typed by that extension no matter what its mode says.
    static func needsRepair(at url: URL) -> Bool {
        guard url.pathExtension.isEmpty else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { return false }
        // Any of owner/group/other execute is enough to type it as an executable.
        return permissions.uint16Value & 0o111 != 0
    }

    /// Clear the execute bits, leaving read/write exactly as they were.
    ///
    /// Returns whether anything was changed, so a caller can count. Failure is deliberately
    /// silent: this is a courtesy on the way to opening a document, and a file we cannot
    /// chmod is one we can very likely still read. Refusing to open it because we could not
    /// tidy its permissions would be worse than the problem.
    @discardableResult
    static func clearIfNeeded(at url: URL) -> Bool {
        guard needsRepair(at: url) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        let cleared = permissions.uint16Value & ~UInt16(0o111)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: cleared)], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Repair every extensionless file in a folder, one level deep.
    ///
    /// One level because the use case is a floppy dump or a folder someone was handed, not a
    /// recursive sweep of a home directory — and because a surprise recursive chmod is
    /// exactly the kind of thing an app should not do on the user's behalf.
    ///
    /// Returns the number of files actually changed.
    static func repairFolder(at folder: URL) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return 0 }
        return entries.reduce(into: 0) { count, url in
            if clearIfNeeded(at: url) { count += 1 }
        }
    }
}
