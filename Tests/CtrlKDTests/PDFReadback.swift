/// Reading a rendered PDF back apart in assertions — the Swift half of Python's
/// `_content_text` / `_content_spans` / `_basefonts` test helpers.
///
/// Python matches the content stream with a regular expression. This target imports nothing
/// (no Foundation, therefore no `NSRegularExpression`, and no `range(of:)`), so the same job
/// is a hand-written scan. That is not a hardship here: the emitter's operators are written
/// by this project, in one shape, with `esc` as the only thing that can put a byte inside a
/// string literal — so a scanner that knows that shape is as exact as the regex and says
/// what it assumes out loud.
@testable import CtrlKD

/// One text-showing operator, decoded.
///
/// `tz`, `x` and `y` are optional because the emitter has three shapes for the same
/// operator: `Tz` (horizontal scaling) is written only when the value CHANGES, and the
/// proportional line path writes one `Td` for a whole line rather than one per span.
struct ShownSpan {
    let font: String            // "F1", not "/F1"
    let size: Int
    let rise: Int
    let tz: Double?
    let x: Double?
    let y: Double?
    /// The literal's bytes with `esc`'s escaping undone — `esc` escapes only backslash and
    /// the two parentheses, so this is exactly the text the emitter was handed.
    let text: String
}

/// Every text-showing operator in a PDF, in stream order.
func contentSpans(_ pdf: [UInt8]) -> [ShownSpan] {
    let chars = Array(latin1(pdf))
    var out: [ShownSpan] = []
    var i = 0
    while i < chars.count {
        // The operator always opens with the font resource name.
        guard chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "F" else { i += 1; continue }
        var j = i + 2
        var number = ""
        while j < chars.count, chars[j].isNumber { number.append(chars[j]); j += 1 }
        guard !number.isEmpty else { i += 1; continue }

        // Everything between the font name and the string literal, as whitespace-separated
        // tokens. A newline ends the operator: no text-showing operator spans two lines.
        var tokens: [String] = []
        var token = ""
        var sawLiteral = false
        while j < chars.count {
            let c = chars[j]
            if c == "(" { sawLiteral = true; j += 1; break }
            if c == "\n" { break }
            if c == " " {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(c)
            }
            j += 1
        }
        guard sawLiteral, tokens.count >= 4, tokens[1] == "Tf", tokens[3] == "Ts",
              let size = Int(tokens[0]), let rise = Int(tokens[2]) else { i += 1; continue }

        var k = 4
        var tz: Double? = nil
        if k + 1 < tokens.count, tokens[k + 1] == "Tz" { tz = Double(tokens[k]); k += 2 }
        var x: Double? = nil
        var y: Double? = nil
        if k + 2 < tokens.count, tokens[k + 2] == "Td" {
            x = Double(tokens[k])
            y = Double(tokens[k + 1])
        }

        // The literal, with `esc`'s escaping undone. A backslash always escapes exactly one
        // following character here, so the unescaped `)` that closes the literal is the
        // first one not preceded by a backslash.
        var text = ""
        while j < chars.count {
            if chars[j] == "\\", j + 1 < chars.count {
                text.append(chars[j + 1])
                j += 2
                continue
            }
            if chars[j] == ")" { j += 1; break }
            text.append(chars[j])
            j += 1
        }
        out.append(ShownSpan(font: "F" + number, size: size, rise: rise,
                             tz: tz, x: x, y: y, text: text))
        i = j
    }
    return out
}

/// `["F1": "Courier", …]` — the resource dict's `/Fn` names resolved through the indirect
/// references to the font objects they point at, so a test asserts on the FACE and never on
/// an object number.
func baseFonts(_ pdf: [UInt8]) -> [String: String] {
    let lines = latin1(pdf).split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    var byNumber: [Int: String] = [:]
    for (i, line) in lines.enumerated() where line.hasSuffix(" 0 obj") {
        guard let number = Int(line.dropLast(6)), i + 1 < lines.count else { continue }
        let body = lines[i + 1]
        guard body.hasPrefix("<< /Type /Font ") else { continue }
        let tokens = body.split(separator: " ").map(String.init)
        guard let at = tokens.firstIndex(of: "/BaseFont"), at + 1 < tokens.count else { continue }
        byNumber[number] = String(tokens[at + 1].dropFirst())      // "/Courier" -> "Courier"
    }

    var out: [String: String] = [:]
    for line in lines where line.hasPrefix("<< /Type /Page ") {
        let tokens = line.split(separator: " ").map(String.init)
        for (k, token) in tokens.enumerated() {
            // `/Font` also starts "/F": a resource name is `/F` plus digits and nothing else.
            guard token.hasPrefix("/F"), Int(token.dropFirst(2)) != nil,
                  k + 2 < tokens.count, tokens[k + 2] == "0",
                  let number = Int(tokens[k + 1]), let base = byNumber[number] else { continue }
            out[String(token.dropFirst())] = base
        }
    }
    return out
}

/// The `/Fn` name a face was registered under in this PDF.
func fontName(for baseFont: String, in pdf: [UInt8]) -> String? {
    baseFonts(pdf).first { $0.value == baseFont }?.key
}
