/// A minimal JSON value and writer, for `--diagnose` output.
///
/// Foundation has two JSON writers and neither is right here. `JSONSerialization` takes
/// `[String: Any]`, which throws away every type at the boundary and would make the
/// diagnose builder untestable except by round-tripping through text; it also escapes
/// forward slashes (`"\/tmp\/x"`), which the Python reference does not. `JSONEncoder`
/// wants a `Codable` struct, and diagnose output is not one shape — it has three
/// (empty/^Z, detected-only, and WordStar-with-parse-evidence), which in Swift means a
/// pile of optionals and a hand-written `encode(to:)` anyway.
///
/// So: an enum. The builder returns a value that tests can compare structurally against
/// the Python reference, and `render()` is the only thing that knows about bytes.
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    /// Page geometry (ctrl-kd 1.2.0's `--diagnose` "page" field): `.pl`/`.po`/`.mt`/`.mb`
    /// resolve to `Double` (a unit-suffixed dot-command argument like `.mt 1.5"` converts
    /// to a fractional line count), so the JSON writer needs a real floating-point case
    /// rather than truncating everything to `Int`. Swift's default `Double` description
    /// already prints a trailing `.0` for whole values (`"\(66.0)"` == `"66.0"`), matching
    /// Python's `repr`/`json.dumps` closely enough for the documented EQUIVALENT-not-
    /// byte-identical output this type promises elsewhere.
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// The documented output shape: keys sorted, two-space indent — i.e. what Python's
    /// `json.dumps(obj, indent=2, sort_keys=True)` produces, which is what makes the output
    /// diffable and safe to pipe into `jq` or a test.
    ///
    /// Non-ASCII characters are emitted as UTF-8 rather than `\uXXXX` escapes (Python's
    /// `ensure_ascii=True` default). This is a deliberate divergence: the only field that
    /// can carry non-ASCII is the file path, and a legible path beats a byte-identical one
    /// for a human reading the output.
    public func render() -> String {
        render(indent: 0)
    }

    private func render(indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch self {
        case .string(let s):
            return JSONValue.quote(s)
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { inner + $0.render(indent: indent + 2) }.joined(separator: ",\n")
            return "[\n" + body + "\n" + pad + "]"
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            let body = fields.keys.sorted().map { key in
                inner + JSONValue.quote(key) + ": " + fields[key]!.render(indent: indent + 2)
            }.joined(separator: ",\n")
            return "{\n" + body + "\n" + pad + "}"
        }
    }

    /// A JSON string literal: the two mandatory escapes, the five shorthands, and `\u00XX`
    /// for every other C0 control byte.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + JSONValue.hex2(UInt8(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Lowercase two-digit hex — Python's `f'{k:02x}'`, which is also how `unknown_codes`
    /// keys are spelled (core.py:323).
    static func hex2(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
