/// The number formats the PDF writer needs, hand-rolled — `'%.1f'` (both the integer-tenths
/// convention and, since ctrl-kd 1.3.0's page-geometry work, real fractional `Double`s) and
/// `'%010d'`.
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

/// Python's `'%.1f' % value` for a real `Double` — needed once a printed-mode baseline lead
/// can be irrational-at-48ths (ctrl-kd 1.3.0's `.lh` unit conversions: `.lh 1C` is
/// `28.346456692913385`pt, not a clean tenth), so the writer's accumulated `y` is no longer
/// always an exact multiple of 0.1 the way `fixedOneDecimal(tenths:)` above assumes. Still
/// hand-rolled for the same reason that one is: Foundation's `String(format:)` stays out of
/// this library (job-001), and `Double.rounded()` needs libm symbols this Foundation-free
/// Linux build can't link (see `PDFLayout.swift`'s `roundHalfToEven`, the same technique this
/// borrows: truncate via `Int(_:)`, which is a compiler builtin, then compare the fraction).
///
/// Round-half-to-even, same tie-break as Python's own correctly-rounded formatter, computed
/// on `value * 10` rather than on the exact binary value directly — a second rounding step
/// that could in principle disagree with a fully correct decimal formatter at a value landing
/// exactly on a tenth's boundary only after that multiplication. Checked against the reference
/// for the actual coordinate domain this writer produces (every `.lh` unit conversion this
/// project's own vectors exercise, accumulated page-length deep, and both rule offsets): no
/// disagreement found.
func fixedOneDecimalDouble(_ value: Double) -> String {
    let negative = value < 0
    let magnitude = negative ? -value : value
    let scaled = magnitude * 10.0
    let whole = Int(scaled)
    let fraction = scaled - Double(whole)
    let tenths: Int
    if fraction < 0.5 {
        tenths = whole
    } else if fraction > 0.5 {
        tenths = whole + 1
    } else {
        tenths = whole % 2 == 0 ? whole : whole + 1
    }
    return (negative ? "-" : "") + "\(tenths / 10).\(tenths % 10)"
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
