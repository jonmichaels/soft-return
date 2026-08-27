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
    /// b24 round 19 (RULINGS-LEDGER PIX row): the index into `Document.graphics` this
    /// span's placeholder text ("[image: NAME]") refers to, or `nil` outside one — same
    /// run-boundary mechanism as `font`/`colour`. Python carries this as a `pix<N>` tag
    /// in the same `frozenset` as the style codes; the value rides in its own field
    /// here for the same reason `font`/`pctlHMI` do.
    public var pix: Int?
    /// Register C2 (LJ6DTP parity): the index into `Document.pclPrograms` of the RAW
    /// PCL this 0x0F print control sends to the printer, or `nil` — always paired with
    /// `pctlHMI` (the same control's screen-only display string). A printed renderer
    /// EXECUTES that PCL (LJ6DTP's page border and page 4's checkerboard are drawn
    /// entirely this way); every other consumer ignores it. Python carries this as a
    /// `pcl<N>` tag in the same `frozenset`; the value rides in its own field here for
    /// the same reason `pctlHMI`/`pix` do.
    public var pcl: Int?
    /// This span IS a type-9 TAB's own padding run, and this is the tab block's ABSOLUTE
    /// target in HMIs (1/1800in) from the LEFT MARGIN — `content[2:4]`, never read
    /// anywhere before the tab-positioning fix. `nil` for every other span, typed spaces
    /// included: a `.lm`/`.pm`/typed indent carries no type-9 block and so has no real
    /// target to offer. See `StructuralMark.tab` for the measurement behind
    /// "absolute, not relative". Python tags this `tabhmi<N>` in the same frozenset as
    /// the style codes; the value rides in its own field here for the same reason
    /// `pctlHMI`/`pix` do.
    public var tabHMI: Int?
    /// The tab's own leader BYTE (0x20 for the plain/space-padded types; any other
    /// printable byte is a dot-leader character, spec: "Other character such as '.' or
    /// '*' are used for dot leaders"). Rides along with `tabHMI` so a renderer can tell a
    /// dot-leader tab (real ink WS7 prints) from a plain one (WS7 advances the pen with
    /// NO printed padding at all) without re-deriving it from the already-expanded text.
    /// Python's `tableader<N>` tag.
    public var tabLeader: Int?

    public init(text: String, styles: Style = [], font: Int? = nil, colour: Int? = nil,
                pctlHMI: Int? = nil, pix: Int? = nil, pcl: Int? = nil,
                tabHMI: Int? = nil, tabLeader: Int? = nil) {
        self.text = text
        self.styles = styles
        self.font = font
        self.colour = colour
        self.pctlHMI = pctlHMI
        self.pix = pix
        self.pcl = pcl
        self.tabHMI = tabHMI
        self.tabLeader = tabLeader
    }
}
