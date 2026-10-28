#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import CtrlKD
import SoftReturnShared

/// A PRINTED FACSIMILE DOES NOT EXPAND TABS TO COCOA'S STOPS.
///
/// `NSParagraphStyle` defaults to twelve tab stops at 28pt, and this renderer never set
/// otherwise for the Printed family — so a literal tab in the source jumped to a 28pt stop
/// inside a page that is fixed pitch everywhere else. Measured 2026-09-07 against the
/// engine's own PDF: RNFOREST.TXT begins with a tab, the engine draws that line's ink at the
/// margin (x=72.00) and the app put it at x=100.00. 72 + 28 = 100, exactly, on all six of
/// RNFOREST/RECYCLE/WETLAND's .TXT and .WS4 pairs.
///
/// The engine does not expand the tab at all — its own word there is literally `\tThe`, one
/// run starting at the margin, so the tab occupies the cell grid like any other character.
/// Jon's standing rule is that the Printed view reproduces the engine's output, so that is
/// what this reproduces: no stops, and one column per tab.
///
/// (Whether the ENGINE is right about a raw tab in a plain-text file is a separate question
/// that only a real WS7 print of a tabbed .TXT can answer. None of the 18 PCL captures has
/// one; filed as a phase-2 capture question, and it does not block this.)
func nativeTabStops(_ style: NSMutableParagraphStyle, columnWidthPt: Double) {
    style.tabStops = []
    style.defaultTabInterval = CGFloat(columnWidthPt)
}

/// A Native line's paragraph style, for the plain and the Show Invisibles renders alike. `lead`: the line pinned to
/// that many points (`minimumLineHeight == maximumLineHeight`); nil, the line at its own font's natural height (0
/// for both, `NSMutableParagraphStyle`'s "unbounded" default), as a natural pass needs. Tab stops at the document's
/// Courier pitch, 0.6 of `fontSize`. `extraLeftPt` goes on both indents: a Native paragraph is one physical line, so
/// the two never differ.
func nativeLineParagraphStyle(fontSize: Double, lead: Double?, lineBreakMode: NSLineBreakMode = .byClipping,
                              extraLeftPt: Double = 0) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    if let lead {
        style.minimumLineHeight = CGFloat(lead)
        style.maximumLineHeight = CGFloat(lead)
    }
    style.lineBreakMode = lineBreakMode
    nativeTabStops(style, columnWidthPt: fontSize * 0.6)
    if extraLeftPt != 0 {
        style.firstLineHeadIndent = CGFloat(extraLeftPt)
        style.headIndent = CGFloat(extraLeftPt)
    }
    return style
}

/// Job 226: disables `NSAttributedString`'s default kerning on every Native-style string
/// this renderer builds. `PDFWriter.lineOpsPrinted`/`runningOps`'s whole positioning model —
/// `spanPitch`, `spanTarget`, `tzScale`, the running-head/footer `Td` math — assumes a FIXED
/// per-character advance with no font-pair kerning at all: PDF's plain `Tj` operator (this
/// emitter never writes a `TJ` array with per-glyph adjustments) places glyphs back to back
/// at the font's raw advance widths, full stop. `.kern: 0` is Cocoa's documented way to
/// disable kerning per run, so this is applied on general principle to keep AppKit's layout
/// matching that same "no font-pair kerning" model.
///
/// NOT CONFIRMED as the explanation for the header drift this job chased (a `"Courier"`
/// `NSAttributedString.size()` probe measured a 53-char header string at 367.26pt against an
/// expected 381.6pt (53 * 7.2) — a ~14pt gap matching the observed reference-vs-actual
/// drift — but the SAME probe with `.kern: 0` added measured IDENTICAL 367.26pt: legacy
/// `NSStringDrawing.size()` either doesn't apply `.kern` the way real `NSLayoutManager`
/// layout does, or isn't measuring what this job assumed (leading-space handling is one
/// candidate, untested). The real oracle (TextKit-rendered, not `.size()`) DID show some
/// LJ6DTP row counts move after this change landed, but not cleanly enough to credit kerning
/// specifically — several other fixes landed in the same pass. Left in as a real, defensible
/// correctness fix on its own terms; the header's remaining pixel drift is NOT closed and
/// its root cause is still open — see this job's report/LESSONS, not a re-derivation here.
let nativeNoKerning: Float = 0

/// The kern that puts a Courier Prime character on the engine's 10-pitch grid, 0.6 em: Courier
/// Prime advances 0.5996 em, and a running line of it drifted a quarter point left by its last
/// word (-README's head against its WS7 capture). Any other face takes no kern.
@MainActor
func nativeCourierPitchKern(_ font: NSFont) -> Float {
    guard font.familyName == "Courier Prime" else { return nativeNoKerning }
    return Float(0.6 * Double(font.pointSize) - nativeResolvedAdvance(of: "0", in: font))
}


/// A line's graphic cells, less the `.l#` bars (`PDFMetrics.lineNoBarChars` at
/// `PDFMetrics.lineNoBarXs`): the engine draws those at fixed x on every numbered row, and
/// they are not characters in the line's text, so they would put the character-by-character
/// match of the rest out of step. Native draws them with the line number instead.
func nativeLineGraphicCells(_ line: PageLine) -> (cells: [PageLine.GraphicCellPlacement],
                                                bars: [PageLine.GraphicCellPlacement]) {
    let all = line.graphicCells ?? []
    guard line.lineNo != nil else { return (all, []) }
    let isBar = { (cell: PageLine.GraphicCellPlacement) in
        zip(PDFMetrics.lineNoBarChars, PDFMetrics.lineNoBarXs).contains {
            $0.0 == cell.char && abs($0.1 - cell.x) < 1e-6
        }
    }
    return (all.filter { !isBar($0) }, all.filter(isBar))
}

/// The pieces Native pins a line to, and the scale tolerance to pin them with.
///
/// A line with text WS7's driver places (`PageLine.driverPieces`): every piece the engine
/// places, at the driver's own x, each drawn in its Mac face and scaled to its paper width, so
/// it neither runs into the gap after it nor leaves that gap wider (`nativeDriverScaleTolerance`
/// is 0). WS7
/// itself positioned every word from its tables and let the printer's face draw it; the Mac
/// face is the printer's face here.
///
/// Otherwise the engine's justification pieces (`PageLine.justifyWordX`) for a line whose every
/// inked span is fixed pitch, never scaled.
func nativeLinePieces(
    _ line: PageLine, fonts: [FontChange]
) -> (pieces: [PageLine.JustifyWordPiece], scaleBeyond: Double?) {
    if let driver = line.driverPieces, !driver.isEmpty {
        return (driver, nativeDriverScaleTolerance)
    }
    return (nativeJustifyPieces(line, fonts: fonts), nil)
}

