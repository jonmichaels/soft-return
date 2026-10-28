// DotTimelines.swift
//
// One mechanism for every dot command whose effect runs forward from where it was read:
// `.pr or=`, `.mt`/`.mb`, `.pl`, `.hm`/`.fm`, `.po`, `.poe`/`.poo`, `.pn`, `.pn`/`.pg`/`.op`
// (the automatic page number) and `.l#`. Each used to be its own walk over
// `Document.dotPositions`, written out nine times with its own "last checkpoint at or
// before this block" lookup. A `Timeline` is that walk and that lookup, once; what stays
// per command is the small `reduce` closure (which commands count, what value they set)
// and the fallback the document's own page geometry gets when the walk found nothing.
//
// Every factory below keeps the exact behaviour of the walk it replaced, including the
// differences between them. Those differences are measured, not accidental, and are
// written down on each factory: whether block 0 is seeded and at what, what a document
// with no usable command reseeds from, whether a repeated value is a new entry, and
// whether the line index matters.
//
//   timeline         seed at block 0              reseed from doc.page when     new entry when
//   orTimeline       portrait                     never                         value changes
//   mtMbTimeline     doc.page mt/mb, else default never                         pair changes
//   plTimeline       default .pl (66)             no entry was added (*)        value changes
//   hmFmTimeline     default .hm/.fm (2/2)        no entry was added (*)        pair changes
//   poTimeline       default .po (8)              no entry was added (*)        value changes
//   parityPoTimeline none (empty = "never set")   never                         first, then on change
//   pnTimeline       1                            no `.pn` was accepted at all  every `.pn` (**)
//   pgnumTimeline    on                           never                         value changes
//   lineNumberingT.  off (nil)                    never                         value changes
//
//   (*) "No entry was added", which is NOT "the document has no such command": a command
//       that repeats the seed's own value adds no entry either, so the document's page
//       geometry replaces the seed in that case too. Kept as it was.
//   (**) Two `.pn` at the same position keep the later; one at the seed's position
//       replaces the seed. A repeated value still restarts the count.
//
// The line index matters only to `orTimeline` (via `at(_:consumed:)`), to RTF's section
// anchors, and to the page-position walk (`checkpointsByPage`) that reads `.pn` and the
// automatic-number entries.

/// The command name (upper-cased) and argument of one recorded dot command, by the same
/// `[A-Za-z]{1,3}` name grammar the parser uses; nil when the text does not parse as one.
extension DotPosition {
    var command: (name: String, arg: [UInt8])? {
        guard let (name, arg) = dotCommandNameAndArg(Array(text.utf8)) else { return nil }
        return (String(decoding: name.map(ASCII.upper), as: UTF8.self), arg)
    }
}

/// `.mt`/`.mb` in force, in lines.
struct MarginLines: Equatable {
    var mt: Double
    var mb: Double
}

/// `.mt`/`.mb`/`.pl` in force, in lines -- what a WS4 page's body height is made of.
struct BodyGeometry: Equatable {
    var mt: Double
    var mb: Double
    var pl: Double
}

/// `.hm`/`.fm` in force, in lines.
struct HeadFootLines: Equatable {
    var hm: Double
    var fm: Double
}

/// A value that a document's dot commands change as they are read, kept as the list of
/// places it changed, ascending. Entry 0 is the value before any command, except for a
/// timeline with no seed, which starts empty (`isEmpty`) and means "never set".
///
/// Each entry carries the POSITION it was read at (block, and how many of that block's
/// lines came before it). `at(_:)` answers by block alone unless it is given `consumed`.
struct Timeline<Value> {
    /// THE LINE INDEX (triage Q12, probes 2026-09-14) is `dotPositions`' own second
    /// field: how many of that block's lines came BEFORE the command. A block index alone
    /// is too coarse for a running head (triage Q9, `HFEvent.within`) and for a
    /// `.pn` or `.pr or=` for the same reason: WordStar stores one typed mid-paragraph
    /// between two of that paragraph's own physical lines, and `-HOLYMAC.WS` does exactly
    /// that -- its second `.pn0` sits immediately after "Charles Maher", the last line
    /// page 1 has room for. Read at block granularity it re-anchored the numbering ON
    /// page 1, which printed a `0` real WS7 does not print.
    struct Entry {
        var blockIndex: Int
        var lineIndex: Int
        var value: Value
    }

