import Foundation
import Testing
@testable import CtrlKD

/// wschange: the WSCHANGE .PAT interpreter, checked against the real Sawyer-archive
/// dumps — a known-answer gauntlet, because the CLI page presets ('default' = factory,
/// 'sawyer') were HAND-derived from these very bytes; the interpreter must reproduce
/// conclusions already trusted, not merely run without crashing. Port of
/// `tests/test_wschange.py`.
///
/// The `.PAT` fixtures (`PRISTINE.PAT`, `DEFAULT.PAT`, etc.) sit directly at the Sawyer
/// archive's OWN top level — verified against both the vendored corpus copy and the full
/// original archive, neither of which wraps them in a `WS/` subdirectory (that wrapper was
/// a stale assumption from an old local layout, corrected here). Gated on
/// `CTRLKD_SAWYER_ARCHIVE` (Tier 2/3 contract, `docs/TESTING.md`), never `CTRLKD_PRIVATE_CORPUS`
/// — these are Sawyer-archive documents, not Jon's private corpus.
///
/// Unset: every test below is a recorded SKIP (`.enabled(if:)`), never a silent pass. Set but
/// a named fixture missing from that copy of the archive: the test FAILS loud naming the path
/// — a corpus that's present but incomplete is a real bug, not something to wave through.

/// The ONE place the archive path lives (private-local; keep it a single constant for
/// future scrubbing).
let sawyerArchivePath = (ProcessInfo.processInfo.environment["CTRLKD_SAWYER_ARCHIVE"]
    .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) ?? ""

/// `true` exactly when `CTRLKD_SAWYER_ARCHIVE` is set — every `.PAT`/Sawyer-archive test in
/// this file cites this via `.enabled(if:)` so an unset var is a recorded Skip, not a pass.
let sawyerArchiveArmed = !sawyerArchivePath.isEmpty

let sawyerArchiveSkipReason: Comment =
    "sawyer-archive-gated: CTRLKD_SAWYER_ARCHIVE unset — see docs/TESTING.md"

/// Planning #192 (2026-09-05): the vendored `private-corpus` this repo's own
/// `CTRLKD_SAWYER_ARCHIVE` is documented to point at (that repo's README) is DOCUMENTS ONLY
/// by Jon's ruling ("CAN ONLY be documents. Nothing else.") — `.PAT` files (WSCHANGE's own
/// patch-point interpreter tables, not WordStar documents) are one of the named excluded
/// categories, same call as macros/dictionaries/fonts/printer-defs, so every `.PAT` fixture
/// this file needs is deliberately absent from that copy, permanently, not incompletely.
/// Checked once via `PRISTINE.PAT`'s own presence (one probe settles it for the whole
/// suite) rather than treating each individual missing `.PAT` as the "armed but broken"
/// bug `MissingSawyerFixture` exists to catch — arming against a full, untrimmed Sawyer
/// download (which still carries `.PAT` files) runs this suite for real, exactly as
/// before.
let sawyerArchiveHasPATFixtures = sawyerArchiveArmed
    && FileManager.default.fileExists(atPath: sawyerArchivePath + "/PRISTINE.PAT")

let sawyerArchivePATSkipReason: Comment =
    "sawyer-archive .PAT fixtures unavailable: the vendored corpus is documents-only (planning #192, 2026-09-05 ruling) and does not carry .PAT files by design — arm CTRLKD_SAWYER_ARCHIVE against a full, untrimmed Sawyer download to run this suite"

/// Thrown by `patFixture` when the archive is armed but the named file isn't in it — a hard
/// failure (never a skip): an armed-but-incomplete corpus is a real bug.
struct MissingSawyerFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "CTRLKD_SAWYER_ARCHIVE=\(sawyerArchivePath) is set but \(path) is missing from that copy of the archive."
    }
}

private func patFixture(_ name: String) throws -> [UInt8] {
    let path = sawyerArchivePath + "/" + name + ".PAT"
    guard let data = FileManager.default.contents(atPath: path) else {
        throw MissingSawyerFixture(path: path)
    }
    return [UInt8](data)
}

