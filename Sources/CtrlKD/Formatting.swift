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
/// Round-half-to-even on the EXACT binary value, same as Python's correctly-rounded
/// formatter — via integer arithmetic on the double's own significand/exponent, so no
/// second floating-point rounding step can disagree. The previous implementation rounded
/// `value * 10` and its documented in-principle disagreement became real on 2026-08-06:
/// Modern proportional x-advances land on values like 184.35 (binary 184.34999…), where
/// `* 10.0` rounds UP to exactly 1843.5 and the tie-break then fired on a value Python's
/// exact formatter sees as below the midpoint — 23 ops in one archive PDF differed by
/// 0.1pt. Exact comparison: value = m/2^k with integer m, so tenths = ⌊10m/2^k⌋ and the
/// remainder compares against half of 2^k with no rounding at all.
func fixedOneDecimalDouble(_ value: Double) -> String {
    let negative = value < 0
    let magnitude = negative ? -value : value
    // Domain guard: coordinates are 0..~15000pt. Anything under half a thousandth of a
    // tenth formats as 0.0 regardless; anything astronomically large would overflow the
    // exact path and cannot occur in a PDF this writer emits.
    if magnitude < 0.001 { return (negative ? "-" : "") + "0.0" }
    let m = Int64(magnitude.significandBitPattern | (1 << 52))   // normal doubles only here
    let e2 = magnitude.exponent - 52                             // magnitude = m * 2^e2
    var tenths: Int64
    if e2 >= 0 {
        // an exact integer: no fraction, no tie (e2 capped: a coordinate ≥ 2^58pt is no
        // real PDF; the cap only avoids shift overflow, the value is absurd either way)
        tenths = (m << min(e2, 5)) * 10
    } else if e2 < -62 {
        // magnitude < 2^-10: caught by the domain guard above; unreachable
        tenths = 0
    } else {
        let den: Int64 = 1 << (-e2)
        let num = m.multipliedReportingOverflow(by: 10)
        if num.overflow {
            // magnitude ≥ ~2^59pt: no real PDF coordinate; saturate via the old path
            tenths = Int64(magnitude * 10.0)
        } else {
            tenths = num.partialValue / den
            let rem = num.partialValue % den
            let twice = rem.multipliedReportingOverflow(by: 2)
            if !twice.overflow {
                if twice.partialValue > den {
                    tenths += 1
                } else if twice.partialValue == den {
                    if tenths % 2 != 0 { tenths += 1 }           // half-to-even
                }
            } else if rem > den / 2 {
                tenths += 1
            }
        }
    }
    return (negative ? "-" : "") + "\(tenths / 10).\(tenths % 10)"
}

/// A `Double` rounded to hundredths, AS AN INTEGER of hundredths — Python's `round(x, 2)`
/// with the result kept exact instead of being handed back to binary floating point.
///
/// The `Tz` horizontal-scaling operator needs this twice and for two different jobs: it is
/// written `'%.2f'`, and it is written ONLY WHEN THE VALUE CHANGES, which means the emitter
/// compares one scaling to the next. Comparing `Double`s rounded to two places is a float
/// equality test on values that are not exactly representable; comparing hundredths is
/// integer equality and cannot disagree with the digits actually printed.
///
/// Round-half-to-even, Python's tie-break, by the same truncate-and-compare technique as
/// `fixedOneDecimalDouble` (no libm, see there).
func hundredths(_ value: Double) -> Int {
    let negative = value < 0
    let scaled = (negative ? -value : value) * 100.0
    let whole = Int(scaled)
    let fraction = scaled - Double(whole)
    let rounded: Int
    if fraction < 0.5 {
        rounded = whole
    } else if fraction > 0.5 {
        rounded = whole + 1
    } else {
        rounded = whole % 2 == 0 ? whole : whole + 1
    }
    return negative ? -rounded : rounded
}

/// Python's `'%.2f' % value`, for a value already reduced to exact hundredths by
/// `hundredths(_:)`.
func fixedTwoDecimal(hundredths value: Int) -> String {
    let negative = value < 0
    let magnitude = negative ? -value : value
    let fraction = magnitude % 100
    let tens = fraction / 10
    return (negative ? "-" : "") + "\(magnitude / 100).\(tens)\(fraction % 10)"
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
