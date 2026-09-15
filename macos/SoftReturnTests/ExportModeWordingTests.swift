import AppIntents
import AppKit
import Foundation
import Testing
@testable import SoftReturn

/// #271 M11, batch 31 item 5 (Jon, via Athena): "Exports are Modes. Looking at something is a View." Everywhere a person
/// reads an export's Native/Printed/Modern choice, it is the Mode. A relabel only: the values, the identifiers and the
/// scripting dictionary's terms (`style`, `using style` — what existing scripts say) keep their names.
@Suite @MainActor struct ExportModeWordingTests {
    /// Export As: the pulldown's row label reads "Mode:" and VoiceOver reads the pulldown as "Mode"; no label says style.
    @Test func exportAsSheetNamesTheControlMode() throws {
        let accessory = ExportAccessoryView(formats: [.rtf], notes: NoteSelection(), style: .native)
        accessory.layoutSubtreeIfNeeded()
        let views = RenderProbeKit.descendants(accessory)
        let popup = try #require(
            views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "export-style-popup" },
            "no export-style-popup in the accessory")
        #expect(popup.accessibilityLabel() == "Mode")
        let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("Mode:"), "the accessory's labels: \(labels)")
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("style") }, "the accessory's labels: \(labels)")
    }

    /// Batch Export: VoiceOver reads the pulldown as "Mode", read off the live control. The row label "Mode:" and the
    /// caption under Font and Size are SwiftUI `Text`, which a test process cannot read back: without an assistive
    /// client AppKit builds the window no accessibility tree (b31-i5t-mac2 walked it and found no text at all, not even
    /// the pulldown's label). So the window draws both from `BatchWindowController.modeLabel` and `.fontCaption`, and
    /// those are what is held here.
    @Test func batchWindowNamesTheControlMode() throws {
        let controller = BatchWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let content = try #require(controller.window?.contentView, "batch window has no contentView")
        content.layoutSubtreeIfNeeded()
        let popup = try #require(
            RenderProbeKit.descendants(content).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == "batch-style-control" },
            "no batch-style-control in the batch window")
        #expect(popup.accessibilityLabel() == "Mode")
        #expect(BatchWindowController.modeLabel == "Mode:")
        #expect(BatchWindowController.fontCaption == "Font and size apply to Modern mode — RTF and PDF exports.")
    }

    /// Shortcuts' Convert WordStar Document: the parameter's title and its type's name both read "Mode".
    @Test func shortcutsNameTheParameterMode() {
        let intent = ConvertWordStarDocumentIntent()
        #expect(String(localized: intent.$style.title) == "Mode")
        #expect(String(localized: ConversionStyle.typeDisplayRepresentation.name) == "Mode")
    }

    /// The scripting dictionary the app ships: its terms keep "style", and no description uses the word for the mode.
    /// `export`'s and `convert`'s `using style` describe an omitted value as the mode of the view. Other meanings may
    /// still say it, and are named here: note marks drawn the way Word draws them ("word style"), a document's own
    /// paragraph styles (RTF's \stylesheet, the CLI's --no-styles), and the Finder's "NAME 2" naming ("Finder-style").
    @Test func scriptingDictionaryDescribesTheModeNotAStyle() throws {
        let name = try #require(Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String)
        let url = try #require(Bundle.main.url(forResource: name, withExtension: nil), "\(name) is not in the app bundle")
        let root = try #require(try XMLDocument(contentsOf: url, options: []).rootElement())
        func elements(_ element: XMLElement) -> [XMLElement] {
            [element] + (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap(elements)
        }
        func attribute(_ element: XMLElement, _ key: String) -> String? { element.attribute(forName: key)?.stringValue }
        let all = elements(root)
        func named(_ kind: String, _ term: String) -> [XMLElement] {
            all.filter { $0.name == kind && attribute($0, "name") == term }
        }

        #expect(named("enumeration", "style").count == 1)
        #expect(named("property", "style").count == 1)
        #expect(named("parameter", "using style").compactMap { attribute($0, "description") } == [
            "Omitted: the mode of the document's current view.",
            "Omitted: the mode of each document's current/detected view.",
        ])

        let otherMeanings = ["word style", "paragraph styles", "\\stylesheet", "--no-styles", "Finder-style"]
        var described = 0
        for element in all {
            guard let description = attribute(element, "description") else { continue }
            described += 1
            let rest = otherMeanings.reduce(description) { $0.replacingOccurrences(of: $1, with: "") }
            #expect(rest.range(of: "style", options: .caseInsensitive) == nil,
                    "\(element.name ?? "?") \"\(attribute(element, "name") ?? "")\": \(description)")
        }
        #expect(described > 100, "only \(described) descriptions read — is this the whole dictionary?")
    }
}
