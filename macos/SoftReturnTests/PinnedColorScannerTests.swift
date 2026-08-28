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
/// live-fired both directions (planted violation caught, clean tree passes) and
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
