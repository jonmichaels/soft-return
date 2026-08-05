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
    /// The active COLOUR (symmetric type 0x01) palette index, or `nil` for colour 0
    /// (Black, the default) — same run-boundary mechanism as `font`. Python carries this
    /// as a `colourN` tag in the same `frozenset`, with colour 0 contributing NO tag at
    /// all so a fontless document, and every all-black document, stays byte-identical:
    /// this mirrors that by leaving colour 0 as `nil` rather than `.some(0)`.
    public var colour: Int?
    /// A 0x0F user print control's DISPLAY STRING, carrying the block's own declared
    /// width in HMIs (1/1800in) — 0 for LJ6DTP's rule-drawing controls, whose payload
    /// draws with no character advance at all. Non-`nil` marks this span as SCREEN-ONLY:
    /// on paper WordStar sends the raw printer payload instead and advances by this HMI
    /// figure; reading modes render the text verbatim, the only human-visible trace of
    /// what the control does. Python tags this as a synthetic `pctl<hmi>` style string;
    /// the value rides in its own field here for the same reason `font` does.
    public var pctlHMI: Int?

    public init(text: String, styles: Style = [], font: Int? = nil, colour: Int? = nil,
                pctlHMI: Int? = nil) {
        self.text = text
        self.styles = styles
        self.font = font
        self.colour = colour
        self.pctlHMI = pctlHMI
    }
}