/// The `.kr` state Native's LJ6DTP substitution collapses doubled curly quotes under
/// (`nativeLJ6DTPSubstitute`). A line the driver places keeps the pair as two characters,
/// tucked by the driver's own kerning pairs, as Printed draws it.
func nativeQuoteKerning(_ line: PageLine) -> Bool {
    line.kerning && (line.driverPieces ?? []).isEmpty
}

/// A driver-placed word narrower than its width on paper keeps its Mac face's natural width
/// unless it is narrower by more than this fraction; then it is scaled to the paper width. 0:
/// every word is drawn at its paper width, which keeps a justified line's gaps even.
let nativeDriverScaleTolerance = 0.0

/// The justification pieces Native pins a line to: the engine's (`PageLine.justifyWordX`) for
/// a line whose every inked span is fixed pitch, none otherwise. A proportional line is pinned
/// to its `driverPieces` instead (`nativeLinePieces`).
func nativeJustifyPieces(_ line: PageLine, fonts: [FontChange]) -> [PageLine.JustifyWordPiece] {
    guard let pieces = line.justifyWordX, !pieces.isEmpty else { return [] }
    let proportional = line.spans.contains { span in
        guard span.text.contains(where: { !$0.isWhitespace }) else { return false }
        let entry = span.font.flatMap { fonts.indices.contains($0) ? fonts[$0] : nil }
        return pdfFamily(entry) != .courier
    }
    return proportional ? [] : pieces
}