// ---------------------------------------------------------- known answers

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func pristineReproducesTheFactoryPage() throws {
    // PRISTINE.PAT is the unmodified factory dump: patPageSettings must land on
    // WordStar's own documented defaults — .mt 3 lines (0.5in), .mb 8 lines (1.33in),
    // .po 0.8in = 8.0 columns, .pl 66 lines, .hm/.fm 2 lines, .lh 8/48in — i.e. exactly
    // what an EMPTY settings value means to the machine layer ('default' preset = {}).
    let data = try patFixture("PRISTINE")
    let page = patPageSettings(try parsePAT(data))
    #expect(abs(page["mt_lines"]! - 3.0) < 1e-6)
    #expect(abs(page["mb_lines"]! - 8.0) < 1e-6)
    #expect(abs(page["po_cols"]! - 8.0) < 1e-6)
    #expect(abs(page["pl_lines"]! - 66.0) < 1e-6)
    #expect(abs(page["hm_lines"]! - 2.0) < 1e-6)
    #expect(abs(page["fm_lines"]! - 2.0) < 1e-6)
    #expect(abs(page["lh_48"]! - 8.0) < 1e-6)
}

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func defaultReproducesTheSawyerPreset() throws {
    // DEFAULT.PAT is Sawyer's machine: the geometry must equal the CLI's 'sawyer'
    // preset (mt 1195/1440in*6, mb 6 lines, po 7 columns — those literals ARE the
    // preset). Everything the preset leaves alone must still read factory.
    let data = try patFixture("DEFAULT")
    let page = patPageSettings(try parsePAT(data))
    #expect(abs(page["mt_lines"]! - 1195.0 / 1440.0 * 6.0) < 1e-6)
    #expect(abs(page["mb_lines"]! - 6.0) < 1e-6)
    #expect(abs(page["po_cols"]! - 7.0) < 1e-6)
    // unchanged-from-factory fields (decode doc: only mt/mb/po differ)
    #expect(abs(page["pl_lines"]! - 66.0) < 1e-6)
    #expect(abs(page["hm_lines"]! - 2.0) < 1e-6)
    #expect(abs(page["fm_lines"]! - 2.0) < 1e-6)
    #expect(abs(page["lh_48"]! - 8.0) < 1e-6)
}

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func fullDumpsShareOneLabelSet() throws {
    // Both full dumps carry 294 label LINES — but UDATE appears twice (lines 1 and 559,
    // identical bytes: WSCHANGE stamps the dump date at both ends), so the decode doc's
    // "294 labels" is 293 unique names in the mapping.
    let pri = try parsePAT(try patFixture("PRISTINE"))
    let saw = try parsePAT(try patFixture("DEFAULT"))
    #expect(Set(pri.keys) == Set(saw.keys))
    #expect(pri.count == 293 && saw.count == 293)
    // struct sizes the decode doc derives from PATCH.LST (INISIZ = 68; ten 74-byte .RR
    // records + 1 reserved = 741)
    for pat in [pri, saw] {
        #expect(pat["INIEDT"]?.count == 68)
        #expect(pat["RLRINI"]?.count == 741)
    }
}

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func partialPatchSetsParseWithTrueCounts() throws {
    // Grep-estimates in the brief were PATHS 55, NOTYPE 25, ALL 3; the TRUE parsed label
    // counts differ for those three because the estimates counted continuation lines as
    // labels. Asserting reality.
    for (name, labels) in [("WSMIN", 4), ("VCOLOR", 1), ("PATHS", 40),
                           ("NOTYPE", 2), ("ALL", 2)] {
        let data = try patFixture(name)
        #expect(try parsePAT(data).count == labels, "\(name)")
    }
}

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func partialsAreSubsetsOfTheFullDump() throws {
    // Subset semantics: a partial patch set is a mapping of only the labels it names —
    // every one of which exists in the full dump's 293.
    let full = Set(try parsePAT(try patFixture("PRISTINE")).keys)
    for name in ["WSMIN", "VCOLOR", "PATHS", "NOTYPE", "ALL"] {
        let data = try patFixture(name)
        #expect(Set(try parsePAT(data).keys).isSubset(of: full), "\(name)")
    }
}

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func partialWithoutINIEDTSaysNothingAboutThePage() throws {
    // WSMIN.PAT carries no INIEDT: the machine layer must contribute NO page overrides,
    // not factory values — [:] is "this dump is silent", which is not the same claim as
    // "this dump says factory".
    let data = try patFixture("WSMIN")
    #expect(patPageSettings(try parsePAT(data)).isEmpty)
}

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func notypeQuotedStringsReassemble() throws {
    // NOTYPE.PAT is the corpus's only use of quoted-string items: one block of 23
    // three-char extension strings plus a 0x00 terminator, wrapped one string per
    // continuation line. The known answer for the quoted path: 70 bytes, first and last
    // extensions where they belong.
    let data = try patFixture("NOTYPE")
    let block = try #require(try parsePAT(data)["NOTYPE"])
    #expect(block.count == 70)
    #expect(block.starts(with: bytes("'''")))
    #expect(block.suffix(4) == ArraySlice(bytes("XLS") + [0x00]))
}

