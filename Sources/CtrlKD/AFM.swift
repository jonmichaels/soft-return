/// Glyph widths for the PDF base-14, as data. GENERATED FILE — see `Scripts/generate-afm.py`.
///
/// Transcribed by that script from ctrl-kd's `src/ctrlkd/afm.py` (the reference
/// implementation, added there in 6b9200d) rather than by hand: 13 tables of 256 integers is
/// a transcription-error machine, and one wrong width does not crash — it moves one span a
/// fraction of a point and shows up only as drift nobody can explain. Edit the generator, or
/// edit ctrl-kd and re-run it; never edit the numbers here.
///
/// WHY THIS EXISTS
/// ---------------
/// Printed mode positions every span at WordStar's own x (`PDFWriter.swift`'s HMI
/// arithmetic: each font block declares a per-character advance in 1/1800in, and that number
/// IS the grid the document was laid out on). Courier lands on that grid by construction. A
/// PROPORTIONAL face does not: Times at 12pt sets "Chapter One" in whatever width Times
/// happens to want, which is not the width WordStar reserved, so the following span would
/// start in the wrong place — or, on a 72pt banner, run clean off the paper.
///
/// The fix needs one number this emitter never had: how wide a string actually is in the
/// face it is set in. That is what these tables are.
///
/// SOURCE
/// ------
/// Adobe's Core 14 AFM metrics — the font metrics Adobe publishes for the 14 fonts every PDF
/// viewer must provide, freely redistributable and the reason this project can typeset in
/// them without embedding anything. Widths are INTEGER units of 1/1000 em, exactly as the AFM
/// files state them; nothing here is measured, estimated or scaled. They are numbers,
/// transcribed as data.
///
/// (Transcribed via the URW base-35 AFMs, which are metric-compatible clones of the same
/// faces by construction — Helvetica A=667 space=278, Times A=722 space=250, Courier 600
/// throughout, matching Adobe's published tables.)
///
/// ENCODING
/// --------
/// One 256-entry table per face, indexed by BYTE VALUE, because that is what the writer
/// writes: it encodes text as Latin-1 (`esc`). For the text faces the table is built over
/// Latin-1 glyph names, which over 0xA0-0xFF are exactly WinAnsiEncoding's. For Symbol and
/// ZapfDingbats it is built over the font's OWN encoding — the codes the emitter deliberately
/// writes back via `untransliterate`, so a Symbol 'a' really is alpha and really is measured
/// as alpha: 631/1000, not the 556 Helvetica would have given it. (ctrl-kd's own docstring
/// says 439 there; its DATA says 631, which is what Adobe's Symbol AFM says, so the number
/// above is read off the table rather than copied from the prose.)
///
/// Two faces share a table rather than repeating it: Helvetica-Oblique is metrically
/// identical to Helvetica and Helvetica-BoldOblique to Helvetica-Bold — slanting a face does
/// not change its advance widths, and the AFM files agree byte for byte. The generator
/// deduplicates by VALUE, so that sharing is a measured fact about the tables, not an
/// assumption written into the script.
///
/// Since 2026-08-05 the text font objects declare `/Encoding /WinAnsiEncoding` (which IS
/// cp1252) and the writer's `esc` encodes cp1252 instead of Latin-1, so bytes, glyphs and
/// these widths agree over the WHOLE range — including the 0x80-0x9F typographic row
/// (curly quotes, en/em dashes, ellipsis, bullet, dagger, trademark, ligatures), which
/// Latin-1 has no glyphs for at all. The generator overlays real Adobe AFM widths for that
/// row onto the Latin-1-named base tables below, exactly as ctrl-kd's own `afm.py` does.
///
/// A code with no glyph in a face gets 0. Callers must treat a zero-width string as "no metric
/// available" rather than dividing by it (`tzScale` does).

/// Courier is monospaced at 600/1000 em in all four weights — the AFM files say 600 for every
/// glyph, including the ones the other faces do not have, so a table would be 256 copies of
/// one number. This is that number.
let afmCourierWidth = 600


