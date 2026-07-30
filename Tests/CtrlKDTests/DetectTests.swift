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
    let data = ws7Block(0x00) + ws7Block(0x11, payload: [0x02]) + Array("Chapter One".utf8) +
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
