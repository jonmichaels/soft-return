// PDFLaserJet.swift
//
// Printed's side of WS7's LASERJET driver (`LaserJet.swift` is the driver): which of a
// document's fonts it places, and the helpers a line, a justified line and a running head or
// foot share to draw its pieces. Port of the `_laserjet_fonts`/`_lj_*` helpers in ctrl-kd's
// `pdf.py`.

import Foundation

/// `fonts`, each proportional font that WS7's driver prints in one of its own proportional text
/// fonts marked with that driver, `laserjet` or `lj6dtp` (Sawyer's LJ6DTP, for a document last
/// printed through it): its words are placed with the driver's own widths and kerning
/// (`LaserJet.swift`). A symbol font keeps its own path. Under LJ6DTP a font the driver prints
/// in a bitmap face is marked `bitmap`: its sub/superscripts keep the line's size (WS7 teardown
/// 17.8). A fixed-pitch font of a document printed through one of `ljFixedPitchDrivers`
/// carries `pitch1800`, the driver's own pitch for it (`spanPitch`). Port of `_laserjet_fonts`.
func laserjetFonts(_ fonts: [FontChange], driver printerDriver: String?) -> [FontChange] {
    let named = (printerDriver ?? "").trimmed().uppercased()
    let driver: LaserJet.Driver = named == "LJ6DTP" ? .lj6dtp : .laserjet
    return fonts.map { f in
        var marked = f
        if f.proportional, f.symbolMap == .cp437 || f.symbolMap == .cp850,
           LaserJet.block(for: f, bold: false, italic: false, driver: driver) != nil,
           let font = LaserJet.font(for: f, driver: driver), font.key & 0x2000 == 0 {
            marked.laserjet = driver
        } else if f.proportional, f.symbolMap == .cp437 || f.symbolMap == .cp850,
                  let pitch = LaserJet.fixedPitch1800(f, driver: driver), pitch != 0 {
            // A proportional record the driver matches to one of its fixed fonts (a display
            // face wider than any it has: Broadway, Uncial) prints in that font, at its pitch.
            marked = FontChange(offset: f.offset, width1800: pitch, height1440: f.height1440,
                                typestyle: f.typestyle & ~0x8000)
        } else if let pitch = ljFixedPitch(f, named: named, driver: driver) {
            marked.pitch1800 = pitch
        }
        if driver == .lj6dtp && LaserJet.isBitmap(marked, driver: driver) {
            marked.bitmap = true
        }
        return marked
    }
}

/// The drivers whose fixed-pitch fonts advance at the driver's own pitch, not the record's
/// width: LASERJET, Sawyer's LJ6DTP, and HP4, whose faces and widths are LASERJET's (WS7
/// teardown 11.17, 7a and 8). Port of `_LJ_FIXED_PITCH_DRIVERS`.
private let ljFixedPitchDrivers: Set<String> = ["LASERJET", "LJ6DTP", "HP4"]

/// The pitch, in 1/1800 inch, a fixed-pitch record of a document printed through `named`
/// advances at: the driver font it matches, whatever its own width, which only picks the font
/// (WS7 teardown 11.17, 7a). Nil for a proportional or symbol record, another driver, or a
/// record the driver prints in a proportional font.
private func ljFixedPitch(_ f: FontChange, named: String, driver: LaserJet.Driver) -> Int? {
    guard ljFixedPitchDrivers.contains(named), !f.proportional,
          f.symbolMap == .cp437 || f.symbolMap == .cp850,
          let pitch = LaserJet.fixedPitch1800(f, driver: driver), pitch != 0 else { return nil }
    return pitch
}

/// `fonts` with each fixed-pitch font's `pitch1800` set as `laserjetFonts` sets it, and nothing
/// else changed, for a view that resolves the document's own fonts (Native): its fixed-pitch
/// text advances at the pitch Printed places it at.
public func laserjetFixedPitches(_ fonts: [FontChange], driver printerDriver: String?) -> [FontChange] {
    let named = (printerDriver ?? "").trimmed().uppercased()
    let driver: LaserJet.Driver = named == "LJ6DTP" ? .lj6dtp : .laserjet
    return fonts.map { f in
        var out = f
        out.pitch1800 = ljFixedPitch(f, named: named, driver: driver)
        return out
    }
}