@Test(.enabled(if: sawyerArchiveHasPATFixtures, sawyerArchivePATSkipReason))
func rulerTabsReproduceTheFactoryRuler() throws {
    // .RR 0 in BOTH dumps (byte-identical per the decode doc — Sawyer never touched his
    // ruler): 11 stops every 900 HMI = every 5 columns.
    let want = (1...11).map { 5.0 * Double($0) }
    for name in ["PRISTINE", "DEFAULT"] {
        let data = try patFixture(name)
        let tabs = patRulerTabs(try parsePAT(data))
        #expect(tabs.count == want.count, "\(name)")
        for (a, b) in zip(tabs, want) {
            #expect(abs(a - b) < 1e-6, "\(name)")
        }
    }
}

// ---------------------------------------------------------- format corners
// Synthetic bytes — no archive needed below this line.

@Test func continuationLinesReassembleInOrder() throws {
    let pat = try parsePAT(bytes("ABC=01,02\r\n=03,04\r\n=05\r\nDEF=FF\r\n"))
    #expect(pat == ["ABC": [0x01, 0x02, 0x03, 0x04, 0x05], "DEF": [0xFF]])
}

@Test func lfOnlyTrailingWhitespaceAndBlankLines() throws {
    let pat = try parsePAT(bytes("ABC=01,02  \n\n=03\t\nDEF=0A \n"))
    #expect(pat == ["ABC": [0x01, 0x02, 0x03], "DEF": [0x0A]])
}

@Test func emptyContinuationAndTrailingComma() throws {
    // The real full dumps end PRNID with a bare '=' line; tolerate both that and a
    // trailing comma without inventing a byte for either.
    let pat = try parsePAT(bytes("ABC=01,\r\n=\r\n=02\r\n"))
    #expect(pat == ["ABC": [0x01, 0x02]])
}

@Test func ctrlZPaddingIsDiscarded() throws {
    let pat = try parsePAT(bytes("ABC=41\r\n") + [0x1A, 0x1A, 0x1A, 0x1A])
    #expect(pat == ["ABC": [0x41]])
}

@Test func quotedItemsMixWithHexAndKeepCommas() throws {
    // No corpus string contains a comma, but splitting inside quotes would be silent
    // corruption, so the tokenizer honours them anyway.
    let pat = try parsePAT(bytes("X=01,\"A,B\",02\r\n"))
    #expect(pat == ["X": [0x01] + bytes("A,B") + [0x02]])
}

@Test func repeatedLabelRestartsLastWins() throws {
    // The real dumps repeat UDATE (identical bytes); a repeat RESTARTS the value rather
    // than appending, matching re-apply semantics.
    let pat = try parsePAT(bytes("UDATE=01\r\nOTHER=02\r\nUDATE=03\r\n"))
    #expect(pat == ["UDATE": [0x03], "OTHER": [0x02]])
}

@Test func malformedLinesRaiseRatherThanGuess() {
    #expect(throws: PATError.self) { _ = try parsePAT(bytes("no equals sign here\r\n")) }
    #expect(throws: PATError.self) { _ = try parsePAT(bytes("ABC=GG\r\n")) }     // not hex
    #expect(throws: PATError.self) { _ = try parsePAT(bytes("ABC=123\r\n")) }    // 3 digits
    #expect(throws: PATError.self) { _ = try parsePAT(bytes("=01\r\n")) }        // continuation first
}

@Test func missingBlocksYieldEmptyInterpretations() {
    #expect(patPageSettings([:]).isEmpty)
    #expect(patRulerTabs([:]).isEmpty)
    #expect(patRulerTabs(["RLRINI": [UInt8](repeating: 0, count: 10)]).isEmpty)  // short
}

@Test func truncatedINIEDTYieldsOnlyTheFieldsItCarries() {
    // 0x16 bytes covers mt (rel 0x14, LE16) and nothing after it: a damaged dump
    // reports what it has instead of guessing the rest.
    var ie = [UInt8](repeating: 0, count: 0x16)
    ie[0x14] = UInt8(720 & 0xFF)
    ie[0x15] = UInt8(720 >> 8)
    let page = patPageSettings(["INIEDT": ie])
    #expect(page.count == 1)
    #expect(abs((page["mt_lines"] ?? 0) - 3.0) < 1e-9)
}
