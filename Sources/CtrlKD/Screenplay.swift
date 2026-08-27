/// Screenplay-format detection — b24 round 20b (slate item 13). Direct port of
/// `detect_screenplay_blocks`/`_SCREENPLAY_SLUGLINE_RE`/`_block_has_slugline` (core.py).
///
/// A screenplay slugline — WSFORMAT gives no dot command for one; real screenplays
/// convention it ALL CAPS at a line's own start, an optional 1-4-digit scene number, and
/// an optional WordStar merge-var scene marker (`&n/s&`, `&scene&`, ...) sitting just
/// before it (the slate's "merge-var scene markers" signal folded into the SAME anchor
/// rather than treated as an independent trigger — see `detectScreenplayBlocks`'s own
/// doc comment for why). Case-SENSITIVE: the convention is uppercase; a lowercase
/// "int." in ordinary prose must never match.
///
/// Hand-rolled rather than a regex engine (this project imports none in `Sources/`) —
/// ports the exact grammar of `_SCREENPLAY_SLUGLINE_RE`:
///
///     ^[ \t]*\d{0,4}[ \t]*(?:&[^&\r\n]{1,24}&[ \t]*)?
///     (?:INT\.|EXT\.|INT\.?/EXT\.|I/E\.)[ \t]
///
/// The alternation is tried in the SAME left-to-right order Python's own backtracking
/// regex would: "INT." is tried first, and if it matches but the very next character
/// isn't a space/tab (e.g. the text is actually "INT./EXT. "), the attempt is abandoned
/// and the NEXT alternative is tried from the same position — not an overall failure.
func matchesScreenplaySlugline(_ text: [Character]) -> Bool {
    let n = text.count
    func isSpaceTab(_ c: Character) -> Bool { c == " " || c == "\t" }
    var i = 0
    // ^[ \t]*
    while i < n, isSpaceTab(text[i]) { i += 1 }
    // \d{0,4}
    var digits = 0
    while i < n, digits < 4, text[i].isASCII, text[i].isNumber { i += 1; digits += 1 }
    // [ \t]*
    while i < n, isSpaceTab(text[i]) { i += 1 }
    // (?:&[^&\r\n]{1,24}&[ \t]*)? -- optional; only advances `afterPrefix` on a genuine
    // closing '&' within the 1-24 character budget.
    var afterPrefix = i
    if i < n, text[i] == "&" {
        var j = i + 1
        var count = 0
        while j < n, count < 24, text[j] != "&", text[j] != "\r", text[j] != "\n" {
            j += 1
            count += 1
        }
        if count >= 1, j < n, text[j] == "&" {
            var k = j + 1
            while k < n, isSpaceTab(text[k]) { k += 1 }
            afterPrefix = k
        }
    }
    func tryLiteral(_ lit: [Character]) -> Bool {
        guard afterPrefix + lit.count < n else { return false }   // room for the literal + trailing separator
        for (k, c) in lit.enumerated() where text[afterPrefix + k] != c { return false }
        return isSpaceTab(text[afterPrefix + lit.count])
    }
    for lit in [Array("INT."), Array("EXT."), Array("INT./EXT."), Array("INT/EXT."), Array("I/E.")] {
        if tryLiteral(lit) { return true }
    }
    return false
}

/// b26-modern item 3 (screenplay ruling, BUILD-SLATES.md item 27, Jon's decided
/// ruling): two line SHAPES that only matter INSIDE a screenplay-detected region
/// (`detectScreenplayBlocks` — gated the same way the emitters' own verse-forcing
/// already is; a WordStar screenplay page-number marker or a numbered scene-list entry
/// elsewhere in an ordinary document must never be swept up by these).
///
/// A "page marker" line — SCRIPT.WS's own "1." sitting alone at the top of its
/// rendered screenplay page, real screenplay-software convention — is nothing but
/// whitespace and a bare 1-4 digit number (optional trailing period). Full-string
/// match, so a slugline's own leading scene number ("1     INT. ...") never qualifies
/// (it has letters after the digits on the same line). Port of ctrl-kd's
/// `_SCREENPLAY_PAGE_MARKER_RE = re.compile(r'[ \t]*\d{1,4}\.?[ \t]*$')`, matched with
/// `.match` (which, with a trailing `$` and no embedded newline in a single Line's
/// text, is a full-string match).
func matchesScreenplayPageMarker(_ text: [Character]) -> Bool {
    let n = text.count
    func isSpaceTab(_ c: Character) -> Bool { c == " " || c == "\t" }
    var i = 0
    while i < n, isSpaceTab(text[i]) { i += 1 }
    var digits = 0
    while i < n, digits < 4, text[i].isASCII, text[i].isNumber { i += 1; digits += 1 }
    guard digits >= 1 else { return false }
    if i < n, text[i] == "." { i += 1 }
    while i < n, isSpaceTab(text[i]) { i += 1 }
    return i == n
}

