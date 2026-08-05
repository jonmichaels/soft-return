#!/usr/bin/env python3
"""Generate `Sources/CtrlKD/AFM.swift` from ctrl-kd's `src/ctrlkd/afm.py`.

WHY A GENERATOR. The Adobe Core 14 widths are 13 tables of 256 integers. Retyping
3,328 numbers into Swift by hand is a transcription-error machine, and a single
wrong width is invisible: it does not crash, it moves one span a fraction of a
point and only shows up as drift the cross-check cannot explain. So the numbers
are copied by a program, from the Python module that is this project's reference
implementation, and the generated file is committed (nothing runs at build time —
CtrlKD imports nothing, including a build tool).

Usage, with the two repos side by side:

    python3 Scripts/generate-afm.py ../ctrl-kd/src/ctrlkd/afm.py Sources/CtrlKD/AFM.swift

Re-run it if ctrl-kd's tables ever change; the output is deterministic, so a
no-op run leaves the file byte-identical.
"""
import importlib.util
import sys

# Swift identifier per PDF /BaseFont name. Courier's four share one table.
SWIFT_NAME = {
    'Courier': 'afmCourier',
    'Helvetica': 'afmHelvetica',
    'Helvetica-Bold': 'afmHelveticaBold',
    'Helvetica-Oblique': 'afmHelveticaOblique',
    'Helvetica-BoldOblique': 'afmHelveticaBoldOblique',
    'Times-Roman': 'afmTimesRoman',
    'Times-Bold': 'afmTimesBold',
    'Times-Italic': 'afmTimesItalic',
    'Times-BoldItalic': 'afmTimesBoldItalic',
    'Symbol': 'afmSymbol',
    'ZapfDingbats': 'afmZapfDingbats',
}

HEADER = '''\
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
'''

FOOTER = '''
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
'''


def swift_table(name, widths):
    lines = [f'private let {name}: [Int] = [']
    for row in range(0, 256, 16):
        chunk = ', '.join('%4d' % w for w in widths[row:row + 16])
        lines.append(f'    {chunk},')
    lines.append(']')
    return '\n'.join(lines)


def main():
    src, dest = sys.argv[1], sys.argv[2]
    spec = importlib.util.spec_from_file_location('_afm', src)
    afm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(afm)

    out = [HEADER]
    out.append('\nprivate let afmCourier: [Int] = '
               '[Int](repeating: afmCourierWidth, count: 256)\n')

    seen = {}   # widths tuple -> Swift name; equal tables share one array
    for basefont, widths in afm.WIDTHS.items():
        if widths in seen:
            continue
        seen[widths] = SWIFT_NAME[basefont]
        if basefont.startswith('Courier'):
            continue                                   # emitted above
        assert len(widths) == 256, basefont
        out.append(swift_table(SWIFT_NAME[basefont], widths) + '\n')

    out.append('/// PDF `/BaseFont` name (i.e. `base14`\'s own values) -> the widths that\n'
               '/// face sets its glyphs at.\n'
               'let afmWidths: [String: [Int]] = [')
    for basefont, widths in afm.WIDTHS.items():
        out.append('    "%s": %s,' % (basefont, seen[widths]))
    out.append(']\n')
    out.append(FOOTER)

    with open(dest, 'w') as fh:
        fh.write('\n'.join(out))


if __name__ == '__main__':
    main()
