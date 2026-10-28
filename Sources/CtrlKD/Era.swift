/// What one WordStar release does differently.
///
/// WordStar changed behaviour between releases, and a converter has to know WHICH
/// WordStar wrote a file. Until 2026-08-03 those decisions were scattered as inline
/// `variant == .ws4` checks, which worked for two eras and would not survive a third.
/// This table is the one place that knows. Direct port of `ERAS`/`era_for`
/// (core.py, ctrl-kd 2.0.0).
///
/// ADDING A RELEASE (e.g. WS3): add an entry here, make `detect` able to return its
/// variant, and — ideally — confirm each field by RUNNING that WordStar under
/// `tools/wordstar_harness.sh` rather than trusting a manual. Nothing else should
/// need to grow a version check; if it does, the missing fact belongs in here.
///
/// Sources: WordStar Professional 4.0 (1987) Appendix G and Appendix B; WordStar 7.0
/// Reference; "Upgrading from a Previous Release" (WS7); WordStar Professional 5.0
/// "What's New" (1988). Where the last two disagree the field is marked UNVERIFIED —
/// see `columnUnit`.
public struct Era: Sendable, Equatable {
    /// What a "column" means in `.rm`/`.lm`/`.pm`/`.po`/`.pc`.
    public enum ColumnUnit: String, Sendable {
        /// Pre-WS5: one character of the CURRENT FONT.
        case font
        /// WS5+: a fixed 0.1 inch.
        case tenthInch = "tenth-inch"
    }

    public let name: String

    /// WS4 and earlier set bit 7 on the LAST character of each word (microjustify
    /// flags). WS5+ dropped it, and a high byte there is an extended cp437 character
    /// instead — so this decides whether stripping the high bit recovers text or
    /// destroys it.
    public let highBitWordwrap: Bool

    /// `0x1D`-delimited symmetrical sequences: notes, fonts, colour, styles.
    public let symmetricBlocks: Bool

    /// `^ONF`/`^ONE`/`^ONA`/`^ONC`. Blank in the 4.0/3.3 keystroke tables; appears at
    /// 5.5/6.0. A WS4 file cannot contain a note.
    public let hasNotes: Bool

    /// `.sb on|off` — suppress blank lines at the top of a page. Absent from WS4's and
    /// WS3.3's command lists entirely (exhaustive Appendix G extraction, `.AV` through
    /// `.XW`), so a pre-WS5 file cannot mean it.
    public let hasSB: Bool

    /// Equal at the default `.cw 12` (10 cpi), so this only bites a document that
    /// changes `.cw` AND uses a margin dot command.
    ///
    /// The WS7 half is read from WS7's code (ruler unit 180 HMI = 1/10 inch; WS7 teardown,
    /// `wordstar-dos/7-configuration.md` 7.1); the WS4 half has not been run.
    public let columnUnit: ColumnUnit

    /// The column the automatic page number starts in when `.pc` is unset or 0 (1-based,
    /// counted from `.po`; may be fractional: WS7 centres a one-digit number on 33.5, WS7
    /// teardown `wordstar-dos/11-print-engine.md` 11.5). WS4's factory `.PC` is 28 (WS4
    /// teardown `wordstar4-dos/4-formatting-printing.md` 3.2, 4 §13; runs x41-*).
    public let pcDefault: Double

    /// A bare `.po` (no argument) sets the page offset to 0. WS7 Rev. D does that (runs
    /// arg-*: x = 0), though a bare `.pl/.mt/.mb/.lh` keeps its previous value (WS7
    /// teardown, `wordstar-dos/7-configuration.md` 7.9). So does WS4. Port of
    /// `core.Era.bare_po_zero`.
    public var barePoZero: Bool = false

    /// A bad `.po` argument (`.PO x`) is 0 too: WS4's reader collects no digits and an empty
    /// number is 0 (WS4 teardown 4 §2.3, 3.12; runs po-args). WS7's answer for one has not
    /// been run. Port of `core.Era.bad_po_zero`.
    public var badPoZero: Bool = false