    private(set) var entries: [Entry]
    /// How many commands the `reduce` closure accepted, whether or not each one changed
    /// the value. Lets a caller tell "no such command anywhere" from "commands that all
    /// repeated the seed".
    private(set) var acceptedCommands = 0

    init(entries: [Entry]) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Each entry's `(blockIndex, lineIndex)`, for the page walk (`checkpointsByPage`).
    var positions: [(blockIndex: Int, lineIndex: Int)] {
        entries.map { (blockIndex: $0.blockIndex, lineIndex: $0.lineIndex) }
    }

    /// The value in force for a page opening at block `bi`: the LAST entry at or before
    /// it. Port of Python's `_or_at`/`_mt_mb_at`/`_pl_at`/`_hm_fm_at`/`_po_at`/`_pgnum_at`/
    /// `line_numbering_at`.
    ///
    /// `consumed` is how many lines of block `bi` EARLIER pages already took -- the
    /// paginator's own `readTally[bi]`. With it, an entry counts when it sits at or before
    /// this page's opening position, so a command further into the block than this page
    /// reached belongs to a later page. Without it (`nil`) the comparison is
    /// block-granular: every entry in block `bi` counts. Only the orientation timeline is
    /// asked with `consumed`; RTF's section spine asks it without, having already resolved
    /// each change to the paragraph boundary it can actually break at.
    ///
    /// An entry before block 0 or an unseeded timeline has no answer: ask `isEmpty` first,
    /// or use `atIfAny`.
    func at(_ bi: Int, consumed: Int? = nil) -> Value {
        var value = entries[0].value
        for entry in entries {
            if entry.blockIndex > bi { break }
            if entry.blockIndex == bi, let consumed, entry.lineIndex > consumed { break }
            value = entry.value
        }
        return value
    }

    /// `at(bi)`, or nil for a timeline that never had a command (`.poe`/`.poo`, where
    /// "never set" is a different answer from any value).
    func atIfAny(_ bi: Int) -> Value? {
        isEmpty ? nil : at(bi)
    }

    /// Replaces the seed -- for a document whose page geometry was set directly rather
    /// than through the parser, so no command in `dotPositions` speaks for it.
    mutating func reseed(_ value: Value) {
        entries[0].value = value
    }
}

extension Timeline where Value: Equatable {
    /// Seeded at `(0, 0)`; an accepted command makes a new entry only when it CHANGES the
    /// value. `reduce` gets the value in force and the command, and returns the new value,
    /// or nil to ignore the command.
    init(of doc: Document, seed: Value, reduce: (Value, DotPosition) -> Value?) {
        entries = [Entry(blockIndex: 0, lineIndex: 0, value: seed)]
        for dp in doc.dotPositions {
            guard let next = reduce(entries[entries.count - 1].value, dp) else { continue }
            acceptedCommands += 1
            if next != entries[entries.count - 1].value {
                entries.append(Entry(blockIndex: dp.blockIndex, lineIndex: dp.lineIndex,
                                     value: next))
            }
        }
    }

    /// No seed: starts empty, the first accepted command is always an entry, and a later
    /// one only when it differs from the last.
    init(unseededOf doc: Document, reduce: (DotPosition) -> Value?) {
        entries = []
        for dp in doc.dotPositions {
            guard let next = reduce(dp) else { continue }
            acceptedCommands += 1
            if entries.isEmpty || next != entries[entries.count - 1].value {
                entries.append(Entry(blockIndex: dp.blockIndex, lineIndex: dp.lineIndex,
                                     value: next))
            }
        }
    }
}

extension Timeline {
    /// Seeded at `(0, 0)`; EVERY accepted command is an entry, even one that repeats the
    /// value in force (a restart to a number already used still restarts). Two commands at
    /// the same position keep the later one, and one at the seed's own position replaces
    /// the seed rather than doubling it.
    init(restartingFrom doc: Document, seed: Value, reduce: (DotPosition) -> Value?) {
        entries = [Entry(blockIndex: 0, lineIndex: 0, value: seed)]
        for dp in doc.dotPositions {
            guard let next = reduce(dp) else { continue }
            acceptedCommands += 1
            let entry = Entry(blockIndex: dp.blockIndex, lineIndex: dp.lineIndex, value: next)
            let last = entries[entries.count - 1]
            if last.blockIndex == dp.blockIndex && last.lineIndex == dp.lineIndex {
                entries[entries.count - 1] = entry
            } else {
                entries.append(entry)
            }
        }
    }
}