/// Whether LJ6DTP prints `entry` in one of its bitmap faces, whose sub/superscripts keep the
/// line's size (WS7 teardown 17.8; `laserjetFonts`'s `bitmap`), for a view that sets the run in
/// its own face (Native).
public func lj6dtpBitmapFont(_ entry: FontChange?) -> Bool {
    entry.map { LaserJet.isBitmap($0, driver: .lj6dtp) } ?? false
}

/// A running head's text as the document wrote it: the head draws its dot as · where the
/// document has the F9 glyph ∙, and the driver measures the document's.
func ljHeadSource(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for s in text.unicodeScalars { out.append(s == "·" ? "∙" : s) }
    return String(out)
}

/// `text` as the driver measures it: the document's own characters. Port of `_lj_measured`.
func ljMeasured(_ text: String, _ entry: FontChange) -> String {
    entry.laserjet == .lj6dtp ? ljUnsubstituted(text) : text
}

/// What two spans share for a kerning pair to work across them: the driver block, the size,
/// the script and the underline. Port of `_lj_key`.
struct LJKey: Equatable {
    let block: ObjectIdentifier
    let tw: Int
    let sup: Bool
    let sub: Bool
    let underline: Bool
}

/// The driver block and size (twips) a span is measured at. Port of `_lj_block`.
func ljBlock(_ entry: FontChange, _ styles: Style, _ sizeHere: Int)
    -> (block: LaserJet.Block, tw: Int)
{
    let block = LaserJet.block(for: entry, bold: styles.contains(.bold),
                               italic: styles.contains(.italic), driver: entry.laserjet!)!
    let script = styles.contains(.sup) || styles.contains(.sub)
    return (block, LaserJet.twips(block, Double(sizeHere), script: script))
}

func ljKey(_ block: LaserJet.Block, _ tw: Int, _ styles: Style) -> LJKey {
    LJKey(block: ObjectIdentifier(block), tw: tw, sup: styles.contains(.sup),
          sub: styles.contains(.sub), underline: styles.contains(.underline))
}

/// `(key, last character's code)` for the span after this one to kern against, or nil when this
/// span is not driver-placed or ends in a blank, a tab or a print control. Port of `_lj_last`.
func ljLast(_ seg: LineSegment) -> (key: LJKey, code: Int)? {
    guard let entry = seg.entry, entry.laserjet != nil, let last = seg.text.unicodeScalars.last,
          !String(last).isPythonSpaceOnly,
          seg.pctlHMI == nil, seg.tabHMI == nil,
          !seg.text.contains(where: { graphicChars.contains($0) })
    else { return nil }
    let (block, tw) = ljBlock(entry, seg.styles, seg.size)
    return (ljKey(block, tw, seg.styles),
            LaserJet.code(ljMeasured(String(last), entry).unicodeScalars.first!))
}

/// `text` placed by WS7's LASERJET driver, `[(piece, xPt, widthPt)]` from the start of `text`,
/// or nil when `entry` is not one of the driver's proportional fonts (`laserjetFonts`). A word
/// is split where a kerning pair applies. `sizeHere` is the span's own declared size; a
/// sub/superscript is measured at the driver's own script size.
///
/// `prev` is `ljLast` of the span before: a pair still applies across a record for the same
/// font, at the same size, script and underline, so the first piece may start left of the
/// span's own start. `source` is the document's own text when `text` has had a character
/// swapped for display one for one (a running head's bullet). Port of `_lj_pieces`.
func ljPieces(_ text: String, _ entry: FontChange?, _ styles: Style, _ sizeHere: Int,
              kerning: Bool, prev: (key: LJKey, code: Int)? = nil, source: String? = nil)
    -> [(text: String, x: Double, width: Double)]?
{
    guard let entry, entry.laserjet != nil else { return nil }
    let (block, tw) = ljBlock(entry, styles, sizeHere)
    let measured = ljMeasured(source ?? text, entry)
    var lead = 0
    if kerning, let prev, let first = text.unicodeScalars.first,
       !String(first).isPythonSpaceOnly, prev.key == ljKey(block, tw, styles) {
        lead = LaserJet.kernDots(block, tw, prev.code, LaserJet.code(measured.unicodeScalars.first!))
    }
    // The pieces come from the measured text; each is shown as the span's own text.
    var shown = Array(text.unicodeScalars)[...]
    var out: [(text: String, x: Double, width: Double)] = []
    for p in LaserJet.pieces(measured, block, tw, kerning: kerning) {
        let measuredScalars = Array(p.text.unicodeScalars)
        let n = measuredScalars.count
        let piece = Array(shown.prefix(n))
        shown = shown.dropFirst(n)
        if entry.laserjet == .lj6dtp, n > 1, piece.contains("©") {
            // LJ6DTP's © is its own glyph from another symbol set (`ljCopyright`): a piece of
            // its own, at the driver's x.
            var x = p.x
            var start = 0
            while start < n {
                let isCopy = piece[start] == "©"
                var end = start + 1
                while !isCopy, end < n, piece[end] != "©" { end += 1 }
                let rw = measuredScalars[start..<end].reduce(0) {
                    $0 + LaserJet.charDots(block, tw, LaserJet.code($1))
                }
                var run = String.UnicodeScalarView()
                run.append(contentsOf: piece[start..<end])
                out.append((String(run), LaserJet.dotsToPt(block, x + lead), LaserJet.dotsToPt(block, rw)))
                x += rw
                start = end
            }
        } else {
            var run = String.UnicodeScalarView()
            run.append(contentsOf: piece)
            out.append((String(run), LaserJet.dotsToPt(block, p.x + lead), LaserJet.dotsToPt(block, p.width)))
        }
    }
    return out
}

