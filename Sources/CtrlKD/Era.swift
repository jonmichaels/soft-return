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
    /// UNVERIFIED: WS7's "Upgrading" and WS5's "What's New" name DIFFERENT command
    /// lists as affected. Settle by experiment before relying on it.
    public let columnUnit: ColumnUnit

    /// Page-number column (`.pc` default).
    public let pcDefault: Int
}

/// The known releases. A print stream is printer output, not a document: no dot
/// commands survive in it and none of the above applies, so it gets the most
/// conservative entry — as does plain text.
public let eras: [Variant: Era] = [
    .ws4: Era(name: "ws4", highBitWordwrap: true, symmetricBlocks: false,
              hasNotes: false, hasSB: false, columnUnit: .font, pcDefault: 28),
    .ws5plus: Era(name: "ws5+", highBitWordwrap: false, symmetricBlocks: true,
                  hasNotes: true, hasSB: true, columnUnit: .tenthInch, pcDefault: 28),
    .printstream: Era(name: "printstream", highBitWordwrap: false, symmetricBlocks: false,
                      hasNotes: false, hasSB: false, columnUnit: .tenthInch, pcDefault: 28),
    .text: Era(name: "printstream", highBitWordwrap: false, symmetricBlocks: false,
               hasNotes: false, hasSB: false, columnUnit: .tenthInch, pcDefault: 28),
    // `binary` is a DETECTED variant, not an unknown one, and it must not inherit the
    // ws5+ fallback below. Doing so switched symmetric-block parsing ON for a file
    // `detect` had already declined to identify, and `symmetricBlocks` treats every
    // `0x1D` as a block-start marker: `A <ESC> 0x1D B` parsed to `"A"`, losing both the
    // escaped byte and every byte after it. Conservative on BOTH axes — no high-bit
    // stripping AND no symmetric blocks.
    .binary: Era(name: "binary", highBitWordwrap: false, symmetricBlocks: false,
                 hasNotes: false, hasSB: false, columnUnit: .tenthInch, pcDefault: 28),
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