/// A JUSTIFIED LINE'S OWN WORD AND GAP WIDTHS, AS THE LIBRARY SPREAD THEM.
///
/// Planning #251(b): `PageLine.justifyWordX` is the engine's own precomputed
/// `justifyPiecesPrinted` result — every word and every gap of a justified line, left to
/// right, each with its own x and width. The pieces are contiguous, so pinning each one's
/// total advance to its own width lands every one of them on its own x by construction.
///
/// It has to be pinned rather than left to AppKit for the same reason a fixed-pitch cell
/// does: the app's own spread is its Mac face's, and the library's is a whole-point
/// distribution over a fixed-pitch grid. REFORM.DOT line 18 is the corpus case — the engine
/// puts `.pf` at 273.60 and `on` at 511.20, a gap of over 200pt, where the app ran the line
/// together at its own natural spacing.
///
/// Bails out entirely rather than partially if the pieces and the built string ever
/// disagree: a line half-pinned to a model it does not match is worse than one not pinned.
///
/// `scaleBeyond`: for a line's driver pieces, an inked piece wider than its own width is
/// scaled to it (`.expansion`); a narrower one is scaled only when it is narrower by more than
/// this fraction, and otherwise keeps its natural width with the gap after it taking up the
/// difference.
@MainActor
func nativePinJustifiedWords(
    _ input: NSAttributedString, pieces inputPieces: [PageLine.JustifyWordPiece],
    scaleBeyond: Double? = nil
) -> NSAttributedString {
    guard !inputPieces.isEmpty, input.length > 0 else { return input }
    // A dot-leader tab on a driver-placed line: WS7 repeats the leader glyph at the driver's own
    // advance to fill the gap, and the engine's piece is the dots it drew. The document's own run
    // of dots is rebuilt to that many, each spaced at the engine's pitch, unscaled, and the run
    // never joins the word beside it.
    let pieces = inputPieces
    var leaders = Set<Int>()
    let assembled = NSMutableAttributedString(attributedString: input)
    if scaleBeyond != nil {
        var at = 0
        for (index, piece) in inputPieces.enumerated() {
            let length = (piece.text as NSString).length
            let string = assembled.string as NSString
            at = nativeSkipAttachments(in: string, from: at, before: piece.text)
            var typed = 0
            if length > 2, let dot = piece.text.first, !dot.isWhitespace, !dot.isLetter, !dot.isNumber,
               piece.text.allSatisfy({ $0 == dot }) {
                while at + typed < string.length,
                      string.substring(with: NSRange(location: at + typed, length: 1)) == String(dot) {
                    typed += 1
                }
            }
            if typed > 0, let dot = piece.text.first,
               let font = assembled.attribute(.font, at: at, effectiveRange: nil) as? NSFont {
                let one = nativeResolvedAdvance(of: String(dot), in: font)
                var attributes = assembled.attributes(at: at, effectiveRange: nil)
                attributes[.kern] = max(0, piece.width / Double(length) - one)
                attributes[.expansion] = nil
                assembled.replaceCharacters(in: NSRange(location: at, length: typed),
                                            with: NSAttributedString(string: piece.text, attributes: attributes))
                leaders.insert(index)
            }
            at += length
        }
    }
    let text = assembled.string as NSString
    // Every piece's own character range in the built string, checked as we go.
    var ranges: [NSRange] = []
    var cursor = 0
    for piece in pieces {
        cursor = nativeSkipAttachments(in: text, from: cursor, before: piece.text)
        let piece = piece.text as NSString
        guard cursor + piece.length <= text.length,
              text.substring(with: NSRange(location: cursor, length: piece.length)) == piece as String
        else { return input }
        ranges.append(NSRange(location: cursor, length: piece.length))
        cursor += piece.length
    }
    let pinned = NSMutableAttributedString(attributedString: assembled)
    // Each piece's natural width in its own face and the kerns already on it (the fixed-pitch
    // and graphic-cell pins), and the last character, which carries the pin.
    var naturals: [Double] = []
    var kernsOn: [Double] = []
    var lasts: [NSRange] = []
    for range in ranges {
        var natural = 0.0
        var kerns = 0.0
        var last = NSRange(location: NSNotFound, length: 0)
        var at = range.location
        while at < NSMaxRange(range) {
            let composed = text.rangeOfComposedCharacterSequence(at: at)
            let clamped = NSIntersectionRange(composed, range)
            guard clamped.length > 0 else { break }
            last = clamped
            if let font = pinned.attribute(.font, at: clamped.location, effectiveRange: nil) as? NSFont {
                natural += nativeResolvedAdvance(of: text.substring(with: clamped), in: font)
            }
            kerns += (pinned.attribute(.kern, at: clamped.location, effectiveRange: nil) as? Double) ?? 0
            at = NSMaxRange(composed)
        }
        naturals.append(natural)
        kernsOn.append(kerns)
        lasts.append(last)
    }
    // The scale of each piece. A word a kerning pair split into pieces is judged whole: its
    // width on paper is the sum of its pieces' advances, kerning included, against its face's
    // natural width. Wider at all, or narrower past the tolerance, the whole word is scaled to it.
    var scales = [Double](repeating: 1, count: ranges.count)
    // Each piece's advance on screen: its width on paper, except inside a word a kerning pair
    // split and that keeps its natural width (below).
    var targets = pieces.map(\.width)
    if let limit = scaleBeyond {
        func inked(_ k: Int) -> Bool {
            text.substring(with: ranges[k]).contains(where: { !$0.isWhitespace })
        }
        var k = 0
        while k < ranges.count {
            guard inked(k) else { k += 1; continue }
            // LJ6DTP's © (`nativeLJ6DTPCopyright`) and a dot leader stand alone, never part of
            // a word.
            func standsAlone(_ k: Int) -> Bool { pieces[k].text == "©" || leaders.contains(k) }
            var end = k
            while end + 1 < ranges.count, inked(end + 1), !standsAlone(end), !standsAlone(end + 1) { end += 1 }
            let natural = naturals[k...end].reduce(0, +)
            let width = pieces[k...end].reduce(0) { $0 + $1.width }
            // A lone symbol (a bullet, a © standing by itself) narrower than its cell keeps its
            // own shape: the printer drew its own glyph there (the engine's `ljAlone`).
            let scalars = pieces[k].text.unicodeScalars
            let lone = k == end && scalars.count == 1
                && !CharacterSet.alphanumerics.contains(scalars.first!)
            if (lone && natural < width) || leaders.contains(k) {
                k = end + 1
                continue
            }
            if natural > 0, pieces[k...end].allSatisfy({ $0.drawn != nil }) {
                // Each piece at the width the driver drew it, as Printed sets each piece's Tz:
                // a kerning pair tucks the next piece under this one's end rather than
                // squeezing this one into the advance (LJ6DTP p2's ’’, which the LaserJet and
                // Printed print as one tight pair).
                for w in k...end where naturals[w] > 0 {
                    let scale = (pieces[w].drawn ?? pieces[w].width) / naturals[w]
                    scales[w] = scale
                    pinned.addAttribute(.expansion, value: log(scale), range: ranges[w])
                }
            } else if natural > 0, width > 0, natural > width || (width - natural) / width > limit {
                // One scale for the word, except that a piece of more than one letter in a
                // word a kerning pair split fills its own slot: the Mac face's letters are not
                // in the driver's proportions, and one scale left the last piece short, a gap
                // after the word. A single tucked letter keeps the word's scale, so a kerned
                // pair still overlaps rather than squeezing.
                // An underlined word keeps one scale: AppKit draws an underline per run, and a
                // scale per piece broke a link's underline into steps (LJ6DTP p8).
                let underlined = ((pinned.attribute(.underlineStyle, at: ranges[k].location,
                                                    effectiveRange: nil) as? Int) ?? 0) != 0
                for w in k...end {
                    let own = end > k && !underlined && pieces[w].text.count > 1 && naturals[w] > 0
                    let scale = own ? pieces[w].width / naturals[w] : width / natural
                    scales[w] = scale
                    pinned.addAttribute(.expansion, value: log(scale), range: ranges[w])
                }
            } else if end > k, natural > 0 {
                // A split word drawn at its natural width keeps its pieces together, each
                // moved only by the driver's kern, and the word's slack goes after its last
                // piece rather than opening a gap at the split.
                let slack = width / natural - 1
                var moved = 0.0
                for w in k..<end {
                    targets[w] = pieces[w].width - naturals[w] * slack
                    moved += naturals[w] * slack
                }
                targets[end] = pieces[end].width + moved
            }
            k = end + 1
        }
    }
    for (index, last) in lasts.enumerated() where ranges[index].length > 0 {
        guard last.location != NSNotFound else { continue }
        let advance = naturals[index] * scales[index] + kernsOn[index]
        let delta = targets[index] - advance
        let existing = (pinned.attribute(.kern, at: last.location, effectiveRange: nil) as? Double) ?? 0
        let lastAdvance = (pinned.attribute(.font, at: last.location, effectiveRange: nil) as? NSFont)
            .map { nativeResolvedAdvance(of: text.substring(with: last), in: $0) * scales[index] } ?? 0
        // AppKit never moves a glyph back: a character whose advance comes out negative advances
        // nothing, and the line after it sits right by the difference. A cut too deep for the
        // last character (a run of tab spaces before a symbol, LJ6DTP p3's chart) is shared
        // among the piece's characters.
        guard lastAdvance + existing + delta < 0 else {
            pinned.addAttribute(.kern, value: existing + delta, range: last)
            continue
        }
        var characters: [NSRange] = []
        var at = ranges[index].location
        while at < NSMaxRange(ranges[index]) {
            let composed = NSIntersectionRange(text.rangeOfComposedCharacterSequence(at: at), ranges[index])
            guard composed.length > 0 else { break }
            characters.append(composed)
            at = NSMaxRange(composed)
        }
        let share = delta / Double(characters.count)
        for character in characters {
            let own = (pinned.attribute(.kern, at: character.location, effectiveRange: nil) as? Double) ?? 0
            pinned.addAttribute(.kern, value: own + share, range: character)
        }
    }
    // The typesetter adds the face's kerning pair after some pinned characters and not others
    // (Times' space before T, 0.2 pt, and ’ before a space, 0.9 pt; not W before o in a word
    // scaled in two runs), so the line is set once as AppKit sets it and each piece's last
    // character takes up the difference between where the next piece starts and its target.
    let measured = nativeGlyphStarts(pinned, at: ranges.map(\.location))
    // Each piece's place is the engine's x, moved by any slack a split word put after its last
    // piece instead (`targets`), and a print control's spacer between pieces keeps its gap.
    var moved = 0.0
    var error = 0.0
    for index in 0..<(ranges.count - 1) {
        moved += targets[index] - pieces[index].width
        let planned = pieces[index + 1].x - pieces[0].x + moved
        let after = measured[index + 1] - measured[0] - planned
        let last = lasts[index]
        if ranges[index].length > 0, last.location != NSNotFound, abs(after - error) > 0.01 {
            let kern = (pinned.attribute(.kern, at: last.location, effectiveRange: nil) as? Double) ?? 0
            pinned.addAttribute(.kern, value: kern - (after - error), range: last)
            error = after
        }
    }
    return pinned
}

