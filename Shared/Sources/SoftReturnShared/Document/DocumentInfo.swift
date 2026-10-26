import CtrlKD
import Foundation

/// The rows Document Info shows, in their fixed order, for the Mac's panel, the Mac batch
/// window's preview and the iPhone's screen. What differs between them is passed in: the
/// "Where" text (a full path on the Mac, a display name on the iPhone) and the figures only a
/// platform renderer can count (Pages).
public enum DocumentInfo {
    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// What a row reads when there is nothing to report.
    public static let none = "—"

    public static let fileLabels = [
        "File Name", "Kind", "Size", "Where", "Created", "Modified", "Page Size", "Pages",
    ]

    /// File Name, Kind, Size, Where, Created, Modified — the Get-Info rows every file has.
    /// With no `url`, or an attribute the file does not report, the row reads "—".
    /// `location` is the "Where" text the caller wants; `nil` reads "—".
    public static func getInfoRows(url: URL?, kind: String, location: String?) -> [Row] {
        let values = try? url?.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        return [
            Row("File Name", url?.lastPathComponent ?? none),
            Row("Kind", kind),
            Row("Size", values?.fileSize.map(byteText) ?? none),
            Row("Where", location ?? none),
            Row("Created", values?.creationDate.map(dateText) ?? none),
            Row("Modified", values?.contentModificationDate.map(dateText) ?? none),
        ]
    }

    /// The eight Get-Info rows: the six above, then Page Size and Pages as the caller measured
    /// them on the sheet Printed lays out.
    public static func fileRows(url: URL?, kind: String, location: String?, pageSize: String, pages: String) -> [Row] {
        getInfoRows(url: url, kind: kind, location: location) + [Row("Page Size", pageSize), Row("Pages", pages)]
    }

    /// All eight rows reading "—": a window with no file behind it yet.
    public static func emptyFileRows() -> [Row] {
        fileLabels.map { Row($0, none) }
    }

    /// Word Count, Character Count, Fonts, Notes, Margins — read from the document as `style`
    /// shows it (the text Copy and a plain-text export give for that view).
    @MainActor
    public static func documentRows(state: DocumentState, style: RenderStyle) -> [Row] {
        let text = emitText(state.document, mode: style.emitMode)
        return [
            Row("Word Count", "\(text.split(whereSeparator: \.isWhitespace).count)"),
            Row("Character Count", "\(text.count)"),
            Row("Fonts", fontsText(state.document)),
            Row("Notes", noteCountsText(state.document)),
            // On the page Printed lays out with the Margins choice.
            Row("Margins", state.marginsDescription),
        ]
    }

    /// The document's declared font families (a typestyle name when the family is empty),
    /// deduplicated and sorted; "—" for WS4 files and print streams, which carry no font table.
    public static func fontsText(_ document: CtrlKD.Document) -> String {
        let names = Set(document.fonts.map { $0.family.isEmpty ? ($0.typestyleName ?? "Unnamed") : $0.family })
        return names.isEmpty ? none : names.sorted().joined(separator: ", ")
    }

    /// The four note kinds, zero included.
    public static func noteCountsText(_ document: CtrlKD.Document) -> String {
        func count(_ kind: NoteKind) -> Int { document.notes.filter { $0.kind == kind }.count }
        var text = "Footnotes \(count(.footnote)) · Endnotes \(count(.endnote)) · "
        text += "Annotations \(count(.annotation)) · Comments \(count(.comment))"
        return text
    }

    private static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