    /// The LaserJet driver this WordStar prints with. WS4's is HPLJET, a code module in
    /// WSPRINT.OVR (WS4 teardown, `wordstar4-dos/4-formatting-printing.md` 15): line 1's
    /// baseline 1/3" below the top margin whatever `.lh`, each line a step of the `.lh` in
    /// force on the line above, every word placed from WS4's own width tables, and its own
    /// microjustification (`HPLJET.swift`). WS7's is LASERJET.PDF (`wordstar-dos/
    /// 9-printer-drivers.md`, `11-print-engine.md`). Port of `core.Era.hpljet_driver`.
    public var hpljetDriver: Bool = false

    /// WS4's page counter (WS4 teardown `wordstar4-dos/4-formatting-printing.md` 3.1): R
    /// starts a page at H - 1 and each line costs LH, so a line STARTS while the height
    /// used is under the body height H and the page holds `floor((H - 1) / LH) + 1` lines
    /// (37 at `.lh 12`); `.cp n` breaks when `floor(R / LH) + 1 < n`. WS7 instead keeps a
    /// line only when it fits whole (`wordstar-dos/11-print-engine.md` 11.3), and `.cp n`
    /// there is `room / LH < n`. Port of `core.Era.line_starts_in_room`.
    public var lineStartsInRoom: Bool = false

    /// WS4 re-derives R at once when `.pl/.mt/.mb` change (`R := R - Hold + Hnew`, routine
    /// 1EE1B), so the page in progress takes the new body height, tighter or looser
    /// (`evidence/pass3/exe-static.md` 8, runs t43-mtmb). WS7 measurements say a
    /// mid-document margin change may loosen a page but never tighten it. Port of
    /// `core.Era.geometry_acts_at_once`.
    public var geometryActsAtOnce: Bool = false

    /// `^PK` in a header/footer on an EVEN page: WS7 keeps one blank of the run that
    /// follows (measured, `sawyer/REF/CTRL-K.H1`); WS4 drops the `^PK` together with every
    /// blank and tab after it (`exe-static.md` 9, 16FD3-16FEB; run p12-hepk). Port of
    /// `core.Era.pk_even_keeps_blank`.
    public var pkEvenKeepsBlank: Bool = true

    /// WS7's paginator (WS7 report 14.3, 14.5, 15.1, 15.10), as five behaviours that WS4
    /// has not been shown to share (the next five properties read it). Port of
    /// `core.Era(ws7_paging=)`.
    public var ws7Paging: Bool = false

    /// A blank line after a full page or a trailing `.pa` is a text line and makes a page
    /// that prints its number.
    public var blankLinesMakePages: Bool { ws7Paging }
    /// A `.pa` on a page that holds nothing yet is ignored.
    public var paIgnoredOnEmptyPage: Bool { ws7Paging }
    /// An empty soft-return line at the top of a page the paginator ended for room is
    /// swallowed, with or without `.sb`.
    public var softBlanksSwallowed: Bool { ws7Paging }
    /// Under `.lh a` a line may overhang the bottom by its font's rise over the base line
    /// when that rise fits the room left.
    public var overhangsByFontRise: Bool { ws7Paging }
    /// The page number's baseline is a page line below the foot row whatever `.cw` is.
    public var pagenoRowBelowPageLine: Bool { ws7Paging }
    /// The first over-budget blank of a double-spaced WS4 file's spacing never forces a page
    /// break (measured on WS7 printing WS4 sources, `ws4SpacingBlankIndices`). WS4 itself has
    /// no such forgiveness: every line, a blank one too, costs LH and may open a page (WS4
    /// teardown `4-formatting-printing.md` 3.1). Port of `core.Era.forgives_spacing_blank`.
    public var forgivesSpacingBlank: Bool { ws7Paging }
}

