import Testing
@testable import CtrlKD

@Test func detectWS4() {
    // Mirrors test_detect_ws4.
    let data = ws4Text("hello there friendly world this line wraps") + SOFT +
               ws4Text("and continues here") + HARD + [0x1a]
    #expect(detect(data).variant == .ws4)
}

@Test func detectPrintstream() {
    // Mirrors test_detect_printstream.
    let data = Array("Line one of printed page\r\nLine two\r\nLine three\r\n".utf8) + [0x1a]
    #expect(detect(data).variant == .printstream)
}

@Test func detectBinary() {
    // Mirrors test_detect_binary: bytes(range(256)) * 4.
    let byteRange = (0...255).map { UInt8($0) }
    let data = byteRange + byteRange + byteRange + byteRange
    #expect(detect(data).variant == .binary)
}

@Test func detectWS5PlusFromSymmetricBlocks() {
    // Mirrors the 1D-symmetric-block shape from test_ws7_heading_and_softpage; only
    // detect()'s classification is asserted here, since parse_ws() isn't ported yet.
    let data = ws7Block(0x00) + styleRef(2) + Array("Chapter One".utf8) +
               HARD + HARD + Array("Body text of the chapter.".utf8) + HARD +
               ws7Block(0x0B) + Array("Next page text.".utf8) + HARD
    #expect(detect(data).variant == .ws5plus)
}

@Test func tinyFileNotMisdetectedAsWS4() {
    // Mirrors test_tiny_file_not_misdetected_as_ws4: regression guard for the
    // max(1, len(core)//20) fix — without it, `hi >= 0` was always true for tiny files.
    let data = Array("ab cd ef\r\n".utf8) + [0x1a]
    #expect(detect(data).variant != .ws4)
}

@Test func highbitBinaryNotWS4() {
    // Mirrors test_highbit_binary_not_ws4: binary with high-bit density but low text%
    // (e.g. game data) is not WordStar.
    let prefix: [UInt8] = [0x2b, 0x2c, 0x28, 0x14, 0x20, 0x2f, 0x30, 0x02] // b'+,(\x14 /0\x02'
    let block: [UInt8] = [0x88, 0x99, 0xaa, 0x07, 0x01]
    var data = prefix
    for _ in 0..<40 { data += block }
    data += Array("some ascii".utf8)
    data += Array(repeating: 0x00, count: 150)
    #expect(detect(data).variant == .binary)
}

@Test func bareEOFFindsTruePaddingRunNotFirstStrayByte() {
    // Mirrors test_bare_eof_finds_true_padding_run_not_first_stray_byte. detect() used to
    // truncate at the FIRST 0x1A anywhere in the file — but 0x1A occurs legitimately
    // INSIDE real WordStar content (WSFORMAT.TXT 1Dh: "Symmetrical sequences can contain
    // any character including 1AH"), not only as the trailing ^Z padding WordStar writes
    // to fill a CP/M sector. REF/ROUNDED.BRD (Sawyer WS7 preservation corpus) is a genuine
    // 6.4 KB document whose first 0x1A sits at offset 48 — an in-content control byte
    // inside a real symmetrical sequence — while its true trailing padding run does not
    // start until offset 6324. Truncating at the first occurrence judged the file on 48
    // bytes ("89% text but no structure") and parse refused it outright.
    let early = Array("abc\u{1a}def".utf8)
    let run = Array(repeating: UInt8(0x1a), count: 10)
    let filler = Array("more real content after the stray byte".utf8)
    let data = early + filler + run
    #expect(bareEOF(data) == early.count + filler.count)

    // A file with NO padding run at all — just one bare 0x1A — still treats that single
    // byte as EOF (a document can be genuinely truncated right at a real, unpadded EOF
    // marker; this must not regress).
    let unpadded = Array("plain content ending right here".utf8) + [0x1a]
    #expect(bareEOF(unpadded) == unpadded.count - 1)

    // A wrapped extended character's middle byte is never mistaken for EOF, padding run
    // or not (ASCIITAB.WS charts every control code, including <1B 1A 1C>).
    let wrappedOnly: [UInt8] = [0x1b, 0x1a, 0x1c] + Array("more text with no bare 0x1A at all".utf8)
    #expect(bareEOF(wrappedOnly) == nil)
}

@Test func detectAndParseSurviveInContentEOFByteBeforeTruePaddingRun() throws {
    // Mirrors test_detect_and_parse_survive_in_content_0x1A_before_true_padding_run.
    // Synthetic reproduction of the ROUNDED.BRD shape (real corpus fixtures are not
    // shipped): a short WS4 header, ONE in-content 0x1A that is not EOF, then substantial
    // real ws4 prose, then a genuine trailing padding run. Before the fix, detect()
    // truncated at the in-content byte and saw only the 18-byte header — "72% text but no
    // structure", parse threw ParseError. After the fix, the whole document is in scope.
    let header = Array(".pl64\r\n.mt1\r\n".utf8) + [0x00, 0x00, 0x0f, 0x00, 0x00]
    let stray: [UInt8] = [0x1a]
    let body = ws4Text("hello there friendly world this line wraps") + SOFT +
               ws4Text("and continues here across several more words") + SOFT +
               ws4Text("a third wrapped line completes the paragraph") + HARD
    let pad = Array(repeating: UInt8(0x1a), count: 10)
    let data = header + stray + body + pad

    #expect(detect(data).variant == .ws4)

    let doc = try parse(data)
    #expect(doc.roundtrip?.era == "ws4")
    let lines = doc.blocks.flatMap { $0.lines.map { $0.text() } }
    // all three real prose lines survived — none silently dropped with the in-content byte
    #expect(lines.contains { $0.contains("friendly world") })
    #expect(lines.contains { $0.contains("continues here") })
    #expect(lines.contains { $0.contains("completes the paragraph") })
}

