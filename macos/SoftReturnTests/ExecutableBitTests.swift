import AppKit
import Testing
@testable import SoftReturn

/// The Gatekeeper problem: an extensionless file with the execute bit is refused by macOS as
/// an unverifiable program, before the app is ever asked. These tests work on copies in a
/// temporary directory — never on anyone's real documents.
@MainActor
private func scratchFile(name: String, mode: Int) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ExecBitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data("PLAIN TEXT DOCUMENT\r\nSecond line.\r\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    return url
}

private func mode(of url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as! NSNumber).uint16Value
}

/// The exact shape macOS refuses: no extension, execute bit set.
@Test @MainActor func anExtensionlessExecutableIsRepaired() throws {
    let url = try scratchFile(name: "AWAKEN", mode: 0o744)
    #expect(ExecutableBitRepair.needsRepair(at: url))
    #expect(ExecutableBitRepair.clearIfNeeded(at: url))
    #expect(try mode(of: url) & 0o111 == 0, "execute bits survived the repair")
    // Read and write are the user's business and must be left exactly as found.
    #expect(try mode(of: url) & 0o600 == 0o600, "the repair damaged read/write permissions")
}

/// A file WITH an extension is typed by that extension, whatever its mode — leave it alone.
@Test @MainActor func afileWithAnExtensionIsLeftAlone() throws {
    let url = try scratchFile(name: "ARABY.ws", mode: 0o744)
    #expect(ExecutableBitRepair.needsRepair(at: url) == false)
    #expect(ExecutableBitRepair.clearIfNeeded(at: url) == false)
    #expect(try mode(of: url) & 0o111 != 0, "an unrelated file's permissions were changed")
}

/// An extensionless file that is already fine must not be touched or counted.
@Test @MainActor func anAlreadyGoodFileIsNotCounted() throws {
    let url = try scratchFile(name: "HER", mode: 0o644)
    #expect(ExecutableBitRepair.needsRepair(at: url) == false)
    #expect(ExecutableBitRepair.clearIfNeeded(at: url) == false)
}

/// Repair Permissions… reports how many it actually fixed — the number the sheet shows.
@Test @MainActor func preparingAFolderCountsOnlyWhatItChanged() throws {
    let seed = try scratchFile(name: "seed", mode: 0o644)
    let folder = seed.deletingLastPathComponent()
    for name in ["LETTER1", "LETTER2", "LETTER3"] {
        _ = try? Data("x".utf8).write(to: folder.appendingPathComponent(name))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: folder.appendingPathComponent(name).path)
    }
    // Plus one that must NOT be counted: it has an extension.
    let skipped = folder.appendingPathComponent("NOTES.ws")
    try Data("x".utf8).write(to: skipped)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: skipped.path)

    #expect(ExecutableBitRepair.repairFolder(at: folder) == 3,
            "should repair exactly the three extensionless executables")
    #expect(try mode(of: skipped) & 0o111 != 0, "the .ws file should have been skipped")
    // Idempotent: a second run has nothing left to do.
    #expect(ExecutableBitRepair.repairFolder(at: folder) == 0)
}

/// Opening a document clears the bit as a side effect — the path a user actually takes.
@Test @MainActor func openingADocumentRepairsItOnTheWay() throws {
    let url = try scratchFile(name: "OLDLETTER", mode: 0o744)
    let document = WSDocument()
    try document.read(from: url, ofType: "public.data")
    #expect(try mode(of: url) & 0o111 == 0,
            "opening the document did not clear the execute bit, so it will still be refused next time")
}
