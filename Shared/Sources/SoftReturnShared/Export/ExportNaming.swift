import Foundation

/// Where an export's bytes land, and under what name. Two behaviours, each named:
/// `write(_:to:basename:)` never overwrites (Finder-style numbering), and
/// `writeReplacing(_:in:basename:)` deliberately overwrites a fixed name in a folder that was
/// made for the one export (the iPhone's share-sheet staging folder).
public enum ExportNaming {
    /// Finder's collision rule: "PAPER.md", then "PAPER 2.md", "PAPER 3.md" — a space and a
    /// number, never an overwrite. `exists` answers whether a candidate name is taken, so the
    /// rule is testable without a disk.
    public static func uniqueName(basename: String, extension ext: String,
                                  exists: (String) -> Bool) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let first = basename + suffix
        guard exists(first) else { return first }
        // Finder starts at 2 — the original is "1" by implication.
        var counter = 2
        while true {
            let candidate = "\(basename) \(counter)\(suffix)"
            if !exists(candidate) { return candidate }
            counter += 1
            // A directory holding this many collisions is pathological; give up rather than
            // spin, and let the write fail with a real error the person can see.
            if counter > 10_000 { return candidate }
        }
    }

    /// The rule against a real folder.
    public static func uniqueName(basename: String, extension ext: String, in directory: URL,
                                  fileManager: FileManager = .default) -> String {
        uniqueName(basename: basename, extension: ext) { candidate in
            fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
    }

    /// The rule for a whole destination URL: "Dir/PAPER.md" becomes "Dir/PAPER 2.md" when taken.
    public static func uniqueURL(for destination: URL, exists: (URL) -> Bool) -> URL {
        let directory = destination.deletingLastPathComponent()
        let name = uniqueName(
            basename: destination.deletingPathExtension().lastPathComponent,
            extension: destination.pathExtension
        ) { exists(directory.appendingPathComponent($0)) }
        return directory.appendingPathComponent(name)
    }

    /// Writes each product beside the others in `directory` under `basename`, uniquified, never
    /// overwriting. Returns the URLs actually written.
    @discardableResult
    public static func write(_ products: [ExportProduct], to directory: URL, basename: String,
                             fileManager: FileManager = .default) throws -> [URL] {
        try products.map { product in
            let name = uniqueName(
                basename: basename, extension: product.format.fileExtension,
                in: directory, fileManager: fileManager)
            let url = directory.appendingPathComponent(name)
            try Data(product.bytes).write(to: url, options: .atomic)
            return url
        }
    }

    /// Writes each product as `<basename>.<ext>` in `folder`, replacing a file already there.
    /// For a folder created for this one export; use `write(_:to:basename:)` anywhere a
    /// person's files may already be.
    @discardableResult
    public static func writeReplacing(_ products: [ExportProduct], in folder: URL,
                                      basename: String) throws -> [URL] {
        try products.map { product in
            let url = folder.appendingPathComponent("\(basename).\(product.format.fileExtension)")
            try Data(product.bytes).write(to: url, options: .atomic)
            return url
        }
    }
}
