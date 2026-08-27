import Foundation

/// Four-character AppleEvent codes (`OSType`), for bridging `SoftReturn.sdef`'s
/// enumerations to and from Cocoa Scripting's `typeEnumerated` values.
///
/// Cocoa's scripting KVC bridge boxes an sdef `<enumerator code="XXXX">` as an `NSNumber`
/// wrapping that code's 32-bit integer value on the way into a `@objc dynamic` property
/// getter/setter. There is no runtime API to go from the sdef's own XML back to that
/// integer, so both directions are spelled out by hand here, once, against the exact
/// codes in `SoftReturn.sdef` — every enumeration in this file must have a matching case
/// in `ScriptingCodes.swift`'s tables, or the round trip silently breaks.
enum ScriptingCodes {
    /// The 32-bit value AppleEvent code `s` (e.g. `"SRv4"`) becomes — big-endian, the same
    /// byte order `FOUR_CHAR_CODE`/`'SRv4'` uses in C. `s` must be exactly 4 ASCII bytes;
    /// every code below is checked against that by `ScriptingCodesTests`.
    static func fourCharCode(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for scalar in s.unicodeScalars.prefix(4) {
            result = (result << 8) | (scalar.value & 0xFF)
        }
        return result
    }

    static func nsNumber(_ code: String) -> NSNumber {
        NSNumber(value: fourCharCode(code))
    }

    /// The inverse of `fourCharCode(_:)` — job 216's lifecycle instrument needs to render a
    /// live `descriptorType`/`enumCodeValue` (an `OSType` read back off a real descriptor)
    /// as readable ASCII in a breadcrumb, not the other direction this file existed for
    /// before. Non-printable bytes (there shouldn't be any in a well-formed four-char code,
    /// but a malformed/garbage descriptor is exactly what this instrument exists to catch)
    /// render as `.` rather than crashing or producing an unreadable control character.
    static func string(fromFourCharCode code: UInt32) -> String {
        var scalars: [Unicode.Scalar] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((code >> shift) & 0xFF)
            let printable = (0x20...0x7E).contains(byte)
            scalars.append(Unicode.Scalar(printable ? byte : UInt8(ascii: ".")))
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