/// EVERY GRAPHIC CHARACTER GETS THE CELL THE LIBRARY GAVE IT.
///
/// Planning #251(c): `PageLine.graphicCells` states each cp437 box-drawing/graphic
/// character's own x and width, recorded from a real call to the writer's own
/// `lineOpsPrinted`, so it IS the cell the library draws rather than a re-derivation.
///
/// The vector overlay could be placed from that alone, but the glyphs underneath could not:
/// these characters are real text in this app's own storage, and their ADVANCES are the Mac
/// face's, which decide where everything after them on the line begins. `nativePinToCells`
/// already pins a fixed-pitch run's advances to the document's pitch, and for a graphic
/// character inside such a run the two answers agree — but it declines a PROPORTIONAL run
/// outright, and the library gives a graphic cell in a proportional run the type size
/// itself. -LASERJE.FNT line 9 is that case: its box-drawing prelude advanced 15.57pt a cell
/// against the library's own, so the "Scalable" that follows started 4.46pt early, and
/// PAGE.RND line 56's rule drifted its whole width.
///
/// So the advance is pinned here too, per character, from the model. Matched by ORDER and
/// confirmed by character: a cell the model and this string disagree about keeps whatever
/// advance it already had rather than borrowing a neighbour's.
@MainActor
func nativePinGraphicCells(
    _ assembled: NSAttributedString, placements: [PageLine.GraphicCellPlacement]
) -> NSAttributedString {
    guard !placements.isEmpty, assembled.length > 0 else { return assembled }
    let pinned = NSMutableAttributedString(attributedString: assembled)
    let text = pinned.string as NSString
    // This character's own advance in its own face, WITHOUT any kern already on it.
    //
    // The distinction matters and getting it wrong is a real bug this had: `.kern` REPLACES,
    // so a pin that sets `width - (natural + existingKern)` subtracts the existing kern
    // twice. BOX.WS's interior spaces already carry a +6.54 kern of their own, and the first
    // version of this measured that in and then replaced it — every space came out 0.66pt
    // wide instead of 7.2, and a 23-cell row measured 28.22pt against its own border's
    // 165.60. A pin that ADDS (the between-cell one below) wants the kern-inclusive figure;
    // a pin that REPLACES wants this one.
    func naturalAdvance(of range: NSRange) -> Double {
        guard let font = pinned.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        else { return 0 }
        return nativeResolvedAdvance(of: text.substring(with: range), in: font)
    }
    func advance(of range: NSRange) -> Double {
        naturalAdvance(of: range)
            + ((pinned.attribute(.kern, at: range.location, effectiveRange: nil) as? Double) ?? 0)
    }
    // Where each cell landed in this string, so the runs BETWEEN them can be pinned too.
    var matched: [(range: NSRange, placement: PageLine.GraphicCellPlacement)] = []
    // A GRAPHIC RUN'S OWN SPACES ARE CELLS TOO, and missing that is what made a box's
    // closing border miss its column by 59.82pt.
    //
    // `splitGraphics` treats a maximal run that STARTS and ENDS on a graphic character with
    // only graphic characters or spaces between as one graphic segment, so the model records
    // a cell for every character of it — BOX.WS's `│` + 21 spaces + `│` comes back as 23
    // cells, not 2. A walk that only looked at `graphicChars` matched the opening `│` against
    // cell 0, skipped every space without consuming its cell, and then compared the closing
    // `│` against cell 1, which is a SPACE: no match, so the closing border was never pinned
    // at all while the all-graphic border row above it was. That is the whole of the gap.
    //
    // Matched character by character against the cell list instead, advancing the list only
    // on an equal character. A character that does not match consumes nothing, which is what
    // lets the WORD JOINERS this renderer splices between adjacent graphic glyphs pass
    // through, and a run may only START on a graphic character, so a space in ordinary prose
    // before one cannot claim the run's first cell.
    var index = 0
    var placementIndex = 0
    var started = false
    while index < text.length, placementIndex < placements.count {
        let range = text.rangeOfComposedCharacterSequence(at: index)
        defer { index = NSMaxRange(range) }
        guard let character = text.substring(with: range).first else { continue }
        let placement = placements[placementIndex]
        guard placement.char == character else { continue }
        if !started {
            guard nativeGeometryChars.contains(character) else { continue }
            started = true
        }
        placementIndex += 1
        guard placement.width > 0 else { continue }
        let own = naturalAdvance(of: range)
        guard own > 0 else { continue }
        pinned.addAttribute(.kern, value: placement.width - own, range: range)
        matched.append((range, placement))
    }
    // AND THE TEXT BETWEEN TWO CELLS, which is what makes a box a box.
    //
    // Pinning only the cells themselves puts a row of `─` on the library's grid and leaves
    // the prose inside a `│ ... │` row on the reading face's own widths, so the closing
    // border of a box lands wherever that prose happens to end — measured on Modern's own
    // box evidence, 59.82pt right of where the top border closes.
    //
    // The model states each cell's absolute x as well as its width, so the gap between two
    // cells on the same visual line is stated too: `x(k+1) - (x(k) + width(k))`. Pinning the
    // run between them to that gap lands the closing border on the library's own column
    // whatever the prose measures. A pair whose x DECREASES is a pair the library put on two
    // different visual lines, and there is no gap between them to pin.
    for (first, second) in zip(matched, matched.dropFirst()) {
        let between = NSRange(location: NSMaxRange(first.range),
                              length: second.range.location - NSMaxRange(first.range))
        guard between.length > 0 else { continue }
        let wanted = second.placement.x - (first.placement.x + first.placement.width)
        guard wanted > 0 else { continue }
        var measured = 0.0
        var last = NSRange(location: NSNotFound, length: 0)
        var at = between.location
        while at < NSMaxRange(between) {
            let composed = text.rangeOfComposedCharacterSequence(at: at)
            let clamped = NSIntersectionRange(composed, between)
            guard clamped.length > 0 else { break }
            last = clamped
            measured += advance(of: clamped)
            at = NSMaxRange(composed)
        }
        guard last.location != NSNotFound else { continue }
        let existing = (pinned.attribute(.kern, at: last.location, effectiveRange: nil) as? Double) ?? 0
        pinned.addAttribute(.kern, value: existing + (wanted - measured), range: last)
    }
    return pinned
}

