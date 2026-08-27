import AppKit
import CtrlKD

/// Builds the Document Info Inspector's label:value rows and section headers — the single
/// place all three of its sections (file info, the Document summary, and Diagnose)
/// construct their views, so the row shape, header weight, and wrapping width can only be
/// defined once.
///
/// Job 324 (b20): replaces the old Diagnose `NSTextView` inside an `NSScrollView`. That bare
/// `NSTextView()` never had `isVerticallyResizable`, an `autoresizingMask`, or a sized
/// `textContainer` set, so it kept its default zero frame — invisible on screen no matter
/// what `.string` held (a known trap for this project: field-notes.md, "NSScrollView
/// documentView sized by FRAME, not intrinsicContentSize"). `DocumentInfoInspectorJob314Tests`
/// only ever asserted `.string`, never the screen, so nothing caught it — the same "model vs.
/// screen" gap field-notes.md calls out for accessibility-based tests. `diagnose` itself is
/// synchronous and operates purely on in-memory bytes (no file I/O, no security-scoped-URL
/// path), and is documented to never throw, so the async/sandbox/swallowed-error candidates
/// this job was briefed to check are ruled out by reading, not guessed away. Rows here are
/// plain `NSStackView`s; an `NSStackView` sizes itself from its arranged subviews' fitting
/// size, the same mechanism the file-info section already used correctly — there is no
/// separate view left to forget to size.
@MainActor
enum InspectorRows {
    static let contentWidth: CGFloat = 420

    static func row(label: String, value: String, labelWidth: CGFloat) -> NSView {
        let labelField = NSTextField(labelWithString: label + ":")
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        let valueField = NSTextField(wrappingLabelWithString: value.isEmpty ? "—" : value)
        valueField.preferredMaxLayoutWidth = contentWidth - 32 - labelWidth - 8
        valueField.setAccessibilityIdentifier("document-info-value-\(label)")

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    static func sectionHeading(_ title: String) -> NSView {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private static func subHeader(_ title: String) -> NSView {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// The Diagnose section's content: the `--diagnose` report (`InfoValue`) as rows and
    /// small sub-headers instead of one indented text blob (Jon's ruling: no scroll box
    /// anywhere in the Inspector). Field order matches `InfoValueListRenderer`'s (sorted
    /// keys at every level) so nothing here is a fresh reading of what the report says —
    /// only of how each field gets its own view.
    ///
    /// Never returns empty: `DocumentOperations.diagnose` always sets `variant`, so `value`
    /// is never an empty object in practice — the empty-object branch below is unreachable
    /// today and stays anyway as the explicit "say something, never a blank box" floor the
    /// field bug showed this section needs (the never-empty rule a test in
    /// `DocumentInfoInspectorJob314Tests` asserts directly).
    static func rows(for value: InfoValue, labelWidth: CGFloat) -> [NSView] {
        guard case .object(let fields) = value, !fields.isEmpty else {
            return [row(label: "Diagnose", value: "No diagnostics available for this file.", labelWidth: labelWidth)]
        }
        return fields.keys.sorted().flatMap { fieldViews(key: $0, value: fields[$0]!, labelWidth: labelWidth) }
    }

    private static func fieldViews(key: String, value: InfoValue, labelWidth: CGFloat) -> [NSView] {
        switch value {
        case .object(let fields):
            guard !fields.isEmpty else { return [row(label: key, value: "—", labelWidth: labelWidth)] }
            return [subHeader(key)] + fields.keys.sorted().flatMap {
                fieldViews(key: $0, value: fields[$0]!, labelWidth: labelWidth)
            }

        case .array(let items):
            guard !items.isEmpty else { return [row(label: key, value: "—", labelWidth: labelWidth)] }
            if items.allSatisfy(InfoValueListRenderer.isScalar) {
                let joined = items.map(InfoValueListRenderer.scalar).joined(separator: ", ")
                return [row(label: key, value: joined, labelWidth: labelWidth)]
            }
            var views: [NSView] = [subHeader(key)]
            for item in items {
                guard case .object(let fields) = item else {
                    views.append(row(label: key, value: InfoValueListRenderer.scalar(item), labelWidth: labelWidth))
                    continue
                }
                views += fields.keys.sorted().flatMap { fieldViews(key: $0, value: fields[$0]!, labelWidth: labelWidth) }
            }
            return views

        default:
            return [row(label: key, value: InfoValueListRenderer.scalar(value), labelWidth: labelWidth)]
        }
    }
}