extension Document {

    /// `[(blockIndex, lineIndex, orientation), ...]` in ascending order -- the `.pr or=`
    /// orientation IN FORCE from that position onward. Port of Python's `_or_checkpoints`
    /// (M31). Same `dotPositions` anchor and the same "block 0 is WordStar's own hardcoded
    /// default" contract as `plTimeline`, but with the LINE index kept, which
    /// `.pl`/`.po`/`.mt` discard.
    ///
    /// WHAT WAS WRONG. `.pr or=` was captured once, at parse time, into
    /// `doc.formatting.orientation` -- whatever value the file happened to set LAST. That is
    /// the same defect class `poCols`/`lead48` are already excluded from the document-level
    /// formatting record for; it simply never reached `.pr`. A file that asks for landscape on
    /// one page and portrait on the rest printed every page portrait, and the landscape page's
    /// content ran off the right edge of a sheet too narrow to hold it -- silently, because a
    /// viewer clips at the MediaBox without complaining.
    ///
    /// THE TIMING RULE IS MEASURED, not assumed (real WS7 under DOSBox-X, LASERJET driver ->
    /// PCL5, 2026-09-17):
    ///
    ///   * A `.pr or=` at the TOP of a page -- immediately after `.pa`, before any of that
    ///     page's text -- applies to THAT page. WS7 wrote `ESC&l1O` immediately after the form
    ///     feed that ended page 1 and before page 2's text, then `ESC&l0O` immediately after
    ///     page 2's form feed.
    ///   * A `.pr or=` in the MIDDLE of a page does NOT touch that page; it takes effect at the
    ///     NEXT one. With `.pr or=l` typed between page 1's second and third lines, all three
    ///     of page 1's lines printed under the portrait escape at its top, and the landscape
    ///     escape appeared one byte AFTER page 1's form feed. WS7 never emits an orientation
    ///     escape mid-page at all -- it queues the change to the next page boundary.
    ///
    /// WHY THE LINE INDEX IS KEPT, when every sibling here throws it away: a `.pr` typed
    /// between two lines of a paragraph sits in the SAME block the page opened at, so a
    /// block-only comparison reads it a page early and gives page 1 the sheet real WS7 gave
    /// page 2. The paginator already keeps the number that settles it (`readTally[bi]`, how
    /// many lines of that block earlier pages consumed, still the pre-line value where the
    /// geometry recompute runs). `.pl`/`.po`/`.mt` keep their block granularity: their own
    /// oracles were measured against it, and none of them reaches the MediaBox.
    func orTimeline() -> Timeline<Orientation> {
        Timeline(of: self, seed: .portrait) { current, dp in
            guard let (name, arg) = dp.command, name == "PR" else { return nil }
            // The SAME acceptance the parser itself applies (`applyFormatDot`'s `"PR"` case,
            // Formatting2.swift): the argument must literally begin `or=` and its fourth
            // character decides. Anything looser here would invent an entry for a command
            // the parser ignored.
            let a = arg.map(ASCII.upper)
            guard a.count > 3, a[0] == 0x4F, a[1] == 0x52, a[2] == 0x3D else { return nil }  // "OR="
            if a[3] == 0x4C { return .landscape }        // 'l'
            if a[3] == 0x50 { return .portrait }         // 'p'
            return nil
        }
    }