/// Planning #221 follow-up (Athena's ruling, 2026-09-08): a fixed-pitch run must advance at
/// the LIBRARY's pitch, not at the substituted face's own.
///
/// ## The defect this closes
///
/// Native substitutes the bundled Courier Prime for the document's Courier
/// (`CourierPrimeFontRegistration`). Courier Prime's `hmtx` gives every glyph an
/// advanceWidth of 1228 at unitsPerEm 2048 — 0.599609375 em, not the 0.6 em Courier is built
/// on and the engine's grid assumes. At a 12pt type size that is 7.1953125pt per character
/// against the library's 7.2pt column: a deficit of 0.0046875pt each, six and a half parts
/// in ten thousand, which ACCUMULATES one character at a time along the line.
///
/// It predicted the failures exactly before it was fixed. `appNativeViewMatchesTheWordStarCapture`
/// named rows at x=360 (column 50) with residuals of -0.20 to -0.23pt against a predicted
/// 50 x 0.0046875 = 0.234, and rows at x=504 (column 70) at -0.30 against a predicted 0.328.
/// The drift is neither rounding nor a scaled font: it is the face's own designed advance.
///
/// This also explains why that gate's licence ceiling kept moving. The ceiling was never
/// counting a font-substitution constant — it was counting how many words on a page happened
/// to sit far enough right for the accumulation to cross the 0.2pt tolerance, so anything
/// that pushed words rightward (today: bare-tab expansion) raised the count with no new
/// defect behind it.
///
/// ## Why the pitch comes from the engine
///
/// `spanPitch` is the emitter's OWN per-run pitch function, made public for this
/// (`PDFWriter.swift`). Deriving `0.6` here instead would be a second copy of the engine's
/// grid constant in a file whose whole job is to agree with it, and it would miss the case
/// `spanPitch` handles that a constant cannot: a font block carrying an explicit `.cw`
/// character width (`FontChange.width1800`), where the pitch is not an em fraction at all.
///
/// ## Why only fixed-pitch runs
///
/// A proportional run has no grid to land on — the engine advances it by its own widths and
/// scales it with `Tz` — so correcting it toward a per-character pitch would be wrong, not
/// merely unnecessary.
///
/// BOTH halves of the guard are load-bearing, and the first version of this had only one.
/// `NSFont.isFixedPitch` asks about the MAC face this app substituted; `FontChange
/// .proportional` is the LIBRARY's own answer about the document's font block, and they
/// disagree exactly where it matters — a document declaring a proportional face that
/// resolves to a fixed-pitch Mac fallback answers true to the first and is still a
/// proportional run the engine advances by its own widths. Correcting those to a
/// per-character pitch took -README from 43 divergences to 2174 and broke SAWYER and
/// VERSIONS, which had been passing: the words stopped matching at all rather than drifting.
/// The engine's flag decides; the face's own metric only says whether there is a uniform
/// advance to correct.
///
/// Modern never reaches here: every caller on this path passes `disableKerning: true`, and
/// Modern passes false.
/// EVERY GLYPH IN A FIXED-PITCH RUN OCCUPIES EXACTLY ONE CELL, whatever face draws it.
///
/// Athena's ruling, 2026-09-09: -SCREEN's cp437 line is fixed-pitch text on WordStar's own
/// column grid, and a substituted face does not change the grid. So the correction is not
/// "nudge Courier Prime onto the grid", it is "this cell is `spanPitch` wide" — and it holds
/// for the declared face, for a Greek fallback, and for a box-drawing fallback alike.
///
/// WHY THE PREVIOUS SHAPE WAS WRONG. It computed ONE kern for the whole run, from the
/// DECLARED face's advance, and `.kern` is added to whatever advance the face that actually
/// draws each glyph has. AppKit substitutes per character — Courier Prime carries no Greek
/// and no box drawing — so a run's single kern, derived from Courier Prime's 7.1953, was
/// added to a fallback's own 7.2012 and overshot. The first attempt at this papered over it
/// with a coverage guard that skipped any run the declared face could not fully cover, which
/// left -SCREEN's Greek uncorrected (it drew about 0.3pt wide per glyph, enough to push ink
/// into the next 12pt cell of the pixel oracle's grid) and was only ever right by accident
/// for box drawing.
///
/// Corrected per CHARACTER against the face that will actually render it, the arithmetic
/// stops depending on which face that is: each character's kern is `pitch` minus THAT
/// character's own advance in THAT face, so the effective advance is the cell, exactly, for
/// every glyph in the run.
///
/// Modern never reaches here: every caller on this path passes `disableKerning: true`, and
/// Modern passes false. A proportional run is still excluded — `FontChange.proportional` is
/// the library's own answer and the engine advances those by their own widths — as is a run
/// whose declared face is not fixed pitch at all.
@MainActor
func nativePinToCells(
    _ assembled: NSAttributedString, font: NSFont, entry: FontChange?
) -> NSAttributedString {
    guard font.isFixedPitch, entry?.proportional != true, assembled.length > 0 else {
        return assembled
    }
    let pitch = spanPitch(entry, Int(font.pointSize.rounded()))
    guard pitch > 0 else { return assembled }

    let out = NSMutableAttributedString(attributedString: assembled)
    let text = assembled.string as NSString
    // Per CHARACTER, reading the font the assembled run already carries for it — the
    // coverage split (job 447) and the graphic-font resolution have both run by now, so this
    // asks the same face that will actually be painted.
    var index = 0
    while index < text.length {
        let composed = text.rangeOfComposedCharacterSequence(at: index)
        let glyphFont = assembled.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            ?? font
        let character = text.substring(with: composed)
        let advance = nativeResolvedAdvance(of: character, in: glyphFont)
        if advance > 0 {
            out.addAttribute(.kern, value: Float(pitch - advance), range: composed)
        }
        index = composed.location + composed.length
    }
    return out
}

