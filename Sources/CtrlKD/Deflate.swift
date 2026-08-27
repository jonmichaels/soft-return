/// zlib-compatible compression for PIX's embedded-image streams (PNG `IDAT`, PDF
/// `FlateDecode` XObjects) — b24 round 21b closed the DEFLATE-byte-parity gap by
/// linking the REAL zlib (`libz`) rather than hand-rolling a compressor.
///
/// WHY A SYSTEM LIBRARY, NOT FOUNDATION: `libz` ships as part of the base system on
/// every platform this package targets (macOS's own SDK, every Linux distribution) —
/// this is a system library LINK, the same category as linking `libc`, not a
/// "framework dependency" in the sense `Package.swift`'s own no-Foundation ruling is
/// about (that ruling is about avoiding a heavyweight, platform-opinionated framework
/// for text/byte manipulation this project can do itself; zlib is neither — it is the
/// literal thing Python's own `zlib.compress` calls into, so linking it directly is
/// the ONLY way to get byte-IDENTICAL compressed output, not merely decode-compatible
/// output).
///
/// NO MODULE AT ALL (round 21d, the third and final iteration of the *packaging*
/// fix): round 21b tried a bare `.systemLibrary`; round 21c tried a real C target
/// (`CZlibShim`) wrapping `compress2`/`compressBound` in a minimal signature. Both
/// still handed Xcode a package module to give to a consumer, and job 363 found that
/// hand-off fails DETERMINISTICALLY for a `.bundle` product (SoftReturnImporter, the
/// mdimporter) with explicit modules off — Xcode never supplies a package C-target's
/// module there, module map or not. The fix that leaves nothing for Xcode to
/// mishandle: `Package.swift`'s own `linkerSettings: [.linkedLibrary("z")]` on the
/// `CtrlKD` target, plus the three C symbol declarations directly below — no header,
/// no module, just a linker flag and three symbol references, exactly like calling
/// any other libc function this project already does (`fopen`, `fread`, etc., in the
/// `sr`/`ctrlkd-demo` executables).
///
/// `@_extern(c:)`, NOT `@_silgen_name` (round 21e, the *declaration-mechanism* fix):
/// an Apple-official researcher, citing Swift's own `UnderscoredAttributes.md`
/// reference doc, corrected round 21d's choice. `@_silgen_name` binds a Swift
/// declaration to an EXACT symbol name assuming SWIFT ABI conventions (its
/// documented, intended use is pairing with `@_cdecl`/compiler-internal shims, or —
/// per a second, community research pass — the Swift standard library's own ~200
/// PERMANENT uses binding to a fixed, known C symbol, which is legitimately this
/// function's use case too; the attribute is not simply wrong here, but it is not
/// the currently-documented tool for it either, and the stdlib's own newer cases use
/// `@abi` for the Swift-ABI-mangling scenario specifically). `@_extern(c:)` is the
/// mechanism the reference doc actually names for declaring a plain C-ABI function
/// with no header or module: exactly this file's situation. Needs
/// `-enable-experimental-feature Extern` on Swift 6.3.3 (confirmed: `@_extern(c:)`
/// fails to parse without it). Verified — in two throwaway packages built
/// specifically to test this before adopting it here, not assumed — that the flag
/// does NOT propagate as a requirement to a consumer: an ordinary downstream target,
/// AND a `.testTarget` reaching the declaration through `@testable import` (this
/// package's own exact shape), both built and ran correctly with zero flags of their
/// own. `Package.swift`'s own comment on the `CtrlKD` target has the full account,
/// including the two alternatives considered and rejected: `Compression.framework`
/// (`COMPRESSION_ZLIB`) is Apple's OWN encoder, not zlib — it does not claim
/// byte-identical output to Python's `zlib.compress`, which is the entire point of
/// this file, so it was never a candidate; and restructuring around a framework
/// intermediary would be solving a Tuist/Xcode module-hand-off bug this package
/// already fully mitigates with one linker flag — disproportionate machinery for a
/// problem that's already closed.
///
/// THE ONE REAL PITFALL, either mechanism: NEITHER `@_silgen_name` NOR `@_extern(c:)`
/// gets any compiler ABI CHECKING — a signature typo (wrong pointer arity, wrong
/// integer width) would compile cleanly and fail, or worse silently corrupt, at
/// runtime, not at build time. The round-trip tests below (`PixTests.swift`'s
/// `zlibCompressRoundTripsViaRealInflate`, the large-payload variant, and the
/// hardcoded-hex Python-oracle pin `zlibCompressMatchesPythonZlibByteExactly`) are
/// the TRIPWIRE for that risk, not a formality — they exercise these exact three
/// declarations, on whatever platform runs the suite, every time.
///
/// TYPE CARE: zlib's own `uLong`/`uLongf` are typedef'd to C's `unsigned long`, which
/// is 64-bit on every LP64 platform this package targets — macOS (arm64 and x86_64)
/// and Linux (x86_64 and aarch64) are BOTH LP64, so Swift's `UInt` (the platform's
/// native word size, also 64-bit on every one of those) is the exactly-matching type
/// on both, not a coincidental same-size stand-in. `Bytef` is `unsigned char`, i.e.
/// `UInt8`. (Windows' LLP64, where `unsigned long` is 32-bit, would break this
/// assumption — this package does not target Windows.)
@_extern(c, "compress2")
func c_compress2(_ dest: UnsafeMutablePointer<UInt8>, _ destLen: UnsafeMutablePointer<UInt>,
                 _ source: UnsafePointer<UInt8>, _ sourceLen: UInt, _ level: Int32) -> Int32