    /// `[(blockIndex, mtLines, mbLines), ...]` in ascending block order — the `.mt`/`.mb`
    /// pair IN FORCE from that block onward, at BLOCK granularity (the coarsest anchor
    /// `Document.dotPositions` gives — the same mechanism Soft Return.app's Show Invisibles
    /// and `tocPageNumbers`/`AnnotatedLayout.swift` already read). Mirrors how `.lh` already
    /// tracks per-LINE state (`Line.lead48`/`styleLeadPt`) — one level coarser, because
    /// `.mt`/`.mb` only take visible effect at the next page start, never mid-line. Port of
    /// Python's `_mt_mb_checkpoints`.
    ///
    /// The FIRST checkpoint (block 0) is the document's own global mtLines/mbLines
    /// (`ParseWS.swift`'s "first occurrence wins" page dict) — a document that never
    /// touches `.mt`/`.mb` again after its own opening geometry gets exactly ONE checkpoint,
    /// so every page's lookup returns the SAME pair the document-global functions already
    /// gave it: no behaviour change for any document but the ones this exists for.
    ///
    /// Finding 3: SCRIPT.WS changes both mid-document, around its embedded worked-example
    /// figures — measured (ARTICLES/SCRIPT.WS's own dot-command bytes, via
    /// `doc.dotPositions`): block 64 sets `.mt1`/`.mb0` (Figure 1's near-zero margins),
    /// block 75 sets `.mt1"`/`.mb1"` (Figure 2's own, different margins).
    ///
    /// WS4 acts on `.mt`/`.mb` when the line is reached (`Era.geometryActsAtOnce`), so for
    /// it the seed is the factory pair, not the first occurrence's: a page that opens before
    /// the first one prints at the factory margins (`plTimeline` seeds the same way; WS4
    /// teardown `evidence/pass3/exe-static.md` 8, run t43-mtmb).
    func mtMbTimeline() -> Timeline<MarginLines> {
        var seed = MarginLines(mt: page?.mtLines ?? defaultMtLines,
                               mb: page?.mbLines ?? defaultMbLines)
        if printingEra(self).geometryActsAtOnce {
            seed = MarginLines(mt: defaultMtLines, mb: defaultMbLines)
        }
        return Timeline(of: self, seed: seed) { current, dp in
            guard let (name, arg) = dp.command, name == "MT" || name == "MB",
                  let (value, unit) = parseDotNumber(arg) else { return nil }
            var next = current
            let resolved = resolveLinesArg(value, unit)
            if name == "MT" { next.mt = resolved } else { next.mb = resolved }
            return next
        }
    }

    /// `[(blockIndex, lineIndex, mt, mb, pl), ...]` in ascending order -- the body-height
    /// commands IN FORCE from that LINE on, for an era whose page counter acts on them at
    /// once (`Era.geometryActsAtOnce`, WS4). Port of Python's `_body_geometry_checkpoints`.
    /// Seeded at the factory values, like `plTimeline`: a page that opens before the first
    /// `.mt/.mb/.pl` has the factory margins. The line index is kept (as `orTimeline` keeps
    /// it) because a WS4 file is usually ONE block, so a block-granular reading cannot tell
    /// the lines before a `.MT` from the lines after it. WS4 teardown
    /// `evidence/pass3/exe-static.md` 8 (routine 1EE1B re-derives the space left on every
    /// change); run t43-mtmb.
    func bodyGeometryTimeline() -> Timeline<BodyGeometry> {
        let seed = BodyGeometry(mt: defaultMtLines, mb: defaultMbLines, pl: defaultPlLines)
        return Timeline(of: self, seed: seed) { current, dp in
            guard let (name, arg) = dp.command, name == "MT" || name == "MB" || name == "PL",
                  let (value, unit) = parseDotNumber(arg) else { return nil }
            var next = current
            let resolved = resolveLinesArg(value, unit)
            switch name {
            case "MT": next.mt = resolved
            case "MB": next.mb = resolved
            default: next.pl = resolved
            }
            return next
        }
    }

