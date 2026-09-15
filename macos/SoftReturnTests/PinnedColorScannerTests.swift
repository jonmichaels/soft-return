import Foundation
import Testing

/// Wires `macos/scripts/check-pinned-colors.sh` into the suite so it runs on every test pass
/// instead of only when someone remembers to invoke it by hand — the exact failure mode that
/// let b28 ship with invisible Modern footnotes and endnotes (Jon, 2026-08-24: "Text colors
/// must be pinned if the background color is pinned"). The script itself explains why this has
/// to be a SOURCE scan and not a rendering comparison: the headless Mac composites in Light
/// Mode, so no image test on this host can ever see a colour that only misbehaves in Dark Mode.
///
/// This test does not reimplement the check. It shells out to the same script that was already
/// live-fired both directions on the build host (planted violation caught, clean tree passes) and
/// fails loudly — never skips — if that script reports a violation or cannot be run at all.
@Suite struct PinnedColorScannerTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoftReturnTests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root (job 531: macos/ restructure)
    }

    @Test func noThemeDependentColourIsDrawnOnPinnedPaper() throws {
        let script = Self.repoRoot.appendingPathComponent("macos/scripts/check-pinned-colors.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path),
                "\(script.path) is missing or not executable -- the pinned-ink guard cannot run")

        let process = Process()
        process.executableURL = script
        process.currentDirectoryURL = Self.repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus == 0, """
            check-pinned-colors.sh reported a theme-dependent colour drawn on pinned paper \
            (file:line is in its own output below) -- this is the b28 invisible-notes bug class:
            \(output)
            """)
    }
}

/// #271 M5: the Mac app's chrome — every label, menu, header and control — takes the system font
/// (`NSFont.systemFont`, `.boldSystemFont`, `.monospacedSystemFont`, `.menuFont`,
/// `.preferredFont(forTextStyle:)`, …), never a family named by hand. A named font belongs only to a
/// DOCUMENT: the faces WordStar named (or their substitutes) and Modern's reader face, which live in
/// `Rendering/` and the export engine. This scans the app's own sources — every Mac target and the
/// shared package — for a font built from a name anywhere else, and fails with file:line.
@Suite struct ChromeFontScannerTests {
    /// Where building a font from a name is the point: the document's own faces.
    static let documentFaceSources = [
        "macos/SoftReturn/Rendering/",
        "macos/SoftReturn/Export/ExportEngine.swift",
    ]
    static let scannedRoots = [
        "macos/SoftReturn", "macos/SoftReturnQuickLook", "macos/SoftReturnThumbnail",
        "macos/SoftReturnImporter", "Shared/Sources",
    ]
    static let namedFontCalls = [
        "NSFont(name:", "NSFontDescriptor(name:", "CTFontCreateWithName", "fontWithName",
        ".withFamily(", "UIFont(name:",
    ]

    @Test func chromeUsesTheSystemFontNeverANamedFamily() throws {
        let root = PinnedColorScannerTests.repoRoot
        var scanned = 0
        var offenders: [String] = []
        for directory in Self.scannedRoots {
            let base = root.appendingPathComponent(directory, isDirectory: true)
            let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil),
                                     "\(directory) could not be listed — the guard cannot run")
            for case let url as URL in files where url.pathExtension == "swift" {
                scanned += 1
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                guard !Self.documentFaceSources.contains(where: { relative.hasPrefix($0) }) else { continue }
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), Self.namedFontCalls.contains(where: { code.contains($0) }) else { continue }
                    offenders.append("\(relative):\(index + 1): \(code)")
                }
            }
        }
        #expect(scanned > 50, "only \(scanned) Swift files scanned — the guard lost its roots")
        #expect(offenders.isEmpty, """
            chrome builds a font from a family name; use the system font (NSFont.systemFont, \
            .preferredFont(forTextStyle:), …) — a named family is for a document's own faces only (#271 M5):
            \(offenders.joined(separator: "\n"))
            """)
    }
}