private let afmCourier: [Int] = [Int](repeating: afmCourierWidth, count: 256)

private let afmHelvetica: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     278,  278,  355,  556,  556,  889,  667,  191,  333,  333,  389,  584,  278,  333,  278,  278,
     556,  556,  556,  556,  556,  556,  556,  556,  556,  556,  278,  278,  584,  584,  584,  556,
    1015,  667,  667,  722,  722,  667,  611,  778,  722,  278,  500,  667,  556,  833,  722,  778,
     667,  778,  722,  667,  611,  722,  667,  944,  667,  667,  611,  278,  278,  278,  469,  556,
     333,  556,  556,  500,  556,  556,  278,  556,  556,  222,  222,  500,  222,  833,  556,  556,
     556,  556,  333,  500,  278,  556,  500,  722,  500,  500,  500,  334,  260,  334,  584,    0,
       0,    0,  222,  556,  333, 1000,  556,  556,  333, 1000,  667,  333, 1000,    0,  611,    0,
       0,  222,  222,  333,  333,  350,  556, 1000,  333, 1000,  500,  333,  944,    0,  500,  667,
     278,  333,  556,  556,  556,  556,  260,  556,  333,  737,  370,  556,  584,  333,  737,  333,
     400,  584,  333,  333,  333,  556,  537,  278,  333,  333,  365,  556,  834,  834,  834,  611,
     667,  667,  667,  667,  667,  667, 1000,  722,  667,  667,  667,  667,  278,  278,  278,  278,
     722,  722,  778,  778,  778,  778,  778,  584,  778,  722,  722,  722,  722,  667,  667,  611,
     556,  556,  556,  556,  556,  556,  889,  500,  556,  556,  556,  556,  278,  278,  278,  278,
     556,  556,  556,  556,  556,  556,  556,  584,  611,  556,  556,  556,  556,  500,  556,  500,
]

private let afmHelveticaBold: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     278,  333,  474,  556,  556,  889,  722,  238,  333,  333,  389,  584,  278,  333,  278,  278,
     556,  556,  556,  556,  556,  556,  556,  556,  556,  556,  333,  333,  584,  584,  584,  611,
     975,  722,  722,  722,  722,  667,  611,  778,  722,  278,  556,  722,  611,  833,  722,  778,
     667,  778,  722,  667,  611,  722,  667,  944,  667,  667,  611,  333,  278,  333,  584,  556,
     333,  556,  611,  556,  611,  556,  333,  611,  611,  278,  278,  556,  278,  889,  611,  611,
     611,  611,  389,  556,  333,  611,  556,  778,  556,  556,  500,  389,  280,  389,  584,    0,
       0,    0,  278,  556,  500, 1000,  556,  556,  333, 1000,  667,  333, 1000,    0,  611,    0,
       0,  278,  278,  500,  500,  350,  556, 1000,  333, 1000,  556,  333,  944,    0,  500,  667,
     278,  333,  556,  556,  556,  556,  280,  556,  333,  737,  370,  556,  584,  333,  737,  333,
     400,  584,  333,  333,  333,  611,  556,  278,  333,  333,  365,  556,  834,  834,  834,  611,
     722,  722,  722,  722,  722,  722, 1000,  722,  667,  667,  667,  667,  278,  278,  278,  278,
     722,  722,  778,  778,  778,  778,  778,  584,  778,  722,  722,  722,  722,  667,  667,  611,
     556,  556,  556,  556,  556,  556,  889,  556,  556,  556,  556,  556,  278,  278,  278,  278,
     611,  611,  611,  611,  611,  611,  611,  584,  611,  611,  611,  611,  611,  556,  611,  556,
]