    /// `[(blockIndex, plLines), ...]` in ascending block order -- the `.pl` IN FORCE from that
    /// block onward. Mirrors `mtMbTimeline`'s mechanism (same `dotPositions` anchor) but NOT
    /// its block-0 seed: kept as its OWN function/list rather than folded in because `.pl` was
    /// found and fixed separately (register b31-dot-command-sweep), on its own oracle evidence.
    /// Port of Python's `_pl_checkpoints`.
    ///
    /// Real WS7 evidence (PL_PROBE, dosbox-x): a document that holds `.mt`/`.mb` fixed at 1
    /// line each and sets `.pl 20` then, after exactly one page's worth of body, `.pl 40`,
    /// printed 18 lines on page 1 (cap = pl 20 - mt 1 - mb 1) and 38 on page 2 (cap = pl 40 -
    /// mt 1 - mb 1) -- the page AFTER the second `.pl` uses ITS value, not the document's
    /// first.
    ///
    /// Seeded at WordStar's own HARDCODED default (`defaultPlLines`), NEVER at
    /// `doc.page?.plLines` (`ParseWS.swift`'s first-occurrence reading) -- those are the SAME
    /// number for a document that declares `.pl` right at its own start (the overwhelming
    /// common case), but NOT for one whose only `.pl` sits mid-document with nothing before
    /// it: `ParseWS.swift`'s "first occurrence wins" would read THAT single occurrence as the
    /// document's global default and hand it back for block 0 too, retroactively applying the
    /// mid-document value to pages that printed before the command was ever reached (caught
    /// building `hmFmTimeline` against a probe whose only `.hm`/`.fm` are
    /// mid-document -- `.pl` shares the exact same construction, fixed here too).
    ///
    /// If `dotPositions` carries no `.pl` entry AT ALL, the hardcoded seed is replaced with
    /// `doc.page?.plLines` after the walk -- a document with no dot-command evidence for `.pl`
    /// anywhere (every hand-built `Document(..., page:)` fixture that sets page geometry
    /// directly rather than through `parseWS`, plus any real document that truly never sets
    /// `.pl`) has no mid-document-only-occurrence to protect against, so its own declared page
    /// value is trusted as-is -- exactly `mtMbTimeline`'s own seed. A document WITH at
    /// least one `.pl` occurrence anywhere (mid-document or at its own true start, register
    /// b31's actual target) is untouched by this fallback.
    func plTimeline() -> Timeline<Double> {
        var timeline = Timeline(of: self, seed: defaultPlLines) { _, dp in
            guard let (name, arg) = dp.command, name == "PL",
                  let (value, unit) = parseDotNumber(arg) else { return nil }
            return resolveLinesArg(value, unit)
        }
        if timeline.entries.count == 1 {
            timeline.reseed(page?.plLines ?? defaultPlLines)
        }
        return timeline
    }

    /// `[(blockIndex, hmLines, fmLines), ...]` in ascending block order -- the `.hm`/`.fm` pair
    /// IN FORCE from that block onward. Mirrors `mtMbTimeline` (same anchor, same "pair"
    /// shape) -- kept as its own pair/function rather than folded into `mtMbTimeline`
    /// because `.hm`/`.fm` were found and fixed together, sharing one dot-command regex,
    /// months after the mt/mb mechanism shipped. `runningOps`'s own `headBase` no longer
    /// gates `hm`'s participation on `mtSource` at all (mechanism W, PCL-DIVERGENCE-
    /// TRIAGE.md) -- it reads whatever `hmLines` this checkpoint pair resolves to for the
    /// page unconditionally. Port of Python's `_hm_fm_checkpoints`.
    ///
    /// Real WS7 evidence (HMFM_PROBE, dosbox-x, register b31-dot-command-sweep): a document
    /// that never touches `.mt` (stays at the factory default throughout) but sets `.hm 6`/
    /// `.fm 6` mid-document (factory default is `.hm 2`/`.fm 2`) printed its header/footer at
    /// TWO different PCL rows -- 35.7pt/75.6pt on the pages before the change, 12.0pt/80.4pt on
    /// the pages after it -- even though `.mt` itself never moved.
    ///
    /// Seeded at WordStar's own hardcoded defaults (2.0/2.0, WSFORMAT's own `.hm`/`.fm`
    /// defaults), NOT `doc.page?.hmLines`/`fmLines` (`ParseWS.swift`'s first-occurrence
    /// reading) -- HMFM_PROBE is exactly the degenerate case that distinguishes them: its
    /// `.hm`/`.fm` appear only ONCE, mid-document, so "first occurrence wins" reads that single
    /// occurrence as the document's global default and would otherwise hand it back for block 0
    /// too, retroactively applying the mid-document value to the pages that printed before the
    /// command was ever reached. See `plTimeline`'s doc comment -- same fix, same reason.
    ///
    /// Same hand-built-fixture fallback as `plTimeline`: no `.hm`/`.fm` entry anywhere in
    /// `dotPositions` reseeds from `doc.page?.hmLines`/`fmLines` after the walk.
    func hmFmTimeline() -> Timeline<HeadFootLines> {
        // WSFORMAT's own hardcoded defaults: ".HM ... Default is 2." / ".FM ... Default is 2."
        let seed = HeadFootLines(hm: defaultHmLines, fm: defaultFmLines)
        var timeline = Timeline(of: self, seed: seed) { current, dp in
            guard let (name, arg) = dp.command, name == "HM" || name == "FM",
                  let (value, unit) = parseDotNumber(arg) else { return nil }
            var next = current
            let resolved = resolveLinesArg(value, unit)
            if name == "HM" { next.hm = resolved } else { next.fm = resolved }
            return next
        }
        if timeline.entries.count == 1 {
            timeline.reseed(HeadFootLines(hm: page?.hmLines ?? defaultHmLines,
                                          fm: page?.fmLines ?? defaultFmLines))
        }
        return timeline
    }

