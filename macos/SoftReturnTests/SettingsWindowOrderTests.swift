import AppKit
import Testing
@testable import SoftReturn

/// Job 398 (Jon's correction to job 397's F10 ruling — Default Display "needs to go back
/// in... under Default Style"), amended verbatim order:
///
///     On Launch
///     Starting View
///     Default Zoom
///     Default Style
///     Default Display
///     Default Page Size
///     Quick Look Margins
///     -- Separator
///     "Font and size apply..."
///     Font
///     Size
///     Default Export Formats
///     Export Inline Styling
///     Export Headers
///     Export TOC
///     Export Pictures
///     Page Numbering
///
/// Job 520 (N5, b33 page-numbering UI): Page Numbering joins the end of this list — a fifth
/// b24-style ruled addition (see `SettingsStore`'s own class comment), not a reordering of
/// the job 397/398 spec above it.
///
/// Walks the real window's content view in the same top-to-bottom document order
/// `SettingsWindowController.buildForm` lays it out (`content`'s subviews, in insertion order:
/// `topGrid`, the separator `NSBox`, the caption, `bottomGrid`) rather than re-deriving the
/// expected shape — a future insertion at the wrong spot fails THIS list, not a recomputation
/// of it.
@Suite("Settings pane order (job 397, amended job 398)")
@MainActor
struct SettingsWindowOrderTests {

    private func throwawaySettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "SettingsWindowOrderTests.\(UUID().uuidString)")!)
    }

    private func throwawayQuickLookDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SettingsWindowOrderTests.QL.\(UUID().uuidString)")!
    }

    /// Every label (grid rows, in row order) or non-row landmark (separator, caption), in the
    /// window's actual top-to-bottom visual order — read straight off `content.subviews`,
    /// never assumed.
    private enum Landmark: Equatable, CustomStringConvertible {
        case row(String)
        case separator
        case caption(String)

        var description: String {
            switch self {
            case .row(let label): return label
            case .separator: return "-- Separator --"
            case .caption(let text): return "caption(\"\(text)\")"
            }
        }
    }

    private func visualOrder(of content: NSView) -> [Landmark] {
        content.subviews.flatMap { subview -> [Landmark] in
            if let grid = subview as? NSGridView {
                return (0..<grid.numberOfRows).map { row in
                    let label = (grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?
                        .stringValue ?? "?"
                    return .row(label)
                }
            }
            if let box = subview as? NSBox, box.boxType == .separator {
                return [.separator]
            }
            if let field = subview as? NSTextField, field.accessibilityIdentifier() == "settings-font-caption" {
                return [.caption(field.stringValue)]
            }
            return []
        }
    }

    @Test func controlOrderMatchesJonsAmendedF10SpecLineForLine() throws {
        let controller = SettingsWindowController(
            settings: throwawaySettings(), quickLookDefaultsOverride: throwawayQuickLookDefaults())
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let expected: [Landmark] = [
            .row("On Launch:"),
            .row("Starting View:"),
            .row("Default Zoom:"),
            .row("Default Style:"),
            .row("Default Display:"),
            .row("Default Page Size:"),
            .row("Quick Look Margins:"),
            .separator,
            .caption("Font and size apply to Modern style — and to its RTF and PDF exports."),
            .row("Font:"),
            .row("Size:"),
            .row("Default Export Formats:"),
            .row("Export Inline Styling:"),
            .row("Export Headers:"),
            .row("Export TOC:"),
            .row("Export Pictures:"),
            .row("Page Numbering:"),
        ]

        #expect(visualOrder(of: content) == expected)
    }
}
