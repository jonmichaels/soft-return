/// The two number formats the PDF writer needs, hand-rolled — `'%.1f'` and `'%010d'`.
///
/// Foundation stays out of this library (job-001), which rules out `String(format:)`. That
/// is the constraint; what follows is better than a workaround for it. A hand-rolled
/// formatter matches PYTHON's output by construction rather than by two printf
/// implementations happening to agree on rounding, and PDF is a format where a wrong digit
/// is a moved glyph.

/// Python's `'%.1f' % value`, for a value carried as integer TENTHS of a point.
///
/// The tenths convention is the point. Every coordinate `pdf.py` computes is an exact
/// multiple of 0.1 — the metrics are integers, the character advance is `size * 0.6` with
/// `size` in {8, 12} (4.8 and 7.2), and the rule offsets are 1.5 and 3. Python does that
/// arithmetic in binary floats and then asks `%.1f` to round the accumulated error away;
/// it always can, because the true value is a tenth and the error is ~1e-13. Carrying
/// tenths as `Int` skips the round trip: the arithmetic is exact, and formatting is
/// division by ten.
///
/// So the PDF writer should hold `x`, `y` and `w` as tenths — `margin * 10`, `count * size
/// * 6` for an advance, `lead * 10` per line — and never introduce a `Double` at all. That
/// was checked against the reference before it was written this way: over every coordinate
/// `pdf.py` can produce on a page (5988 of them, both type sizes, both top margins, the
/// underline and strike offsets), Python's float result and the exact tenth format to the
/// same string in every case.
///
/// One documented non-match, unreachable from the writer: Python prints `'%.1f' % -0.04` as
/// `-0.0`, keeping a sign this has already lost by the time it sees `0` tenths.
func fixedOneDecimal(tenths: Int) -> String {
    let negative = tenths < 0
    let magnitude = negative ? -tenths : tenths
    return (negative ? "-" : "") + "\(magnitude / 10).\(magnitude % 10)"
}

/// Python's `'%0<width>d' % value` — the xref table's `'%010d'`, whose column is fixed
/// width and whose offsets a reader takes on faith.
///
/// Pads to `width` INCLUDING a minus sign, as Python does (`'%010d' % -42` is `-000000042`,
/// ten characters), and never truncates a value too big for the field.
func zeroPadded(_ value: Int, width: Int) -> String {
    let negative = value < 0
    let digits = String(negative ? -value : value)
    let pad = width - digits.count - (negative ? 1 : 0)
    return (negative ? "-" : "") + String(repeating: "0", count: max(0, pad)) + digits
}