private let afmTimesRoman: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     250,  333,  408,  500,  500,  833,  778,  180,  333,  333,  500,  564,  250,  333,  250,  278,
     500,  500,  500,  500,  500,  500,  500,  500,  500,  500,  278,  278,  564,  564,  564,  444,
     921,  722,  667,  667,  722,  611,  556,  722,  722,  333,  389,  722,  611,  889,  722,  722,
     556,  722,  667,  556,  611,  722,  722,  944,  722,  722,  611,  333,  278,  333,  469,  500,
     333,  444,  500,  444,  500,  444,  333,  500,  500,  278,  278,  500,  278,  778,  500,  500,
     500,  500,  333,  389,  278,  500,  500,  722,  500,  500,  444,  480,  200,  480,  541,    0,
       0,    0,  333,  500,  444, 1000,  500,  500,  333, 1000,  556,  333,  889,    0,  611,    0,
       0,  333,  333,  444,  444,  350,  500, 1000,  333,  980,  389,  333,  722,    0,  444,  722,
     250,  333,  500,  500,  500,  500,  200,  500,  333,  760,  276,  500,  564,  333,  760,  333,
     400,  564,  300,  300,  333,  500,  453,  250,  333,  300,  310,  500,  750,  750,  750,  444,
     722,  722,  722,  722,  722,  722,  889,  667,  611,  611,  611,  611,  333,  333,  333,  333,
     722,  722,  722,  722,  722,  722,  722,  564,  722,  722,  722,  722,  722,  722,  556,  500,
     444,  444,  444,  444,  444,  444,  667,  444,  444,  444,  444,  444,  278,  278,  278,  278,
     500,  500,  500,  500,  500,  500,  500,  564,  500,  500,  500,  500,  500,  500,  500,  500,
]

private let afmTimesBold: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     250,  333,  555,  500,  500, 1000,  833,  278,  333,  333,  500,  570,  250,  333,  250,  278,
     500,  500,  500,  500,  500,  500,  500,  500,  500,  500,  333,  333,  570,  570,  570,  500,
     930,  722,  667,  722,  722,  667,  611,  778,  778,  389,  500,  778,  667,  944,  722,  778,
     611,  778,  722,  556,  667,  722,  722, 1000,  722,  722,  667,  333,  278,  333,  581,  500,
     333,  500,  556,  444,  556,  444,  333,  500,  556,  278,  333,  556,  278,  833,  556,  500,
     556,  556,  444,  389,  333,  556,  500,  722,  500,  500,  444,  394,  220,  394,  520,    0,
       0,    0,  333,  500,  500, 1000,  500,  500,  333, 1000,  556,  333, 1000,    0,  667,    0,
       0,  333,  333,  500,  500,  350,  500, 1000,  333, 1000,  389,  333,  722,    0,  444,  722,
     250,  333,  500,  500,  500,  500,  220,  500,  333,  747,  300,  500,  570,  333,  747,  333,
     400,  570,  300,  300,  333,  556,  540,  250,  333,  300,  330,  500,  750,  750,  750,  500,
     722,  722,  722,  722,  722,  722, 1000,  722,  667,  667,  667,  667,  389,  389,  389,  389,
     722,  722,  778,  778,  778,  778,  778,  570,  778,  722,  722,  722,  722,  722,  611,  556,
     500,  500,  500,  500,  500,  500,  722,  444,  444,  444,  444,  444,  278,  278,  278,  278,
     500,  556,  500,  500,  500,  500,  500,  570,  500,  556,  556,  556,  556,  500,  556,  500,
]

