/// Standard (RFC 4648 §4) base64 encoding, pure Swift — this project's Foundation-free
/// `Sources/` has no `Data.base64EncodedString()` to reach for. Used by HTML's `--pictures
/// embed` (a `data:image/png;base64,...` URI, mirroring Python's `base64.b64encode`).
private let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

func base64Encode(_ data: [UInt8]) -> String {
    var out = ""
    out.reserveCapacity((data.count + 2) / 3 * 4)
    var i = 0
    while i + 3 <= data.count {
        let b0 = data[i], b1 = data[i + 1], b2 = data[i + 2]
        out.append(base64Alphabet[Int(b0 >> 2)])
        out.append(base64Alphabet[Int((b0 & 0x03) << 4 | b1 >> 4)])
        out.append(base64Alphabet[Int((b1 & 0x0F) << 2 | b2 >> 6)])
        out.append(base64Alphabet[Int(b2 & 0x3F)])
        i += 3
    }
    let remaining = data.count - i
    if remaining == 1 {
        let b0 = data[i]
        out.append(base64Alphabet[Int(b0 >> 2)])
        out.append(base64Alphabet[Int((b0 & 0x03) << 4)])
        out += "=="
    } else if remaining == 2 {
        let b0 = data[i], b1 = data[i + 1]
        out.append(base64Alphabet[Int(b0 >> 2)])
        out.append(base64Alphabet[Int((b0 & 0x03) << 4 | b1 >> 4)])
        out.append(base64Alphabet[Int((b1 & 0x0F) << 2)])
        out.append("=")
    }
    return out
}