/// A genuine slugline (anchored the SAME way `detectScreenplayBlocks` itself anchors a
/// scene) that also carries a RIGHT-HAND scene number — real screenplay convention
/// repeats the scene number at both margins of its own slugline. Only a slugline
/// actually shaped this way needs the non-wrap protection; a slugline with no trailing
/// number has nothing on its right edge to protect. Port of ctrl-kd's
/// `_SCREENPLAY_TRAILING_SCENE_NUM_RE = re.compile(r'[ \t]\d{1,4}[ \t]*$')`, matched
/// with `.search`: because the pattern is anchored at the string's end (`$`), a match
/// exists iff the string's own TRAILING digit run (after stripping trailing
/// spaces/tabs) is 1-4 digits long and immediately preceded by a literal space or tab
/// — any longer trailing digit run can never satisfy `\d{1,4}` at a position with a
/// space/tab directly before it (every position inside a longer digit run is itself
/// preceded by another digit, never a space/tab).
func matchesScreenplayTrailingSceneNumber(_ text: [Character]) -> Bool {
    var end = text.count
    while end > 0, text[end - 1] == " " || text[end - 1] == "\t" { end -= 1 }
    var start = end
    while start > 0, text[start - 1].isASCII, text[start - 1].isNumber { start -= 1 }
    let digitCount = end - start
    guard digitCount >= 1, digitCount <= 4, start > 0 else { return false }
    let prev = text[start - 1]
    return prev == " " || prev == "\t"
}

private func blockHasSlugline(_ block: Block) -> Bool {
    for line in block.lines {
        let text = Array(line.spans.map(\.text).joined())
        if matchesScreenplaySlugline(text) { return true }
    }
    return false
}

/// How many blocks a confirmed slugline's own scene REGION can grow across before the
/// detector gives up looking for a closing signal (the next slugline, or a heading).
/// Generous on purpose — see `detectScreenplayBlocks`'s own doc comment for the
/// false-positive argument that makes a large number here still safe. Port of
/// `_SCREENPLAY_MAX_REGION_BLOCKS`.
private let screenplayMaxRegionBlocks = 40

/// Block indices that read as part of a screenplay-formatted scene, for Modern's
/// verse-class (ladder-preserving) treatment. The ANCHOR is a genuine slugline
/// (`matchesScreenplaySlugline`); once found, its scene's REGION grows forward to cover
/// the centered-CHARACTER/indented-dialogue/parenthetical ladder and the action lines
/// around it, without separately re-checking each of THOSE blocks' own shape against
/// the other two named signals (centered-character-over-dialogue,
/// `.rr`/`.lm`/`.rm` churn) — Jon's own ruling when this was scoped: "a partial
/// detector (sluglines-only, say) that clears zero-FP beats a clever one that doesn't."
/// Region growth stops at the NEXT slugline (a new scene, covered by its own
/// iteration), a heading block, a pagebreak/condpage block, or
/// `screenplayMaxRegionBlocks` blocks, whichever comes first.
///
/// FALSE-POSITIVE ARGUMENT for why the region can afford to be broad: region-growing
/// NEVER RUNS at all in a document that never matched a slugline in the first place —
/// and the slugline pattern itself is corpus-swept (ctrl-kd, 2026-08-18, the full
/// 86-file Sawyer WS7 tree) to match EXACTLY ONE real document (SCRIPT.WS, an article
/// about scripting WordStar for screenplays, containing two worked-example scenes) and
/// nothing else. A false positive in the region logic is therefore only reachable
/// inside a document that independently, and separately, contains a real
/// slugline-shaped line — there is no path to one in ordinary prose. Port of
/// `detect_screenplay_blocks`.
func detectScreenplayBlocks(_ doc: Document) -> Set<Int> {
    var sluglineBi: Set<Int> = []
    for (bi, block) in doc.blocks.enumerated() where block.kind == .para && blockHasSlugline(block) {
        sluglineBi.insert(bi)
    }
    guard !sluglineBi.isEmpty else { return [] }
    var region: Set<Int> = []
    let n = doc.blocks.count
    for start in sluglineBi {
        region.insert(start)
        let end = min(n, start + 1 + screenplayMaxRegionBlocks)
        guard start + 1 < end else { continue }
        for bi in (start + 1)..<end {
            let b = doc.blocks[bi]
            if b.kind != .para || b.heading != 0 || sluglineBi.contains(bi) { break }
            region.insert(bi)
        }
    }
    return region
}