/// A GRAPHIC CELL IN MODERN COSTS ONE DECLARED CELL, whatever the face draws.
///
/// The library's `modernTokenWidth` splits a token that mixes geometry and prose and gives
/// each half its own rule: `total += Double(range.count) * pitch` for the graphic run — the
/// RAW `spanPitch`, never scaled by `faceTz` — and the tz-scaled natural width for the text
/// between. The app drew a graphic character at the covering face's own advance instead.
///
/// Measured on -README.WS's list rows, whose marker is the cp437 solid square: the library
/// draws it as geometry occupying an 8.4pt cell and starts the row's text 11.7pt in; the app
/// drew the glyph at about 5pt and started 8.4pt in, so every one of those rows measured
/// narrower than the library's and wrapped a word later.
///
/// `.expansion` is removed on the same range it kerns: the cell is the cell, and the library
/// applies no `Tz` to it.
@MainActor
func modernPinGraphicCells(
    _ assembled: NSAttributedString, entry: FontChange?, pt: Int
) -> NSAttributedString {
    guard assembled.length > 0 else { return assembled }
    let pitch = nativeSpanPitch(entry, pt)
    guard pitch > 0 else { return assembled }
    let text = assembled.string as NSString
    guard text.length > 0, (assembled.string.contains { graphicChars.contains($0) }) else {
        return assembled
    }
    // THE GRAPHIC CHARACTERS THEMSELVES, and not the spaces between them.
    //
    // The library's `graphicRunRanges` does treat a border-gap-border shape as ONE run and
    // charge `range.count * pitch` for the whole of it, interior spaces included, and pinning
    // those interiors here looked like the faithful port. It is not: job 512 already pins a
    // box row's interior, to the neighbouring BORDER GLYPH's own advance in the face that
    // actually draws it, which is what makes a box's right edge line up on screen. Pinning
    // the same spaces to `spanPitch` on top of that took BOXES.WS's interior rows to
    // x=222.70 against a top border at x=165.60 — a 57pt overhang, five rows of it. Measured
    // both ways: the interior pin moved no gate row in either direction, and it breaks this
    // one, so the graphic characters keep the cell and the gaps keep job 512's.
    let out = NSMutableAttributedString(attributedString: assembled)
    var index = 0
    while index < text.length {
        let composed = text.rangeOfComposedCharacterSequence(at: index)
        index = composed.location + composed.length
        let piece = text.substring(with: composed)
        guard let character = piece.first, graphicChars.contains(character),
              let glyphFont = assembled.attribute(.font, at: composed.location,
                                                  effectiveRange: nil) as? NSFont
        else { continue }
        let advance = nativeResolvedAdvance(of: piece, in: glyphFont)
        guard advance > 0 else { continue }
        out.removeAttribute(.expansion, range: composed)
        out.addAttribute(.kern, value: Float(pitch - advance), range: composed)
    }
    return out
}


/// Batch 47 (M27, Jon: Modern's ■ bullets were far larger than Native's and Printed's, and the text after them too
/// close): every ■ in a Modern text is marked with its cell's width (`.modernCellSquare`: its own advance and the kern
/// its cell pin gave it), so the layout manager draws Native's square there in place of the reading face's glyph. Measured
/// on -README.WS (b47-m27-probe):
/// Native's square inks 5.0 pt with 9.0 pt to the next word's ink; Modern's Courier New ■ inked 8.5 pt with 2.5 pt.
/// Idempotent: a ■ already marked is left as it is.
@MainActor
public func markModernSquareBullets(_ text: NSMutableAttributedString) {
    let string = text.string as NSString
    var search = NSRange(location: 0, length: string.length)
    while search.length > 0 {
        let found = string.range(of: "\u{25A0}", options: [.literal], range: search)
        guard found.location != NSNotFound else { break }
        search = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        guard text.attribute(.modernCellSquare, at: found.location, effectiveRange: nil) == nil,
              let font = text.attribute(.font, at: found.location, effectiveRange: nil) as? NSFont else { continue }
        let kern = (text.attribute(.kern, at: found.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        let cell = nativeResolvedAdvance(of: "\u{25A0}", in: font) + kern
        guard cell > 0 else { continue }
        text.addAttribute(.modernCellSquare, value: NSNumber(value: cell), range: found)
        // The gap after a LIST's ■ is `modernBulletGapCell`'s, scoped to the rows the engine calls bullets.
    }
}

/// One character's real advance, in points, in the face AppKit will actually draw it with —
/// `font` when it has a glyph, and CoreText's own substitute when it does not, which is the
/// same decision AppKit's own layout makes.
@MainActor
func nativeResolvedAdvance(of character: String, in font: NSFont) -> Double {
    let key = NativeAdvanceKey(font: font.fontName, size: Double(font.pointSize),
                                character: character)
    if let cached = nativeAdvanceCache[key] { return cached }
    let string = character as CFString
    let resolved = CTFontCreateForString(font as CTFont, string,
                                         CFRange(location: 0, length: CFStringGetLength(string)))
    var characters = Array(character.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    var advance = 0.0
    if CTFontGetGlyphsForCharacters(resolved, &characters, &glyphs, characters.count) {
        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(resolved, .horizontal, &glyphs, &sizes, glyphs.count)
        // A surrogate pair is one character and one glyph plus a zero-advance mate; summing
        // is correct for both cases and needs no special case.
        advance = sizes.reduce(0.0) { $0 + Double($1.width) }
    }
    nativeAdvanceCache[key] = advance
    return advance
}

/// Past any attachment characters at `location` the next piece does not begin with: a print
/// control's spacer (`pctlAdvanceAttachment`) is in the line but not in the engine's pieces,
/// which only start that much further in.
func nativeSkipAttachments(in text: NSString, from location: Int, before piece: String) -> Int {
    guard !piece.hasPrefix("\u{FFFC}") else { return location }
    var at = location
    while at < text.length, text.character(at: at) == 0xFFFC { at += 1 }
    return at
}

/// Where AppKit sets the glyph of each given character, one line laid out alone.
@MainActor
func nativeGlyphStarts(_ line: NSAttributedString, at locations: [Int]) -> [Double] {
    let storage = NSTextStorage(attributedString: line)
    let manager = softReturnLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 100_000, height: 10_000))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    return locations.map { location in
        guard location < storage.length else { return 0 }
        return Double(manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: location)).x)
    }
}

/// Keyed on the face's NAME rather than the `NSFont` itself: two `NSFont` values for the same
/// face and size are equal for this purpose and hashing the object would miss the cache.
struct NativeAdvanceKey: Hashable {
    let font: String
    let size: Double
    let character: String
}

/// Measured once per (face, size, character) and reused. The corpus draws millions of
/// characters through this and CoreText's own fallback resolution is the expensive part.
@MainActor private var nativeAdvanceCache: [NativeAdvanceKey: Double] = [:]