    /// `[(blockIndex, poCols), ...]` in ascending block order -- the `.po` (page offset) IN
    /// FORCE from that block onward. Mirrors `plTimeline` exactly (same `dotPositions`
    /// anchor, same "block 0 is the document's own global first-occurrence value" contract,
    /// same hand-built-fixture fallback) -- see `plTimeline`'s doc comment. Port of Python's
    /// `_po_checkpoints`.
    ///
    /// Body text already carries a mid-document `.po` change correctly: `ParseWS.swift` stamps
    /// `Line.poCols` on every physical line (state carried forward exactly like `.lh`), and
    /// `resolvePrintedBody` override their own `left` per line whenever a
    /// line's `poCols` differs from the document default (`resolveLeftPt(line.poCols, ...)`).
    /// `runningOps` (the header/footer row) had NO equivalent -- it always rendered at the
    /// document's global `left`, regardless of which page it was on.
    ///
    /// SCRIPT.WS (sawyer archive) is the oracle (mechanism O, ctrl-kd 55d2b52): its own
    /// worked-example figures reset `.po` to `.5"` (5 columns) around block 64 and again around
    /// block 75/84, alongside the `.mt`/`.hm` changes `mtMbTimeline`/`hmFmTimeline` already
    /// track for the SAME figures. WS7's own capture (`ws7-prints/v1/SCRIPT.pcl`) prints the
    /// running head "PROFILES MONTH '88 SCRIPT.001..." on the figure pages starting at x=36.0pt
    /// (column 5, the figure's own local `.po .5"`) -- this engine, reading only the document's
    /// global `.po` default (8 columns, 57.6pt), rendered it 21.6pt (3 columns) too far right.
    func poTimeline() -> Timeline<Double> {
        let era = printingEra(self)
        var timeline = Timeline(of: self, seed: defaultPoCols) { _, dp in
            guard let (name, arg) = dp.command, name == "PO" else { return nil }
            guard let (value, unit) = parseDotNumber(arg) else {
                // Era.barePoZero / badPoZero
                return (isBlankDotArg(arg) ? era.barePoZero : era.badPoZero) ? 0.0 : nil
            }
            return resolveColsArg(value, unit)
        }
        if timeline.entries.count == 1 {
            timeline.reseed(page?.poCols ?? defaultPoCols)
        }
        return timeline
    }

    /// Planning #231: `.poe`/`.poo` (even/odd page-offset) checkpoints, keyed by `dotName`
    /// ("POE"/"POO") -- EMPTY if the document never uses that command (unlike
    /// `poTimeline` above, NO block-0 seed: WordStar has no hardcoded default for a
    /// parity-specific offset, "never set" genuinely means "no override," resolved by
    /// falling back to whichever of `.po`/the other parity governs instead -- see
    /// `leftForParity`). Port of ctrl-kd's `_poe_poo_checkpoints`.
    func parityPoTimeline(dotName: String) -> Timeline<Double> {
        Timeline(unseededOf: self) { dp in
            guard let (name, arg) = dp.command, name == dotName,
                  let (value, unit) = parseDotNumber(arg) else { return nil }
            return resolveColsArg(value, unit)
        }
    }