@_extern(c, "compressBound")
func c_compressBound(_ sourceLen: UInt) -> UInt

@_extern(c, "uncompress")
func c_uncompress(_ dest: UnsafeMutablePointer<UInt8>, _ destLen: UnsafeMutablePointer<UInt>,
                  _ source: UnsafePointer<UInt8>, _ sourceLen: UInt) -> Int32

/// zlib's own `Z_OK` (0) — no header is imported to read the real constant from, so
/// this is restated here rather than imported.
private let zOK: Int32 = 0

func zlibCompress(_ data: [UInt8], level: Int32 = 6) -> [UInt8] {
    if data.isEmpty {
        // `c_compress2` on a zero-length source still needs a valid pointer; build
        // the trivial one-byte-array case through the same call rather than special-
        // casing an empty buffer's pointer arithmetic.
        return zlibCompressViaLibz([0], sourceLenOverride: 0, level: level)
    }
    return zlibCompressViaLibz(data, sourceLenOverride: nil, level: level)
}

private func zlibCompressViaLibz(_ data: [UInt8], sourceLenOverride: UInt?, level: Int32) -> [UInt8] {
    let sourceLen = sourceLenOverride ?? UInt(data.count)
    var destLen = c_compressBound(sourceLen)
    var dest = [UInt8](repeating: 0, count: Int(destLen))
    let result = dest.withUnsafeMutableBufferPointer { destBuf -> Int32 in
        data.withUnsafeBufferPointer { srcBuf -> Int32 in
            c_compress2(destBuf.baseAddress!, &destLen, srcBuf.baseAddress!, sourceLen, level)
        }
    }
    // Z_OK (0) is the only success code `compress2` returns; a real allocation failure
    // or a level outside -1...9 are the only other paths, neither reachable with a
    // `compressBound`-sized buffer and this module's own fixed level arguments (6, 9).
    // Falling back to the pure-Swift writer rather than crashing keeps a theoretical
    // future misuse (an out-of-range level) non-fatal.
    guard result == zOK else { return zlibCompressStored(data) }
    return Array(dest[0..<Int(destLen)])
}

/// Adler-32 checksum (RFC 1950 §9), the zlib stream's own trailer — used only by
/// `zlibCompressStored` below now that `zlibCompress` links real zlib, which computes
/// its own trailer internally.
func adler32(_ data: [UInt8]) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    let modAdler: UInt32 = 65521
    // Chunked so `a`/`b` never risk overflowing UInt32 before a mod reduction — 5552 is
    // the standard largest safe chunk length for this modulus (the well-known Adler-32
    // implementation constant: 255 * 5552 * 5552 < 2^32).
    var i = 0
    while i < data.count {
        let end = Swift.min(i + 5552, data.count)
        for byte in data[i..<end] {
            a += UInt32(byte)
            b += a
        }
        a %= modAdler
        b %= modAdler
        i = end
    }
    return (b << 16) | a
}

/// One STORED DEFLATE block (RFC 1951 §3.2.4): a 3-bit header (BFINAL + BTYPE=00) padded
/// out to the next byte boundary, then LEN/NLEN (2 bytes each, little-endian — NLEN is
/// LEN's one's complement, the format's own self-check), then the raw bytes verbatim.
/// Stored blocks are capped at 65535 bytes each, so a longer input is split across
/// several consecutive blocks, only the last carrying BFINAL=1.
private func deflateStored(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    let maxBlock = 65535
    var offset = 0
    if data.isEmpty {
        // One empty final block: BFINAL=1, BTYPE=00, byte-aligned, LEN=0/NLEN=0xFFFF.
        out.append(0x01)
        out.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        return out
    }
    while offset < data.count {
        let end = Swift.min(offset + maxBlock, data.count)
        let isFinal = end == data.count
        // BFINAL in bit 0, BTYPE (00 = stored) in bits 1-2 -- the rest of this byte is
        // padding, per spec, and stored blocks then start the NEXT field byte-aligned.
        out.append(isFinal ? 0x01 : 0x00)
        let len = UInt16(end - offset)
        let nlen = ~len
        out.append(UInt8(len & 0xFF))
        out.append(UInt8(len >> 8))
        out.append(UInt8(nlen & 0xFF))
        out.append(UInt8(nlen >> 8))
        out.append(contentsOf: data[offset..<end])
        offset = end
    }
    return out
}

/// A minimal, pure-Swift zlib-COMPATIBLE stream writer — the no-dependency fallback
/// kept alongside `zlibCompress`'s real-`libz` path (b24 round 21b). DISCLOSED SCOPE
/// CUT: writes STORED (uncompressed) DEFLATE blocks only — no LZ77/Huffman coding. The
/// output is byte-for-byte a VALID zlib stream (correct header, correct Adler-32
/// trailer, correct block framing) that any real zlib/PNG/PDF reader decodes correctly;
/// it is simply larger than a real compressor's, and NOT byte-identical to
/// `zlib.compress`'s own output (only `zlibCompress` above, backed by the real
/// library, is). Not called from anywhere in `Sources/` by default now that `libz` is
/// always linked directly (`c_compress2` above) — kept as a working, tested
/// alternative for a hypothetical future target with no system zlib available.
func zlibCompressStored(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01]
    out.append(contentsOf: deflateStored(data))
    let checksum = adler32(data)
    out.append(UInt8((checksum >> 24) & 0xFF))
    out.append(UInt8((checksum >> 16) & 0xFF))
    out.append(UInt8((checksum >> 8) & 0xFF))
    out.append(UInt8(checksum & 0xFF))
    return out
}
