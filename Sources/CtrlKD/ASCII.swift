// ASCII-only case folding and trimming -- what Python's `bytes.upper()`/`bytes.lower()`/
// `bytes.strip()` and `str.lower()` do, which unlike `String`'s own case mapping never
// touch a non-ASCII byte. This engine stays Foundation-free, and a full Unicode case
// fold is Foundation's job, not this library's. The parser, the dot-command readers and
// the style library each carried a private copy; this is the one.

enum ASCII {
    /// Which bytes a trim removes. Python's `strip()` family, spelled for the places that
    /// need each set.
    enum Trim {
        /// a space only
        case space
        /// space and tab
        case blanks
        /// space, tab and carriage return (what a `.he`/`.pc` argument's right edge sheds)
        case blanksAndReturn
        /// every ASCII whitespace byte: space, tab, LF, CR, VT, FF. The parser's input is
        /// masked raw bytes, so a 0x8D soft return masks to 0x0D and must still be trimmed.
        case whitespace
        /// exactly one byte value (`bytes.strip(ch)`)
        case byte(UInt8)

        func contains(_ b: UInt8) -> Bool {
            switch self {
            case .space: return b == 0x20
            case .blanks: return b == 0x20 || b == 0x09
            case .blanksAndReturn: return b == 0x20 || b == 0x09 || b == 0x0D
            case .whitespace: return b == 0x20 || (b >= 0x09 && b <= 0x0D)
            case .byte(let x): return b == x
            }
        }
    }

    static func upper(_ b: UInt8) -> UInt8 { (b >= 0x61 && b <= 0x7A) ? b - 0x20 : b }
    static func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b }

    /// Python's `str.lower()` restricted to ASCII -- the style and font names this
    /// compares against are ASCII.
    static func lowercased(_ s: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                view.append(Unicode.Scalar(scalar.value + 0x20)!)
            } else {
                view.append(scalar)
            }
        }
        return String(view)
    }

    static func lstrip(_ b: [UInt8], _ trim: Trim) -> [UInt8] {
        var start = 0
        while start < b.count, trim.contains(b[start]) { start += 1 }
        return Array(b[start...])
    }

    static func rstrip(_ b: [UInt8], _ trim: Trim) -> [UInt8] {
        var end = b.count
        while end > 0, trim.contains(b[end - 1]) { end -= 1 }
        return Array(b[..<end])
    }

    static func strip(_ b: [UInt8], _ trim: Trim) -> [UInt8] {
        var start = 0, end = b.count
        while start < end, trim.contains(b[start]) { start += 1 }
        while end > start, trim.contains(b[end - 1]) { end -= 1 }
        return Array(b[start..<end])
    }
}

/// Everything before the last `/`, with the root case kept: `os.path.dirname`'s
/// `"a/b.WS"` -> `"a"`, `"b.WS"` -> `""`, `"/b.WS"` -> `"/"`. String math only. Public
/// so the command-line target uses this one rather than its own copy.
public func pathDirname(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    let head = String(path[..<slash])
    return head.isEmpty ? "/" : head
}