    /// `[(blockIndex, pnValue), ...]` in ascending block order -- a `.pn` RE-ANCHORS the
    /// automatic page-number sequence starting on the page it appears on (WSFORMAT: ".PN ...
    /// Sets the starting page number"), it does not merely set the document's own opening
    /// number once. Port of Python's `_pn_checkpoints`.
    ///
    /// Real WS7 evidence (PN_PROBE, dosbox-x, register b31-dot-command-sweep): printed page 1
    /// as "10", page 2 as "11" (a `.pn 10` up front, incrementing normally), then page 3 as
    /// "500" and page 4 as "501" once a mid-document `.pn 500` was reached -- the SECOND value
    /// re-anchors the count from the page it lands on, exactly like the first.
    ///
    /// Seeded at 1 (WordStar's own hardcoded starting number), same reason `plTimeline`/
    /// `hmFmTimeline` seed at the hardcoded default rather than `doc.page?.pnStart` -- see
    /// their doc comments. Same hand-built-fixture fallback too: no `.pn` entry anywhere in
    /// `dotPositions` reseeds from `doc.page?.pnStart`.
    /// 2026-09-12: a `.pn` is a real checkpoint even when its VALUE repeats one already
    /// seen. The old guard compared against the last checkpoint's number rather than
    /// against the number this page would otherwise have taken, and so threw away every
    /// restart-to-a-number-already-used. MEASURED against real WS7 (ws7-prints/v4,
    /// PRISTINE.EXE) on `sawyer/REF/CTRL-K.H1`, whose mid-document `.pn1` follows five
    /// pages numbered 1-5: WS7 numbers its remaining sheets 6, 7, 8, 9 as pages 1, 2, 3, 4
    /// -- which is also the parity its own `^K` even-page header rule reads
    /// (`ctrlKEvenPage`). Two `.pn` inside the SAME block keep the last; a `.pn` in block 0
    /// replaces the seed rather than doubling it.
    func pnTimeline() -> Timeline<Int> {
        var timeline = Timeline(restartingFrom: self, seed: 1) { dp in
            guard let (name, arg) = dp.command, name == "PN",
                  let (value, _) = parseDotNumber(arg) else { return nil }
            return Int(value)
        }
        // Keyed on any accepted `.pn`, not on a changed value: a `.pn` at block 0
        // replaces the seed, which leaves one entry that is still a real command's.
        if timeline.acceptedCommands == 0 {
            timeline.reseed(page?.pnStart ?? 1)
        }
        return timeline
    }

    /// `[(blockIndex, enabled), ...]` ascending -- whether WordStar's AUTOMATIC page number
    /// (the one `.pc` positions; WSFORMAT.WS's own text: ".PC ... active only when the
    /// footers are not in use and page numbering is turned on") is ON from that block
    /// onward. Mirrors `pnTimeline`'s shape exactly (same `dotPositions` anchor, "last
    /// checkpoint at or before this block wins" contract, via `Timeline.at`). Port of
    /// ctrl-kd's `_pgnum_checkpoints` (pdf.py, register b31, E3 item 2, 2026-08-25).
    ///
    /// Seeded ON -- WordStar 7's stock factory default state (WSCHANGE ships the
    /// automatic page number ON, centered at the bottom margin, unless `.op` turns it
    /// off). REVERSED 2026-09-07, ported from ctrl-kd `pdf.py`'s `_pgnum_checkpoints`
    /// (commit b6d5d03): ws7-prints/v3 (the PRISTINE.EXE recapture), finding #2 --
    /// documents that never touch `.pn`/`.pg`/`.op`/`.pc` at all print a stock
    /// bottom-of-page automatic number under a genuinely stock WS7 install, confirmed
    /// at the raw PCL byte level across BOXES/SAWYER/VERSIONS/-README plus several
    /// private-corpus documents. Previously seeded OFF, MEASURED (dosbox-x, 16 probes) against Robert J.
    /// Sawyer's own WSCHANGE-customized install -- the same install-contamination
    /// family as ctrl-kd's `.po` column 7 vs 8 bug (mechanism S, already ported/
    /// reverted here too): Sawyer's WSCHANGE profile turned the automatic number OFF
    /// by default, stock WS7 does not.
    ///
    /// `.pn` (ANY occurrence -- WSFORMAT: "sets the starting page number"; measured: a
    /// bare `.pn 5` with no header/footer/`.pg` at all still printed a bottom-of-page
    /// number) and `.pg` (WSFORMAT's own documented re-enable after `.op`) both turn it
    /// ON (a no-op against this new default, since it is already ON); `.op` turns it
    /// OFF -- unaffected by this change, still the only way a document reaches "no
    /// number". Genuinely stateful mid-document (measured: page 1 under `.op` silent,
    /// pages after a mid-document `.pg` numbered, no `.pn` anywhere in that probe at
    /// all -- `.pg` alone activates it).
    ///
    /// This is the engine for `EmitOptions.PageNumberMode.auto` (the default): the
    /// document's own dot commands decide, byte-identical to every existing capture/oracle
    /// for the overwhelming majority of documents that never touch any of these four
    /// commands (they now get the stock automatic number instead of none). `.on`/`.off`
    /// bypass this entirely -- see `emitPDF`'s own call site (PDFWriter.swift).
    func pgnumTimeline() -> Timeline<Bool> {
        // No word-boundary check: a real WS7 file overwhelmingly writes `.pn0`/`.pn22`/
        // `.pg` with NO space before a following digit, and `dotCommandNameAndArg`'s own
        // 1-3-ASCII-letter scan (the same one every other timeline here uses) already
        // stops at the first non-letter, so `.PN0` correctly yields name "PN" -- no
        // `\b`-style trap to avoid here the way ctrl-kd's regex port had to name
        // explicitly.
        Timeline(of: self, seed: true) { _, dp in
            guard let (name, _) = dp.command else { return nil }
            if name == "PN" || name == "PG" { return true }
            if name == "OP" { return false }
            return nil
        }
    }