@Test func detectGenuineTruncationAtRealEOFIsUnaffected() throws {
    // Mirrors test_detect_genuine_truncation_at_real_eof_is_unaffected. A document with NO
    // padding run — just one bare 0x1A right after its real content ends — must still
    // detect and parse exactly as before this fix: bareEOF's run-detection must not change
    // behavior when there is no run to find.
    let data = ws4Text("hello there friendly world this line wraps") + SOFT +
               ws4Text("and continues here") + HARD + [0x1a]
    #expect(detect(data).variant == .ws4)
    let doc = try parse(data)
    #expect(doc.roundtrip?.era == "ws4")
}

/// A synthetic executable-shaped blob: about half text-like bytes, half high bytes,
/// with `0x1D` / `<1B ? 1C>` / `<8D 0A>` appearing only at the rate chance puts them
/// in random data. No part of any real binary — the shape is reproduced, not the file.
///
/// Deterministic: a fixed-seed SplitMix64 stands in for Python's `random.Random(seed)`
/// (the stdlib's own generator is not seedable, and a test that classifies noise has to
/// classify the SAME noise every run).
private func chanceNoiseBinary(size: Int = 1 << 18, seed: UInt64 = 4931) -> [UInt8] {
    var state = seed
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    let asciiPool: [UInt8] = (0x20...0x7E).map { UInt8($0) }   // usage strings, symbol names
    // Machine code and padding: control bytes, plus the high bytes that are STILL
    // control-shaped once detect() masks bit 7 (that masking is why a blob of plain
    // 0x80..0xFF scores 85% text-like and would prove nothing). 0x1A is left out so the
    // blob has no EOF to be truncated at. 0x1B/0x1C/0x8D are left out too: this pool is
    // ~60 values wide, so a random draw would mint wrapped triples and soft returns FAR
    // above the rate real random bytes do. Those two sequences are injected below, at
    // the rate a genuine binary shows them.
    var noisePool: [UInt8] = (0x00...0x1F).map { UInt8($0) }.filter { ![0x1a, 0x1b, 0x1c].contains($0) }
    noisePool += (0x80...0x9F).map { UInt8($0) }.filter { $0 != 0x8d }
    noisePool += [0xff]
    var blob: [UInt8] = []
    blob.reserveCapacity(size)
    while blob.count < size {
        let ascii = Double(next() >> 11) * (1.0 / 9007199254740992.0) < 0.45
        let pool = ascii ? asciiPool : noisePool
        blob.append(pool[Int(next() % UInt64(pool.count))])
    }
    // chance rates, measured on the real thing: one 0x1D per 256 bytes, one two-byte
    // sequence per 65536
    for off in stride(from: 0, to: size, by: 256) { blob[off] = 0x1d }
    for off in stride(from: 1000, to: size, by: 1 << 16) {   // 4 wrapped triples in 256 KB
        blob[off] = 0x1b; blob[off + 1] = 0x41; blob[off + 2] = 0x1c
    }
    for off in stride(from: 2000, to: size, by: 1 << 16) {   // 4 soft returns in 256 KB
        blob[off] = 0x8d; blob[off + 1] = 0x0a
    }
    return Array(blob[0..<size])
}

@Test func detectRefusesABinaryWhose1DBytesAreChance() {
    // Mirrors test_detect_refuses_a_binary_whose_1d_bytes_are_chance (job-493): a
    // Windows executable is not a WordStar document.
    //
    // detect() used to count BARE 0x1D BYTES and treat two of them as "WS5+ machinery
    // regardless of anything else". Byte 0x1D turns up by chance about once per 256
    // bytes, so a 2 MB binary carries thousands: dosbox-x.exe reported 5,990 of them,
    // detected as ws5+ at 45% text, and rendered to a 64 MB PDF. Four executables in
    // the archive were accepted this way in b28.
    //
    // The evidence has to be STRUCTURAL. A block is 1D <count> <cmd> <payload> <count>
    // 1D with the counts matching, which random bytes essentially never satisfy — so
    // the same file counts 0. The two-byte sequences (<1B ? 1C> wrapped extended
    // characters, <8D 0A> soft returns) can't be reframed, so they carry a density
    // floor instead: chance alone puts one every 65536 bytes, and evidence at or below
    // the noise floor is not evidence.
    let data = chanceNoiseBinary()
    // the byte tally that fooled it
    #expect(data.reduce(into: 0) { n, b in if b == 0x1d { n += 1 } } >= 200)
    #expect(countSymmetricBlocks(data) == 0)          // not one closes
    let det = detect(data)
    #expect(det.symmetricBlocks1D == 0)
    // the verdict must come from the structure being absent, NOT from the text floor:
    // this blob clears 40% text-like exactly as the .exe did
    #expect(det.textPct >= 40)
    #expect(det.variant == .binary)
    // ... and the rule is not merely harder to reach: ONE well-formed block in a
    // document still settles it (51 archive files — PLAYS.DOC, the MAILLIST envelope
    // layouts, the WS7 tag files — carry exactly one)
    var doc: [UInt8] = Array(".op\r\n".utf8) + Array("Ordinary prose that wraps.".utf8) + SOFT
    doc += ws7Block(0x0B) + Array("More prose.".utf8) + HARD
    doc += [0x1a]
    let real = detect(doc)
    #expect(real.symmetricBlocks1D == 1)
    #expect(real.variant == .ws5plus)
}