private let afmTimesItalic: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     250,  333,  420,  500,  500,  833,  778,  214,  333,  333,  500,  675,  250,  333,  250,  278,
     500,  500,  500,  500,  500,  500,  500,  500,  500,  500,  333,  333,  675,  675,  675,  500,
     920,  611,  611,  667,  722,  611,  611,  722,  722,  333,  444,  667,  556,  833,  667,  722,
     611,  722,  611,  500,  556,  722,  611,  833,  611,  556,  556,  389,  278,  389,  422,  500,
     333,  500,  500,  444,  500,  444,  278,  500,  500,  278,  278,  444,  278,  722,  500,  500,
     500,  500,  389,  389,  278,  500,  444,  667,  444,  444,  389,  400,  275,  400,  541,    0,
       0,    0,  333,  500,  556,  889,  500,  500,  333, 1000,  500,  333,  944,    0,  556,    0,
       0,  333,  333,  556,  556,  350,  500,  889,  333,  980,  389,  333,  667,    0,  389,  556,
     250,  389,  500,  500,  500,  500,  275,  500,  333,  760,  276,  500,  675,  333,  760,  333,
     400,  675,  300,  300,  333,  500,  523,  250,  333,  300,  310,  500,  750,  750,  750,  500,
     611,  611,  611,  611,  611,  611,  889,  667,  611,  611,  611,  611,  333,  333,  333,  333,
     722,  667,  722,  722,  722,  722,  722,  675,  722,  722,  722,  722,  722,  556,  611,  500,
     500,  500,  500,  500,  500,  500,  667,  444,  444,  444,  444,  444,  278,  278,  278,  278,
     500,  500,  500,  500,  500,  500,  500,  675,  500,  500,  500,  500,  500,  444,  500,  444,
]

private let afmTimesBoldItalic: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     250,  389,  555,  500,  500,  833,  778,  278,  333,  333,  500,  570,  250,  333,  250,  278,
     500,  500,  500,  500,  500,  500,  500,  500,  500,  500,  333,  333,  570,  570,  570,  500,
     832,  667,  667,  667,  722,  667,  667,  722,  778,  389,  500,  667,  611,  889,  722,  722,
     611,  722,  667,  556,  611,  722,  667,  889,  667,  611,  611,  333,  278,  333,  570,  500,
     333,  500,  500,  444,  500,  444,  333,  500,  556,  278,  278,  500,  278,  778,  556,  500,
     500,  500,  389,  389,  278,  556,  444,  667,  500,  444,  389,  348,  220,  348,  570,    0,
       0,    0,  333,  500,  500, 1000,  500,  500,  333, 1000,  556,  333,  944,    0,  611,    0,
       0,  333,  333,  500,  500,  350,  500, 1000,  333, 1000,  389,  333,  722,    0,  389,  611,
     250,  389,  500,  500,  500,  500,  220,  500,  333,  747,  266,  500,  606,  333,  747,  333,
     400,  570,  300,  300,  333,  576,  500,  250,  333,  300,  300,  500,  750,  750,  750,  500,
     667,  667,  667,  667,  667,  667,  944,  667,  667,  667,  667,  667,  389,  389,  389,  389,
     722,  722,  722,  722,  722,  722,  722,  570,  722,  722,  722,  722,  722,  611,  611,  500,
     500,  500,  500,  500,  500,  500,  722,  444,  444,  444,  444,  444,  278,  278,  278,  278,
     500,  556,  500,  500,  500,  500,  500,  570,  500,  556,  556,  556,  556,  444,  500,  444,
]

private let afmSymbol: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     250,  333,  713,  500,  549,  833,  778,  631,  333,  333,  500,  549,  250,  549,  250,  278,
     500,  500,  500,  500,  500,  500,  500,  500,  500,  500,  278,  278,  549,  549,  549,  444,
     549,  722,  667,  722,  612,  611,  763,  603,  722,  333,  631,  722,  686,  889,  722,  722,
     768,  741,  556,  592,  611,  690,  631,  768,  645,  795,  611,  333,  863,  333,  658,  500,
     500,  631,  549,  549,  494,  631,  521,  411,  603,  329,  603,  549,  549,  576,  521,  549,
     549,  521,  549,  603,  631,  576,  713,  686,  493,  686,  494,  480,  200,  480,  549,    0,
     790,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     750,  620,  247,  549,  167,  713,  500,  753,  753,  753,  753, 1042,  987,  603,  987,  603,
     400,  549,  411,  549,  549,  713,  494,  460,  549,  549,  549,  549, 1000,  603, 1000,  658,
     823,  686,  795,  987,  768,  768,  823,  768,  768,  713,  713,  713,  713,  713,  713,  713,
     768,  713,  790,  790,  890,  823,  549,  250,  713,  603,  603, 1042,  987,  603,  987,  603,
     494,  329,  790,  790,  786,  713,  384,  384,  384,  384,  384,  384,  494,  494,  494,  494,
       0,  329,  274,  686,  686,  686,  384,  384,  384,  384,  384,  384,  494,  494,  494,    0,
]