    /// `[(blockIndex, interval), ...]` in ascending block order -- the `.l#` line-numbering
    /// interval IN FORCE from that block onward. Same `dotPositions`-anchored shape
    /// `plTimeline`/`hmFmTimeline` use -- both
    /// Printed renderers need the positional answer:
    /// `PDFWriter.swift`'s `pageStream` resolves it PER LINE (by that line's own block index --
    /// a single per-page value cannot represent a document whose `.l#` turns on and off again
    /// within one page, exactly sawyer/PRINT.TST's own shape) and `EmitRTF.swift`'s Printed
    /// gutter resolves it PER BLOCK (RTF has no page object to reset against, so its own
    /// numbering runs continuously from the document's start). Port of Python's
    /// `line_numbering_checkpoints`.
    ///
    /// Seeded at `(0, nil)` ("off") -- unlike `plTimeline`'s WordStar-hardcoded-default
    /// seed, there is no retroactive first-occurrence-wins hazard to guard against here: line
    /// numbering's own real default IS off, so a `.l#` whose only occurrence sits mid-document
    /// correctly leaves every earlier block at `nil` with no special-casing needed.
    ///
    /// Walked directly against `dp.text` rather than through `dotCommandNameAndArg` -- that
    /// helper's name grammar is `[A-Za-z]{1,3}` only, and `.L#`'s own two-character name ends
    /// in the literal `#`, which it can never match (see `parseCollectDot`'s own handling of
    /// the same command, `Formatting2.swift`).
    ///
    /// Planning #247 (found by the #245 job on PRINT.TST/PSPRINT.TST): `doc.lineNumbering`
    /// (set by `parseCollectDot`, `.l#`'s own PARSE-time handler) is a single flat value,
    /// last-command-wins for the WHOLE document -- both real oracles here (sawyer/PRINT.TST,
    /// sawyer/DEFAULT/PRINT.TST) declare `.l#2` right before their "Line Numbers"
    /// demonstration section and `.l# 0` right after it, so the flat reading is always the OFF
    /// value and nothing ever rendered anywhere, even on the one page that turned it on. This
    /// is the `.mt`/`.mb`-shaped fix: a positional answer, not a single global one.
    /// (sawyer/PSPRINT.TST's own `..l#2` is a DIFFERENT thing entirely -- a leading `..` is
    /// WordStar's own `.IG`/comment shorthand, so that occurrence never was a real dot
    /// command; PSPRINT.TST's line numbering stays off throughout, correctly, both before and
    /// after this fix.)
    func lineNumberingTimeline() -> Timeline<Int?> {
        Timeline(of: self, seed: nil) { _, dp in
            let bytes = Array(dp.text.utf8)
            guard bytes.count >= 3, bytes[0] == 0x2E,             // '.'
                  ASCII.upper(bytes[1]) == 0x4C,              // 'L'
                  bytes[2] == 0x23                                // '#'
            else { return nil }
            guard let (value, _) = parseDotNumber(Array(bytes[3...])), value.isFinite
            else { return nil }
            // `Int??`: `.some(nil)` is the accepted value "off"; a bare `nil` ignores the
            // command.
            return .some(Int(value) > 0 ? Int(value) : nil)
        }
    }

}
