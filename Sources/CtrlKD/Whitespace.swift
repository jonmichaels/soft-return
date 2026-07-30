/// Python-faithful whitespace trimming for the emitters.
///
/// The emitters lean on `str.strip()`/`lstrip()`/`rstrip()` in several places where the
/// result is load-bearing (blank-paragraph filtering, `_md_span`'s lead/trail peeling).
/// `Foundation` is off-limits in `Sources/`, so these are hand-rolled — and they operate
/// on `unicodeScalars`, not `Character`, because Python works in code points and grapheme
/// clustering could otherwise merge a combining mark into a neighbour.
///
/// Python's `str.isspace()` is true for a wider set than this (it includes 0x1C-0x1F,
/// whose bidi class is B/S), but the narrower set below is exact for the text that can
/// actually reach an emitter: both parsers discard every byte under 0x20 except tab, so a
/// span's text contains only 0x09, 0x20...0x7E, and cp437-extended codepoints — of which
/// U+00A0 (byte 0xFF) is the sole whitespace, as established in job-005. The 0x0A/0x0C
/// entries cover the newlines and form feeds the emitters themselves join with.
private let pythonWhitespace: Set<UInt32> = [
    0x09,   // tab
    0x0A,   // newline
    0x0B,   // vertical tab
    0x0C,   // form feed
    0x0D,   // carriage return
    0x20,   // space
    0xA0,   // no-break space (cp437 0xFF)
]

extension String {
    private static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        pythonWhitespace.contains(scalar.value)
    }

    /// Equivalent of Python's `str.strip()` with no argument.
    func trimmed() -> String {
        var scalars = Array(unicodeScalars)
        while let first = scalars.first, String.isPythonSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, String.isPythonSpace(last) { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// The leading run of whitespace — Python's `s[:len(s) - len(s.lstrip())]`.
    func leadingWhitespace() -> String {
        var view = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            guard String.isPythonSpace(scalar) else { break }
            view.append(scalar)
        }
        return String(view)
    }

    /// Equivalent of Python's `str.lstrip()` with no argument — the string with its leading
    /// whitespace run removed. Pairs with `leadingWhitespace()`, which returns that run.
    func trimmedLeading() -> String {
        var view = String.UnicodeScalarView()
        var seenNonSpace = false
        for scalar in unicodeScalars {
            if !seenNonSpace && String.isPythonSpace(scalar) { continue }
            seenNonSpace = true
            view.append(scalar)
        }
        return String(view)
    }

    /// The trailing run of whitespace — Python's `s[len(s.rstrip()):]`.
    func trailingWhitespace() -> String {
        var trailing: [Unicode.Scalar] = []
        for scalar in unicodeScalars.reversed() {
            guard String.isPythonSpace(scalar) else { break }
            trailing.append(scalar)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: trailing.reversed())
        return String(view)
    }

    /// Equivalent of Python's `str.replace(old, new)`. Hand-rolled because
    /// `replacingOccurrences(of:with:)` is Foundation, which `Sources/` stays free of.
    /// Scans left to right and does not rescan inserted text, matching Python.
    func replacingAll(_ target: Character, with replacement: String) -> String {
        var out = String()
        out.reserveCapacity(count)
        for character in self {
            if character == target {
                out += replacement
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// Equivalent of Python's `str.rstrip(chars)` for a single repeated character.
    func trimmingTrailing(_ scalar: Unicode.Scalar) -> String {
        var scalars = Array(unicodeScalars)
        while let last = scalars.last, last == scalar { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