/// Disables AppKit's default LIGATURES on every Native-style string this renderer builds,
/// for exactly the reason `nativeNoKerning` above disables kerning — and unlike that one,
/// this is CONFIRMED by a measurement rather than applied on principle.
///
/// A Native facsimile is fixed pitch: every character occupies one 7.2pt Courier cell,
/// because that is what WordStar on a LaserJet put on the paper. `NSAttributedString`
/// defaults to `.ligature: 1`, so AppKit was drawing `fi` as a SINGLE glyph in one cell
/// where the capture has two. Everything after it on the line then sits exactly one column
/// left.
///
/// Caught by the PCL coordinate tier against the real WS7 captures, 2026-09-07, on
/// SCRIPT.WS page 10: the capture's `file` came back from the app's own PDF as one ligature
/// glyph plus `le`, and the four words after it on that line each measured -7.18, -7.22,
/// -7.26 and -7.28pt against the capture — one Courier column, accumulating by a hundredth
/// as the line runs on. The engine renders the same document CLEAN against the same
/// capture, because `emitPDF` places every character itself and never asks a font to
/// ligate.
///
/// PRINTED ONLY. Modern is a modern reading surface and its typography is deliberately not
/// a facsimile, so this is applied where `nativeNoKerning` is and nowhere else.
let nativeNoLigatures: Int = 0

/// Banker's rounding, matching the engine's own `roundHalfToEven`. Swift's
/// `.toNearestOrEven` is the same rule; spelled out here because the engine's helper is
/// `internal`.
func nativeRoundHalfToEven(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

/// Whether this span's face is the engine's `PDFFamily.courier` — the only family with a
/// measured mechanism-G ratio of its own.
///
/// Mirrors `PDFFonts.swift`'s `pdfFamily`, in its own order: a span with NO font block at
/// all is Courier (every WS4 file and every print stream); a symbol/dingbat transliteration
/// is not; otherwise the DECISIVE monospace bit decides. That last test goes through
/// `nativeMacIsMonospace` -> the engine's own shared public `resolveFont`, which is the
/// same call `pdfFamily`'s `!entry.proportional` short-circuit and its `monoFamilies`
/// prefix scan between them amount to — see `nativeMacIsMonospace`'s own doc comment on
/// why this app asks that one question rather than reimplementing the bit test.
func nativeFamilyIsCourier(_ entry: FontChange?) -> Bool {
    guard let entry else { return true }
    let name = (entry.typestyleName ?? "").lowercased()
    if name.hasPrefix("symbol") || name.contains("dingbat") { return false }
    switch entry.symbolMap {
    case .math, .symbols: return false
    case .cp437, .cp850: break
    }
    return nativeMacIsMonospace(entry)
}

/// The engine's `spanPitch` (`PDFWriter.swift`): the LaserJet driver's pitch for a fixed font
/// (`pitch1800`, set on Native's fonts by `NativeEngineWork`), else a font block's own declared
/// width word when it has one (1/1800in units, `hmiPerPoint` = 1800/72 = 25), else Courier's
/// 0.6em at the span's declared size. Both are `public` on `FontChange`, so this reads the
/// same fields the emitter does rather than re-deriving a pitch from AppKit metrics.
func nativeSpanPitch(_ entry: FontChange?, _ pt: Int) -> Double {
    if let width = entry?.pitch1800 ?? entry?.width1800, width != 0 { return Double(width) / (1800.0 / 72.0) }
    return Double(pt) * 0.6
}

/// Job 226: a running head/foot carries WordStar's OWN embedded print-control bytes
/// verbatim — `parseHeadFoot`/`decodeHeadFootText` (`ParseWS.swift:1366`/`1401`) keep the
/// text "as content, not command syntax" (that file's own comment) and never intercept
/// them the way `decodeSpans` does for body text (LJ6DTP's own `.H1` wraps its title in a
/// bold toggle, `\u{02}...\u{02}` — confirmed on this fixture by direct inspection). The
/// engine's `esc(_:)`/`cp1252Encode` pass a C0 control through as its own raw byte value
/// (cp1252 is ASCII-identity there), landing in the PDF's `Tj` string at a codepoint
/// `/WinAnsiEncoding` has no GLYPH for — a PDF viewer (PDFKit, this oracle's reference)
/// draws nothing for an undefined code, but for a monospaced base-14 font (Courier's own
/// `/MissingWidth`, uniform with every other glyph's) STILL ADVANCES the pen by one
/// character cell — confirmed empirically (a direct pixel sample of this oracle's own
/// reference bitmap, not assumed): the reference's visible text starts exactly TWO
/// character-cells later than a naive removal produces. AppKit has no such notion of a
/// per-font missing-glyph width; asked to lay out a real `NSFont` glyph for U+0002 it
/// would reserve ITS OWN (real) advance, and outright deleting the character (this fix's
/// first attempt) undershoots the reference by those same two cells the other way. A
/// plain space reproduces the reference's actual behaviour exactly: same fixed-pitch
/// advance, zero ink — without inventing a bold-toggle PORT (this renderer has no
/// running-head style support at all, and adding one is out of this fix's scope; see
/// this job's LESSONS).
func nativeStripControlChars(_ text: String) -> String {
    // AND `∙` IS A MIDDLE DOT IN PRINTED — `escFallback`'s own mapping (U+2219 -> U+00B7),
    // not `runningOps`' fast-path one, which was U+2219 -> U+2022. Which of the two the engine applies
    // depends on the line: the fast path is for a running head with NO toggle bytes of its
    // own, and a head that has them goes run by run through `esc`, where `escFallback`
    // decides. LJ6DTP.WS's `.h1` wraps its title in a bold toggle, so it takes the second
    // path — measured, its PDF draws a middle dot, and the app drew the BULLET OPERATOR
    // itself, which is a third glyph again.
    //
    // Both paths now agree: the fast path and `hfRuns` map `∙` to the middle dot too, the
    // small dot the LaserJet prints for 0xF9 (planning #586), and so does Modern.
    String(text.unicodeScalars.map { scalar -> Character in
        if scalar.value == 0x2219 { return "\u{00B7}" }
        return scalar.value >= 0x20 && scalar.value != 0x7F ? Character(scalar) : " "
    })
}

/// Job 489 (b29 adoption): port of the engine's own `hfToggles`/`hfRuns` (`EmitRTF.swift`,
/// not `public`, so re-derived here rather than imported) — a running head/foot's raw text
/// can carry WordStar's own print-toggle bytes verbatim (LJ6DTP's `.h1` is
/// `^B^BLJ6DTP ... ^B`), and a document whose `.h#`/`.f#` opened with its own font block
/// (`Document.headerFonts`/`footerFonts`, register C6) needs those bytes INTERPRETED —
/// consumed as style flips, never drawn as literal control characters — the same way the
/// engine's `hfLineOps` reads them, rather than degraded to blank spaces the way
/// `nativeStripControlChars` treats every OTHER control byte. Only reached when a font
/// block is present; the plain (no font block) path below is untouched and still uses
/// `nativeStripControlChars` alone.
let nativeHFToggles: [UInt32: Style] = [
    0x02: .bold, 0x19: .italic, 0x13: .underline,
    0x14: .sup, 0x16: .sub, 0x18: .strike,
]

/// A running-head/foot string -> [(text, styles)], WordStar's own toggle bytes interpreted
/// and every other control byte dropped (not space-degraded). Returns `[]` for a head that
/// is nothing but control bytes — the caller treats that as "nothing to draw," matching
/// `hfRuns`'s own doc comment. Port of `hfRuns` (`EmitRTF.swift`, CtrlKD).
func nativeHeadFootRuns(_ text: String) -> [(text: String, styles: Style)] {
    var runs: [(text: String, styles: Style)] = []
    var buf = ""
    var active: Style = []
    func flush() {
        if !buf.isEmpty { runs.append((buf, active)); buf = "" }
    }
    for scalar in text.unicodeScalars {
        if scalar.value == 0x2219 { buf.unicodeScalars.append(Unicode.Scalar(0x00B7)!); continue }
        if let toggle = nativeHFToggles[scalar.value] {
            flush()
            active.formSymmetricDifference(toggle)
            continue
        }
        if scalar.value < 0x20 { continue }
        buf.unicodeScalars.append(scalar)
    }
    flush()
    guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
    return runs
}

/// Fixed-pitch era faces, matched on the typestyle NAME — same list and same "run before the
/// generic-style bits" ordering as the engine's `monoFamilies` (`PDFFonts.swift`), and for the
/// same reason: the spec's own `Courier` font block declares generic style `serif`.
let nativeMonoFamilies = ["courier", "pica", "elite", "lineprinter"]


/// Job 256 (Show Invisibles, part 2/4): the ink every invisible mark draws in — same gray
/// for all five classes (dot commands, comments, style toggles, soft/hard returns,
/// page-break origin). `NSColor(white: 0.45, alpha: 0.55)` is the spec's own starting
/// point; part 4 tunes the exact value with Jon's own eyes.
///
/// Internal rather than `private` so `SoftReturnTests` can identify a mark run directly by
/// its own colour, the same "loosen to internal for test access" convention `attributedLine`
/// itself already uses.
///
/// Job 258 (Show Invisibles part 4/4): `var`, not `let` — the evidence-sheet harness renders
/// the SAME page at several alphas for Jon's own eyes to pick from (this job's brief: "the
/// judgment... belongs to JON, this job's deliverable is the EVIDENCE SHEET"), restoring the
/// shipped default immediately after each capture. `nonisolated(unsafe)` because a top-level
/// `var` is otherwise flagged as unguarded shared mutable state under Swift 6 strict
/// concurrency; every read/write in practice happens on the main actor (rendering only ever
/// runs there) so there is no real data race, matching the `nonisolated(unsafe) static var`
/// convention this codebase already uses for other test-mutated globals.
nonisolated(unsafe) var invisibleMarkColour = NSColor(white: 0.45, alpha: 0.55)

/// One Show Invisibles mark, as both annotated renders draw it: `invisibleMarkColour`, tagged `.invisibleMarkRun` so
/// Copy leaves it out, and spoken as `spoken` by VoiceOver.
func invisibleMarkRun(_ text: String, font: NSFont, spoken: String, paragraph: NSParagraphStyle) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: invisibleMarkColour,
        .paragraphStyle: paragraph,
        .accessibilityAnnotationTextAttribute: [[NSAccessibility.AnnotationAttributeKey.label: spoken]],
        .invisibleMarkRun: true,
    ])
}