/// The known releases. A print stream is printer output, not a document: no dot
/// commands survive in it and none of the above applies, so it gets the most
/// conservative entry — as does plain text.
public let eras: [Variant: Era] = [
    .ws4: Era(name: "ws4", highBitWordwrap: true, symmetricBlocks: false,
              hasNotes: false, hasSB: false, columnUnit: .font, pcDefault: 28,
              barePoZero: true, badPoZero: true, hpljetDriver: true,
              lineStartsInRoom: true, geometryActsAtOnce: true, pkEvenKeepsBlank: false),
    .ws5plus: Era(name: "ws5+", highBitWordwrap: false, symmetricBlocks: true,
                  hasNotes: true, hasSB: true, columnUnit: .tenthInch, pcDefault: 33.5,
                  barePoZero: true, ws7Paging: true),
    .printstream: Era(name: "printstream", highBitWordwrap: false, symmetricBlocks: false,
                      hasNotes: false, hasSB: false, columnUnit: .tenthInch, pcDefault: 33.5),
    .text: Era(name: "printstream", highBitWordwrap: false, symmetricBlocks: false,
               hasNotes: false, hasSB: false, columnUnit: .tenthInch, pcDefault: 33.5),
    // `binary` is a DETECTED variant, not an unknown one, and it must not inherit the
    // ws5+ fallback below. Doing so switched symmetric-block parsing ON for a file
    // `detect` had already declined to identify, and `symmetricBlocks` treats every
    // `0x1D` as a block-start marker: `A <ESC> 0x1D B` parsed to `"A"`, losing both the
    // escaped byte and every byte after it. Conservative on BOTH axes — no high-bit
    // stripping AND no symmetric blocks.
    .binary: Era(name: "binary", highBitWordwrap: false, symmetricBlocks: false,
                 hasNotes: false, hasSB: false, columnUnit: .tenthInch, pcDefault: 33.5),
]

/// WS3's entry, kept out of `eras` until `detect` can actually return a `ws3` variant —
/// the Python table carries it already, and the values are recorded here so adding the
/// variant is a one-line change rather than a re-derivation. `.pc` moved 33 -> 28 at
/// release 4.
public let ws3Era = Era(name: "ws3", highBitWordwrap: true, symmetricBlocks: false,
                        hasNotes: false, hasSB: false, columnUnit: .font, pcDefault: 33)

/// The `Era` for a detected variant. Every variant `detect` can actually return has its
/// own entry above; a name from nowhere gets the WS5+ entry, which does NOT strip high
/// bits, so it loses no extended characters. Guessing wrong in that direction destroys
/// text.
///
/// That fallback is a guess about ENCODING only. It is emphatically not a licence to
/// enable behaviour that can itself destroy text — which is exactly what happened when
/// `.binary` was left to inherit it and picked up symmetric-block parsing along the way.
/// A new variant belongs in the table, conservative on every axis, rather than relying
/// on this.
public func eraFor(_ variant: Variant) -> Era {
    eras[variant] ?? eras[.ws5plus]!
}

/// Which WordStar prints a WS4 file. Printing behaviour belongs to the program doing the
/// printing, not to the file: WS7 opens a WS4 file and prints it by its own rules (PCL
/// captures of WS7 printing WS4 files centre the page number), while WS4 prints it by WS4's
/// (page number at `.PC` 28, WS4's page counter; WS4 teardown 3.1, 3.2). `.own` is the file's
/// own release, the default; `.ws7` prints a WS4 file as WS7 does. A WS5+ file is always
/// printed by WS7, its own release, since WS4 cannot open one. Port of `core.PRINTED_BY`.
public enum PrintedBy: String, Sendable, CaseIterable, Codable {
    case own
    case ws7
}

/// The Era whose PRINTING rules apply to `doc`: the page counter, margins acting at once,
/// the automatic page number's column, `^PK`, a bare `.po`. What the bytes mean (bit 7,
/// records) is `eraFor(variant)`'s, always. Port of `core.printing_era`.
public func printingEra(_ doc: Document) -> Era {
    eraFor(doc.printingVariant ?? doc.detection?.variant ?? .ws5plus)
}
