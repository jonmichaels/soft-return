import Foundation
import Testing
import TestSupport
@testable import SoftReturnShared

/// Finder-style collision naming, and the two ways an export is written.
@Suite struct ExportNamingTests {
    @Test func firstFreeNameIsTheBasenameItself() {
        #expect(ExportNaming.uniqueName(basename: "PAPER", extension: "md") { _ in false } == "PAPER.md")
    }

    @Test func collisionsCountUpFromTwoWithASpace() {
        var taken: Set<String> = ["PAPER.md"]
        #expect(ExportNaming.uniqueName(basename: "PAPER", extension: "md") { taken.contains($0) } == "PAPER 2.md")
        taken.insert("PAPER 2.md")
        #expect(ExportNaming.uniqueName(basename: "PAPER", extension: "md") { taken.contains($0) } == "PAPER 3.md")
    }

    @Test func noExtensionGetsNoDot() {
        let taken: Set<String> = ["PAPER"]
        #expect(ExportNaming.uniqueName(basename: "PAPER", extension: "") { taken.contains($0) } == "PAPER 2")
    }

    @Test func aWholeDestinationKeepsItsFolderAndExtension() {
        let destination = URL(fileURLWithPath: "/Out/PAPER.rtf")
        let taken: Set<String> = ["/Out/PAPER.rtf", "/Out/PAPER 2.rtf"]
        #expect(ExportNaming.uniqueURL(for: destination) { taken.contains($0.path) }.path == "/Out/PAPER 3.rtf")
        #expect(ExportNaming.uniqueURL(for: destination) { _ in false } == destination)
    }

    @Test func writeNeverOverwritesAFileAlreadyThere() throws {
        let scratch = try TestScratch(prefix: "ExportNamingTests")
        defer { scratch.remove() }
        let existing = scratch.url.appendingPathComponent("PAPER.md")
        try Data("mine".utf8).write(to: existing)
        let product = ExportProduct(format: .markdown, bytes: Array("new".utf8))

        let written = try ExportNaming.write([product], to: scratch.url, basename: "PAPER")
        #expect(written.map(\.lastPathComponent) == ["PAPER 2.md"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "mine")
        #expect(try String(contentsOf: written[0], encoding: .utf8) == "new")
    }

    @Test func writeReplacingOverwritesTheFixedName() throws {
        let scratch = try TestScratch(prefix: "ExportNamingTests")
        defer { scratch.remove() }
        let existing = scratch.url.appendingPathComponent("PAPER.pdf")
        try Data("old".utf8).write(to: existing)
        let product = ExportProduct(format: .pdf, bytes: Array("new".utf8))

        let written = try ExportNaming.writeReplacing([product], in: scratch.url, basename: "PAPER")
        #expect(written == [existing])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "new")
    }

    @Test func eachFormatGetsItsOwnExtension() throws {
        let scratch = try TestScratch(prefix: "ExportNamingTests")
        defer { scratch.remove() }
        let products = ExportFormat.allCases.map { ExportProduct(format: $0, bytes: [0x41]) }
        let written = try ExportNaming.write(products, to: scratch.url, basename: "PAPER")
        #expect(written.map(\.lastPathComponent) == ["PAPER.txt", "PAPER.md", "PAPER.html", "PAPER.rtf", "PAPER.pdf"])
    }
}