/// LJ6DTP prints its © from the PS Math symbol set (its manual, page 3): E3, a sans-serif C, in
/// Arial, Omega and Univers; D3, a serif C, in Times and Times New Roman. Those are Symbol's own
/// copyrightsans and copyrightserif. Port of `_LJ6DTP_COPYRIGHT`.
func ljCopyright(_ family: PDFFamily) -> UInt8 {
    family == .helvetica ? 0xE3 : 0xD3
}

/// The x the driver moves a piece to: its dot position floored to a whole decipoint (`&a#H`),
/// as points. `x` is on the dot grid already. Port of `_lj_x`.
func ljX(_ x: Double) -> Double {
    (x * 10.0 + 1e-6).rounded(.down) / 10.0
}

/// Whether piece `i` of a driver-placed span is a lone symbol: one character, neither letter
/// nor digit, with a blank or nothing either side (a bullet, a © standing by itself). Port of
/// `_lj_alone`.
func ljAlone(_ pieces: [(text: String, x: Double, width: Double)], _ i: Int) -> Bool {
    let blank = { (k: Int) in !pieces[k].text.contains(where: { !$0.isWhitespace }) }
    let scalars = pieces[i].text.unicodeScalars
    guard scalars.count == 1, let s = scalars.first,
          !CharacterSet.alphanumerics.contains(s), !CharacterSet.whitespacesAndNewlines.contains(s)
    else { return false }
    return (i == 0 || blank(i - 1)) && (i == pieces.count - 1 || blank(i + 1))
}

/// The horizontal scale that draws `piece` in `baseFont` at `pt` to the width the driver gave
/// it (`tzScale`'s fit), in hundredths; 100 for a blank. A lone symbol (`ljAlone`) narrower
/// than its width is never stretched: the printer drew its own glyph at the cursor, so the
/// stand-in's is drawn there at its own width (a bullet stays round). Port of `_lj_piece_tz`.
func ljPieceTz(_ piece: String, _ baseFont: String, _ pt: Double, _ width: Double,
               alone: Bool = false) -> Int {
    if !piece.contains(where: { !$0.isWhitespace }) { return hundredths(tzDefault) }
    if alone {
        let natural = stringWidthPt(piece, baseFont, pt)
        if natural > 0, natural < width { return hundredths(tzDefault) }
    }
    let (scale, _) = tzScale(piece, baseFont, pt, width)
    return hundredths(scale ?? tzDefault)
}

/// `[(text, x, width)]`: a driver-placed span's pieces (`plan`, as `lineOpsPrinted` builds it)
/// with each word that a kerning pair split joined back into one, from its first piece's x to
/// its last one's end. Port of `_lj_words`.
func ljWords(_ plan: [(piece: String, x: Double, width: Double)])
    -> [(text: String, x: Double, width: Double)]
{
    var out: [(text: String, x: Double, width: Double)] = []
    for (piece, x, w) in plan {
        if let last = out.last, piece.first != " ", last.text.last != " " {
            out[out.count - 1] = (last.text + piece, last.x, x + w - last.x)
        } else {
            out.append((piece, x, w))
        }
    }
    return out
}
