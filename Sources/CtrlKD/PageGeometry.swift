// The one home for page-geometry facts: WordStar's named dot-command defaults, the
// inch conversions, the Letter fallback, Modern's margin rule and the three named
// `--page-settings` presets. Before this file each of those was written out again at
// every site that needed it (the Modern margins three times: points, twips and the CLI
// preset). Pure arithmetic and constants -- nothing here changes any output.

// MARK: - Units

public let pointsPerInch = 72.0
public let twipsPerInch = 1440.0
/// `.mt`/`.mb`/`.hm`/`.fm`/`.pl` count lines at 6 LPI.
public let linesPerInch = 6.0
/// `.po` counts print columns at 10 CPI.
public let colsPerInch = 10.0

public let twipsPerLine = twipsPerInch / linesPerInch
public let twipsPerCol = twipsPerInch / colsPerInch

public func inchesToPoints(_ inches: Double) -> Double { inches * pointsPerInch }
public func inchesToTwips(_ inches: Double) -> Double { inches * twipsPerInch }

// MARK: - Letter, the fallback sheet

public let letterWidthIn = 8.5
public let letterHeightIn = 11.0
/// Letter's height in twips: what `.pl 0` ("page breaks off", not a sheet) falls back to.
public let letterHeightTwips = 15840

// MARK: - WordStar's own defaults

let defaultPlLines = 66.0   // WordStar's own default: 66 lines = 11in = US Letter
let defaultMtLines = 3.0    // spec: ".MT ... Default value is 3 lines."
let defaultMbLines = 8.0    // spec: ".MB ... The default value is 8 lines."
let defaultPoCols = 8.0     // WS7 manual, "Page Layout": "The default page offset
                            // is .8 inch" -- 8 print columns at the default 10 CPI.
                            // (Through ctrl-kd 1.3.0 this was 0, "least
                            // presumptuous", from the file-format spec stating
                            // none; the manual DOES state one, and 2.0.0 actually
                            // renders the offset, so the manual's figure governs.)
let defaultHmLines = 2.0    // spec: ".HM ... Default is 2." (header sits INSIDE .mt) --
                            // internal (not private): PDFLayout.swift's
                            // `printedNotesReservePt` also reads it (mechanism U port,
                            // `_printed_notes_reserve_pt`).
let defaultFmLines = 2.0    // spec: ".FM ... Default is 2." (footer sits INSIDE .mb)

// MARK: - Modern's own page

/// Modern's margins when a field is declared without a value of its own: 1in all round
/// (6 lines top/bottom at 6 LPI, 10 columns at 10 CPI).
let modernMtLines = 6.0
let modernMbLines = 6.0
let modernPoCols = 10.0

/// Modern's margins -- top, bottom, left -- in whatever unit `unitsPerInch` names
/// (`pointsPerInch` for PDF, `twipsPerInch` for RTF). Modern only trusts a field the
/// document (or a `--page-settings` override, applied as though it were the document's
/// own) actually DECLARED; an undeclared field is Modern's own fixed 1in, never the
/// WordStar factory number `doc.page` already carries. The caller rounds if its unit
/// wants integers. `unitsPerInch / 6` and `/ 10` are exact (12 and 7.2 pt, 240 and 144
/// twips), so each unit gets the very numbers its hand-written copy used to compute.
func modernMargins(_ page: PageGeometry?, unitsPerInch: Double)
    -> (top: Double, bottom: Double, left: Double) {
    let perLine = unitsPerInch / linesPerInch
    let perCol = unitsPerInch / colsPerInch
    let mtDeclared = (page?.mtSource ?? .default) != .default
    let mbDeclared = (page?.mbSource ?? .default) != .default
    let poDeclared = (page?.poSource ?? .default) != .default
    return (mtDeclared ? (page?.mtLines ?? modernMtLines) * perLine : unitsPerInch,
            mbDeclared ? (page?.mbLines ?? modernMbLines) * perLine : unitsPerInch,
            poDeclared ? (page?.poCols ?? modernPoCols) * perCol : unitsPerInch)
}

// MARK: - The named `--page-settings` presets

/// The top margin the `sawyer` preset reproduces: 1195 twips (0.83in).
let sawyerTopMarginTwips = 1195.0

extension PageSettings {
    /// WordStar's own factory geometry: nothing overridden.
    public static let factory = PageSettings()
    /// The Sawyer-archive printed geometry.
    public static let sawyer = PageSettings(
        mtLines: sawyerTopMarginTwips / twipsPerInch * linesPerInch,
        mbLines: 6.0, poCols: 7.0)
    /// Modern mode's own page, made inspectable: 1in margins.
    public static let modern = PageSettings(
        mtLines: modernMtLines, mbLines: modernMbLines, poCols: modernPoCols)
}

/// The three named `--page-settings` presets by name. Port of cli.py's `PAGE_PRESETS`.
public let pagePresets: [String: PageSettings] = [
    "default": .factory,
    "sawyer": .sawyer,
    "modern": .modern,
]