private let afmZapfDingbats: [Int] = [
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
     278,  974,  961,  974,  980,  719,  789,  790,  791,  690,  960,  939,  549,  855,  911,  933,
     911,  945,  974,  755,  846,  762,  761,  571,  677,  763,  760,  759,  754,  494,  552,  537,
     577,  692,  786,  788,  788,  790,  793,  794,  816,  823,  789,  841,  823,  833,  816,  831,
     923,  744,  723,  749,  790,  792,  695,  776,  768,  792,  759,  707,  708,  682,  701,  826,
     815,  789,  789,  707,  687,  696,  689,  786,  787,  713,  791,  785,  791,  873,  761,  762,
     762,  759,  759,  892,  892,  788,  784,  438,  138,  277,  415,  392,  392,  668,  668,    0,
     390,  390,  317,  317,  276,  276,  509,  509,  410,  410,  234,  234,  334,  334,    0,    0,
       0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
       0,  732,  544,  544,  910,  667,  760,  760,  776,  595,  694,  626,  788,  788,  788,  788,
     788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,
     788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,  788,
     788,  788,  788,  788,  894,  838, 1016,  458,  748,  924,  748,  918,  927,  928,  928,  834,
     873,  828,  924,  924,  917,  930,  931,  463,  883,  836,  836,  867,  867,  696,  696,  874,
       0,  874,  760,  946,  771,  865,  771,  888,  967,  888,  831,  873,  927,  970,  918,    0,
]

/// PDF `/BaseFont` name (i.e. `base14`'s own values) -> the widths that
/// face sets its glyphs at.
let afmWidths: [String: [Int]] = [
    "Courier": afmCourier,
    "Courier-Bold": afmCourier,
    "Courier-Oblique": afmCourier,
    "Courier-BoldOblique": afmCourier,
    "Helvetica": afmHelvetica,
    "Helvetica-Bold": afmHelveticaBold,
    "Helvetica-Oblique": afmHelvetica,
    "Helvetica-BoldOblique": afmHelveticaBold,
    "Times-Roman": afmTimesRoman,
    "Times-Bold": afmTimesBold,
    "Times-Italic": afmTimesItalic,
    "Times-BoldItalic": afmTimesBoldItalic,
    "Symbol": afmSymbol,
    "ZapfDingbats": afmZapfDingbats,
]


/// Natural width of `text` set in `baseFont`, in 1/1000 em.
///
/// `text` is measured as the writer will WRITE it — encoded cp1252 (the declared
/// `/WinAnsiEncoding`), with anything outside that repertoire replaced by `?`, which is
/// exactly what `esc` does (modulo `esc`'s own lookalike-degradation pass — see
/// `PDFWriter.swift`; this measures the text as GIVEN, matching ctrl-kd's
/// `string_width_1000`, which does not apply that pass either). Measuring the string
/// directly (as Unicode scalars) would count a character the PDF never receives.
///
/// An unknown base font falls back to Courier's fixed 600: a face this table does not carry
/// cannot be measured, and 600 is this emitter's own default pitch, not a guess at the
/// missing face.
func stringWidth1000(_ text: String, _ baseFont: String) -> Int {
    let table = afmWidths[baseFont] ?? afmCourier
    var total = 0
    for byte in cp1252Encode(text) {
        total += table[Int(byte)]
    }
    return total
}

/// Natural width of `text` in POINTS at `size`.
func stringWidthPt(_ text: String, _ baseFont: String, _ size: Int) -> Double {
    Double(stringWidth1000(text, baseFont)) * Double(size) / 1000.0
}
