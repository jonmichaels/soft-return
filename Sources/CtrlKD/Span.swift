/// A run of text sharing one set of styles. The IR's smallest unit.
public struct Span: Hashable, Sendable {
    public var text: String
    public var styles: Style
    /// The active FONT RUN's index into `Document.fonts`, or `nil` outside any run.
    ///
    /// Python carries this as a `fontN` string inside the same `frozenset` as the style
    /// codes, which a set of strings makes free. `Style` here is an `OptionSet` over a
    /// small FIXED vocabulary — deliberately, see `Style.swift` — and a font index is
    /// neither small nor fixed (a document may declare hundreds), so it rides in its own
    /// field. Everywhere Python tests `st.startswith('font')`, this is `font != nil`.
    public var font: Int?

    public init(text: String, styles: Style = [], font: Int? = nil) {
        self.text = text
        self.styles = styles
        self.font = font
    }
}
