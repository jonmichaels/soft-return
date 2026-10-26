import CtrlKD
import Foundation

/// The look of the table-of-contents and index pages appended to a Modern or Native-view PDF,
/// as plain values. Each platform turns it into its own font and paragraph objects; what the
/// page says and how it is styled is decided once, here.
public enum TOCPageSpec {
    public static let bodyFontName = "Georgia"
    public static let headingFontName = "Georgia-Bold"
    public static let fontSize: Double = 14
    /// Space after each paragraph, in points.
    public static let paragraphSpacing: Double = fontSize * 0.35
    /// Black, because pinned paper means pinned ink: the page is drawn on white whatever the
    /// appearance, so a system text colour would vanish in Dark Mode.
    public static let ink: (red: Double, green: Double, blue: Double) = (0, 0, 0)

    public struct Line: Equatable, Sendable {
        /// The text to draw; an empty source line is a single space, so its paragraph keeps
        /// its height.
        public let text: String
        /// "TABLE OF CONTENTS" and "INDEX" are centred in the bold face.
        public let isHeading: Bool
    }

    public static func isHeading(_ line: String) -> Bool {
        line == "TABLE OF CONTENTS" || line == "INDEX"
    }

    /// The lines to draw, or `nil` when the document has no `.tc`/`.ix` entries (or they
    /// compile to nothing). Lines are separated by a newline carrying the previous line's
    /// attributes, with none after the last. No page numbers: they would name pages against an
    /// export-time layout no engine can predict.
    public static func lines(for document: CtrlKD.Document) -> [Line]? {
        guard !document.tocEntries.isEmpty || !document.indexEntries.isEmpty else { return nil }
        let source = plainTOCIndexLines(document)
        guard !source.isEmpty else { return nil }
        return source.map { Line(text: $0.isEmpty ? " " : $0, isHeading: isHeading($0)) }
    }
}