/// Job 258 (Show Invisibles part 4/4, edge sweep): tags every character `markRun` (below)
/// draws — real characters in the SAME `NSTextStorage` as the document's own text (see this
/// file's top doc comment on why there is only one) — so `PageTextView.copy(_:)`
/// (`PagedDocumentView.swift`) can exclude invisible-ink marks from what lands on the
/// pasteboard: the spec's own default is that Cmd-C copies the document, not the screen
/// furniture Show Invisibles draws alongside it. A dedicated key rather than filtering by
/// `.foregroundColor == invisibleMarkColour` avoids an `NSColor` equality check that can
/// silently fail across colour spaces.
extension NSAttributedString.Key {
    public static let invisibleMarkRun = NSAttributedString.Key("SoftReturn.invisibleMarkRun")

    /// Planning #222: tags the invisible spacer paragraph `modernLeadingSpacer` inserts
    /// before an oversized-title line (job 434), so a reader can identify one BY
    /// CONSTRUCTION instead of by guessing at its shape.
    ///
    /// `InvisiblesModernLayoutOracle` used to recognise a spacer as "a paragraph style with
    /// `minimumLineHeight == maximumLineHeight > 0`", on the stated grounds that
    /// `modernParagraphStyle` never sets either field. That was true when it was written and
    /// stopped being true the moment Modern's leading was pinned to the library's 1.2x — at
    /// which point EVERY ordinary paragraph matched the spacer signature, the oracle's
    /// paired-skip walked over real content, and three fixtures reported divergences whose
    /// every measurable input was identical. Same reasoning as `invisibleMarkRun` above: a
    /// dedicated key beats an inference that can silently start matching everything.
    public static let modernLeadingSpacer = NSAttributedString.Key("SoftReturn.modernLeadingSpacer")

    /// THE BASE-14 `/BaseFont` NAME THE LIBRARY'S OWN MODERN PDF WOULD SET THIS RUN IN,
    /// carried on the run so a measurement can ask the AFM tables about it.
    ///
    /// Modern only (`attributedRun`'s own `modernPitchScale` gate — Printed and Native never
    /// carry it). It exists for `modernAscentDeficit`, which computes the leading spacer's
    /// height from the library's tables rather than from AppKit's glyph-path bounds, and the
    /// face name is the one input that cannot be recovered from the laid-out string: the run
    /// is SET in a real Mac face, and the mapping from that face back to the base-14 row is
    /// not one-to-one (Courier Prime and Courier New both stand in for `Courier`). Recorded
    /// where `pdfFamily` is already in hand rather than guessed at later from a family name.
    public static let modernBase14 = NSAttributedString.Key("SoftReturn.modernBase14")
}
