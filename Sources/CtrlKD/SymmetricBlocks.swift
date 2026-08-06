/// WS5+ 1D symmetric block stripping — the pre-pass `parseWS` runs on ws5+ documents
/// before `linesPass`. Direct port of `_symmetric_blocks` + `_parse_note` +
/// `_strip_dot_commands` + `_tab_columns` (Python ctrl-kd 1.2.0, core.py). Verified
/// against the 86 WS7 documents in Robert J. Sawyer's WordStar archive (per the Python
/// docstring); ported literally, guard conditions included, rather than "cleaned up."
///
/// A `0x1D` symmetric sequence is `0x1D` + 2-byte little-endian body length + body,
/// with a command byte at the start of the body. This pass rewrites the byte stream:
/// footnote/endnote/annotation blocks are extracted to `notes` and replaced with a
/// `SENT_FNREF` sentinel (comments never get one — WordStar never printed them
/// inline); structural blocks (tab, end-of-page, paragraph style) become either bytes or
/// another sentinel; anything else is preserved as an `UnknownBlock` rather than
/// dropped. The result feeds `linesPass`, which never sees a `0x1D` byte from a
/// well-formed ws5+ document.

/// A structural event that used to be an in-band SENTINEL BYTE, now carried as an
/// offset into the cleaned stream.
///
/// RETIRED 2026-08-04: `SENT_FNREF` (`0x00`), `SENT_SOFTPAGE` (`0x0B`) and
/// `SENT_HEADING` (`0x11`). Every byte available for a sentinel is a documented
/// WordStar control code, and all three occur in real archive documents outside any
/// block:
///
///     0x00  ^@  fix the print position     2328 occurrences in 5 documents
///     0x0B  ^K  index marker                 21 occurrences in 3
///     0x11  ^Q  custom print control         37 occurrences in 5
///
/// A literal ^K produced a page break the author never wrote; a literal ^Q, a heading;
/// a literal ^@, a reference to a footnote that does not exist. `SENT_FNREF` had been
/// moved ONTO `0x00` two days earlier on the reasoning that "NUL is not text in a
/// WordStar body" — the spec assigns `0x00` to ^@, so that traded a rare clash for a
/// common one.
///
/// Offsets are the pattern `tabAt` already used for exactly this reason.
public enum StructuralMark: Hashable, Sendable {
    case fnref
    case softpage
    /// A paragraph-style SELECTION: word 0 of the 0x11 block's four LE16 handles. The
    /// handle is resolved against the document's own style library in `parseWS` -- this
    /// pass has no library to resolve against.
    case style(handle: Int)
    /// A FONT CHANGE (0x02/0x15), carrying its index into `Document.fonts`. A font change
    /// is a RUN BOUNDARY in the text, not only metadata: Jon's export review
    /// (2026-08-04) found every RTF in Times because `fonts` was recorded and never
    /// rendered. Same offset mechanism as every other mark.
    case font(index: Int)
    /// A COLOUR CHANGE (0x01), carrying the palette index. Also a run boundary — a
    /// driver-aware renderer (LJ6DTP) honours it as a fill gray. Register C2.
    case colour(index: Int)
    /// A 0x0F user print control's DISPLAY STRING, decoded as ONE span carrying the
    /// block's declared HMI width and its byte length in the cleaned stream — screen-only
    /// content that a printed renderer replaces with blank space of that width. See
    /// `Span.pctlHMI`.
    case pctl(hmi: Int, byteLen: Int)
}

/// Symmetrical-sequence "Notes" types (WordStar 7.0 file format spec, WordStar
/// International, 1992): 3 Footnote, 4 Endnote, 5 Annotation, 6 Comment. All four are
/// rendered inline via a reference marker except comments, which WordStar never
/// prints — they're only reachable through `Document.notes`/`.comments`-style filtering.
private func noteKind(forCmd cmd: Int) -> NoteKind? {
    switch cmd {
    case 0x03: return .footnote
    case 0x04: return .endnote
    case 0x05: return .annotation
    case 0x06: return .comment
    default: return nil
    }
}

/// Result of a symmetric-blocks pass: the rewritten byte stream, every note extracted
/// from it (in document order), and every symmetrical-sequence type this pass doesn't
/// interpret (preserved, not dropped).
public struct SymmetricBlocksResult: Hashable, Sendable {
    public let bytes: [UInt8]
    public let notes: [Note]
    public let unknownBlocks: [UnknownBlock]
    /// INSET picture paths, in document order — one per `[image: NAME]` placeholder in
    /// the rewritten stream. Register C10.
    public let graphics: [String]

    public let colours: [ColourChange]
    public let fonts: [FontChange]
    public let includes: [String]
    public let shiftRuns: [ShiftRun]
    public let printerDriver: String?
    /// The type 0 header sequence's own fields — release and style-library pointer.
    /// `nil` when no 0x00 block carried either.
    public let header: WSHeader?
    /// Offsets into `bytes` at which TAB-derived padding begins — `linesPass` needs to
    /// tell a program-emitted indent from one the author typed. A3.
    public let tabAt: Set<Int>
    /// Structural events by offset into `bytes` — what the sentinel bytes used to be.
    /// MULTI-VALUED per offset: adjacent 0x1D blocks add no text between them, so a
    /// colour change and a font block (LJ6DTP, offset 178) — or a style and a font — can
    /// legitimately mark the very same offset.
    public let marks: [Int: [StructuralMark]]

    public init(bytes: [UInt8], notes: [Note], unknownBlocks: [UnknownBlock],
                graphics: [String] = [], colours: [ColourChange] = [],
                fonts: [FontChange] = [], includes: [String] = [],
                shiftRuns: [ShiftRun] = [], printerDriver: String? = nil,
                header: WSHeader? = nil,
                tabAt: Set<Int> = [], marks: [Int: [StructuralMark]] = [:]) {
        self.header = header
        self.tabAt = tabAt
        self.marks = marks
        self.colours = colours
        self.fonts = fonts
        self.includes = includes
        self.shiftRuns = shiftRuns
        self.printerDriver = printerDriver
        self.bytes = bytes
        self.notes = notes
        self.unknownBlocks = unknownBlocks
        self.graphics = graphics
    }
}

public func symmetricBlocks(_ data: [UInt8]) -> SymmetricBlocksResult {
    var out: [UInt8] = []
    var notes: [Note] = []
    var unknownBlocks: [UnknownBlock] = []
    var graphics: [String] = []
    var colours: [ColourChange] = []
    var fonts: [FontChange] = []
    var includes: [String] = []
    var shiftRuns: [ShiftRun] = []
    var shiftOpen: [Int] = []
    var driver: String? = nil
    var headerVersionBCD: Int? = nil
    var headerRelease: String? = nil
    var headerLibOffset: Int? = nil
    var tabAt: Set<Int> = []
    var marks: [Int: [StructuralMark]] = [:]
    var i = 0
    while i < data.count {
        if data[i] == 0x1b && i + 1 < data.count {
            // `<1B x>` extended-character escape (usually `<1B x 1C>`): x is DATA, never
            // a block start. Without this, ASCIITAB.WS's wrapped `<1B 1D 1C>` chart cell
            // read as a block whose overrunning "jump" (the next two chart bytes)
            // swallowed 3.5 KB to end of file. Both bytes pass through for `decodeSpans`
            // to render.
            out.append(data[i])
            out.append(data[i + 1])
            i += 2
            continue
        }
        // core.py — need the marker plus both length bytes present.
        if data[i] == 0x1d && i + 3 <= data.count {
            let start = i
            let jump = Int(data[i + 1]) | (Int(data[i + 2]) << 8)   // little-endian 16-bit
            // A 0x1D whose framing does not close is NOT a block — the count must echo
            // and the closing bracket must be there. `end` is where the block's own
            // closing 0x1D has to sit (the leading count skips exactly to the trailing
            // one), and the minimum a real sequence can carry is 4: the command byte, the
            // count echo, the bracket.
            //
            // The spec says a bare 0x1D "should not appear in files"; WordStar itself
            // TRUNCATES the file when fooled by one (engineering note 650, "false
            // symmetrical sequences"). Skipping the byte keeps the document — taking it
            // on faith cost ASCIITAB.WS 86% of its text.
            let end = i + 2 + jump
            guard jump >= 4, end < data.count, data[end] == 0x1d,
                  (Int(data[end - 2]) | (Int(data[end - 1]) << 8)) == jump else {
                i += 1                          // dropped, exactly as core.py drops it
                continue
            }
            // `block` re-includes the 2-byte length field, then `jump` more bytes:
            // block[0..<2] is the length, block[2] is the command byte.
            let blockEnd = min(i + 3 + jump, data.count)
            let block = Array(data[(i + 1)..<blockEnd])
            let cmd: Int = block.count > 2 ? Int(block[2]) : -1
            if let kind = noteKind(forCmd: cmd) {
                let content = blockContent(block)
                notes.append(parseNote(kind: kind, cmd: cmd, content: content, offset: start))
                // Comments included (ruling 2026-08-06 M9): every note kind now emits a
                // reference mark so consumers know WHERE it lives — Show Invisibles
                // needs the position, RTF anchors its margin comment there. WordStar
                // printed nothing for a comment and printed mode still renders nothing;
                // the mark is position, not ink.
                marks[out.count, default: []].append(.fnref)
            } else if cmd == 0x09 {                                // tab (and dot leaders)
                // Remember that this padding came from a TAB, not from typed spaces.
                // Recorded as an offset into the CLEANED stream, which is exactly what
                // `linesPass` then scans, so the mark stays aligned without injecting a
                // sentinel byte. A3.
                let (cols, leader) = tabColumns(blockContent(block))
                tabAt.insert(out.count)
                for _ in 0..<cols { out.append(leader) }
            } else if cmd == 0x0B {                                // end of page
                // WSFORMAT.TXT: "This sequence should usually be ignored. It's used by
                // the WordStar editor to keep track of page breaks. It is transient, and
                // moves around with the page break." MEASURED on WordStar 7
                // (2026-08-04): a document printed with and without 0x0B marks produced
                // BYTE-IDENTICAL output — the print pipeline never looks at them. The
                // block is still parsed (it is real structure, and a viewer may want the
                // editor's last-seen pagination), but NO renderer may treat it as a page
                // break: honouring them changed the page count of 43 archive documents.
                marks[out.count, default: []].append(.softpage)
            } else if cmd == 0x0D {                                // paragraph number
                // WordStar's AUTOMATIC outline/legal numbering (`.p#`) — "2.1.3" and
                // the like. Documented layout (WSFORMAT.TXT, "0Dh Paragraph number"):
                //
                //   Byte: level moves FORWARD from the previous number
                //   Byte: level moves BACKWARD
                //   Byte: level number of this paragraph number (1 based)
                //   Word x8: the level counters, 0 BASED
                //   31 bytes: the format string, zero-terminated
                //
                // It is BINARY. An earlier pass scanned the block for printable-looking
                // bytes and emitted those, on the assumption the number was stored as
                // text. What that actually extracted was the 31-byte FORMAT TEMPLATE —
                // so a real document printed "1.1.1.1.1.1.1.1" for every paragraph,
                // plausible enough to pass unnoticed and completely wrong.
                //
                // The number is COMPUTED: take the first `level` counters, add one to
                // each (they are 0-based) and join with dots.
                let content = blockContent(block)
                if content.count >= 5 {
                    let level = Int(content[2])
                    var parts: [String] = []
                    for k in 0..<Swift.min(level, 8) {
                        let off = 3 + k * 2
                        if off + 2 > content.count { break }
                        // Parenthesised deliberately: `|` binds looser than `+`, so
                        // `a | b << 8 + 1` would add one INSIDE the shift.
                        let counter = Int(content[off]) | (Int(content[off + 1]) << 8)
                        parts.append(String(counter + 1))
                    }
                    if !parts.isEmpty { out += Array(parts.joined(separator: ".").utf8) }
                }
            } else if cmd == 0x01 {                                // colour change
                // WSFORMAT.TXT, type 1 Color:
                //     Byte: Color number (see below).
                //     Byte: Previous color in file.
                //
                // CURRENT and PREVIOUS, not foreground and background — which is what
                // this recorded until 2026-08-04. The palette is named and fixed
                // (0 Black … 0Fh White on black), so the number resolves to a colour
                // rather than being an opaque index.
                //
                // Recorded, not rendered: the printed page this project reproduces was
                // monochrome. Register C2.
                let content = blockContent(block)
                if content.count >= 2 {
                    colours.append(ColourChange(offset: out.count,
                                                colour: Int(content[0]),
                                                previous: Int(content[1])))
                    // A colour change is a RUN BOUNDARY too: spans carry the active
                    // colour so a driver-aware renderer can honour it (LJ6DTP maps the
                    // palette to grayscale/white knockouts).
                    marks[out.count, default: []].append(.colour(index: Int(content[0])))
                }
            } else if cmd == 0x02 || cmd == 0x15 {                 // font change
                // WSFORMAT.TXT, type 2 Font — six little-endian words:
                //     Word: Font width in HMIs  (1/1800ths of an inch)
                //     Word: Font height in VMIs (1/1440ths of an inch)
                //     Word: Typestyle
                //     Word x3: the previous width, height and typestyle
                //
                // WIDTH COMES FIRST. Until 2026-08-04 this read word 1 as the height
                // "in 1/20 point" and word 2 as the width — swapped. The error survived
                // because 1/1440in IS 1/20 point exactly (1440/72 = 20), so treating the
                // WIDTH word as 20ths-of-a-point produced 9pt, 8pt, 11pt across 862 real
                // blocks: sizes plausible enough that they were cited as confirming the
                // reading. They were the right arithmetic on the wrong word. Read
                // correctly, 749 of those blocks are 12pt at 10 CPI.
                //
                // Register C3. Deliberate for PDF, which is Courier by design; RTF/HTML
                // can express a size change and now have the figures.
                let content = blockContent(block)
                if content.count >= 6 {
                    fonts.append(FontChange(
                        offset: out.count,
                        width1800: Int(content[0]) | (Int(content[1]) << 8),
                        height1440: Int(content[2]) | (Int(content[3]) << 8),
                        typestyle: Int(content[4]) | (Int(content[5]) << 8)))
                    // A font change is a RUN BOUNDARY in the text, not only metadata:
                    // every RTF came out in Times because `fonts` was recorded and never
                    // rendered (Jon's export review, 2026-08-04). Same offset mechanism
                    // as every other mark.
                    marks[out.count, default: []].append(.font(index: fonts.count - 1))
                }
            } else if cmd == 0x0F {                                // user print control
                // WSFORMAT.TXT, "0Fh User print control":
                //     Word:  number of hmis this sequence uses on the printed page
                //     Byte:  number of characters used for screen display
                //     Text:  the display string itself
                //     "The remaining bytes … will be sent directly to the printer."
                //
                // This used to scan the whole block for printable bytes and look for a
                // `%F"NAME"` file reference, ignoring the structure entirely. The
                // DISPLAY STRING is real content — it is what WordStar shows on screen
                // where the control sits, and three archive blocks carry 70 characters
                // of it. Dropping it lost text; the file reference is one thing inside
                // the printer payload, not the whole payload. Parsing the documented
                // fields recovers 5 references where the scan found 2.
                //
                // Written byte-wise: `range(of:)`/`trimmingCharacters` are Foundation
                // and this module deliberately imports nothing.
                let content = blockContent(block)
                var handled = false
                if content.count >= 3 {
                    let nch = Int(content[2])
                    let split = Swift.min(3 + nch, content.count)
                    // The display string is CP437 SCREEN TEXT -- LJ6DTP's rule-drawing
                    // controls label themselves with box-drawing art ("Empty
                    // Z00.300"hx..."). Bit-7 masking turned that into ASCII noise, and
                    // worse: a leading « (0xAE) masked to '.' (0x2E), so the whole line
                    // was later swallowed as a dot command -- 33 of LJ6DTP's 41 controls
                    // vanished. `out` is a raw single-byte-per-character cp437 stream
                    // throughout this pass, so the filtered bytes are appended AS BYTES,
                    // with no decode/re-encode round trip needed (cp437 is a total,
                    // lossless 256-slot codec: decoding then re-encoding is the identity).
                    let shown = Array(content[3..<split]).filter { $0 >= 0x20 && $0 != 0x7F }
                    let ptext = printableASCII(Array(content[split...]))
                    var name: [UInt8] = []
                    if let mark = indexOfPercentF(ptext) {
                        // Python's `ptext[mark+2:].strip().strip('"')` — whitespace
                        // first, THEN quotes, in that order.
                        name = stripASCII(Array(ptext[(mark + 2)...]), of: 0x20)
                        name = stripASCII(name, of: 0x22)
                    }
                    if !name.isEmpty {
                        // `%F"NAME"` inside the printer payload names a file the printer
                        // is told to pull in — same class as an inset graphic.
                        let decoded = decodeCP437(name)
                        includes.append(decoded)
                        out += Array("[include: \(decoded)]".utf8)
                        handled = true
                    } else if !stripASCII(shown, of: 0x20).isEmpty {
                        // No file reference, but a display string the editor shows.
                        // SCREEN-ONLY: on paper WordStar sends the raw printer payload
                        // instead and advances by the block's own HMI word ("number of
                        // hmis this sequence uses on the printed page" -- 0 for
                        // LJ6DTP's rule-drawing controls). The mark carries (hmi, byte
                        // count) so printed renderers can swap the string for its
                        // declared width; reading modes keep the string, the only
                        // human-visible trace of what the control does.
                        let hmi = Int(content[0]) | (Int(content[1]) << 8)
                        marks[out.count, default: []].append(.pctl(hmi: hmi, byteLen: shown.count))
                        out += shown
                        handled = true
                    }
                }
                if !handled {
                    // Neither: pure printer bytes (most of these are PostScript
                    // preambles). Consuming them silently would be WORSE than the bug
                    // being fixed — it turns a reported unknown into an unreported one.
                    unknownBlocks.append(UnknownBlock(cmd: cmd, bytes: block, offset: start))
                }
            } else if cmd == 0x00 {                                // HEADER sequence
                // WSFORMAT.TXT, type 0 Header — 128 bytes in total:
                //     Byte:      version number in BCD (50h = Release 5.0, 55h = 5.5,
                //                60h = 6.0)
                //     9 bytes:   null-terminated driver name
                //     2 bytes:   reserved
                //     2 words:   32-bit pointer to the file's style library
                //     107 bytes: reserved
                //
                // This was read as nothing but a driver name. The VERSION BYTE is the
                // more valuable field by far: `detect` infers ws4-vs-ws5+ from byte
                // statistics, and the file states its release outright.
                //
                // Fields accumulate across 0x00 blocks the way Python's `header` dict
                // does — each key set only when this block actually carries it, so a
                // second, emptier header cannot erase the first one's pointer.
                let content = blockContent(block)
                if let v = content.first, v == 0x50 || v == 0x55 || v == 0x60 || v == 0x70 {
                    headerVersionBCD = Int(v)
                    headerRelease = "\(Int(v) >> 4).\(Int(v) & 0x0F)"
                }
                if content.count >= 14 {
                    let lo = Int(content[12]) | (Int(content[13]) << 8)
                    let hi = content.count >= 16
                        ? Int(content[14]) | (Int(content[15]) << 8) : 0
                    let ptr = (hi << 16) | lo
                    if ptr != 0 { headerLibOffset = ptr }
                }
                // The driver the document was last formatted for (LASERJET in 43
                // archive documents). Provenance: it explains why a file's
                // measurements look the way they do. The byte before the name is a
                // record tag, not part of it (`pLASERJET`).
                var name: [UInt8] = []
                for c in content {
                    let ch = c & 0x7F
                    if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x30 && ch <= 0x39) {
                        name.append(ch)
                    } else if !name.isEmpty {
                        break
                    }
                }
                if name.isEmpty {
                    // No name in it. An EMPTY 0x00 block is a plain wrapper, not a
                    // driver record — same rule as an 0x0F with no `%F`: consuming it
                    // silently would turn a reported unknown into an unreported one.
                    unknownBlocks.append(UnknownBlock(cmd: cmd, bytes: block, offset: start))
                } else if driver == nil {
                    driver = decodeCP437(name)
                }
            } else if cmd == 0x17 {                                // Shift-In/Shift-Out
                // WSFORMAT.TXT (the WordStar 7.0 file format spec), "17h Japanese
                // Font Shift-In/Shift-Out":
                //     "Byte: Shift-In (to Japanese) = 1, Shift-Out (Back to
                //      Normal) = 0."
                //
                // A ONE-BYTE MODE TOGGLE, not a container of text. The Japanese bytes
                // live in the ordinary stream BETWEEN a shift-in and its shift-out, as
                // double-byte Shift-JIS.
                //
                // This was first implemented as if the block held the text itself,
                // emitting a placeholder for the MARKER — which would have put a bogus
                // placeholder where a mode marker belongs AND left the real Japanese to
                // be mangled by the cp437 decoder.
                //
                // Lifting the run out is CORRECTNESS, not tidiness. The spec goes on:
                // "When shifted in, WordStar no longer uses the 1Bh/1Ch wrap
                // characters". `decodeSpans` treats 1Bh as the extended-character
                // escape UNCONDITIONALLY, so a 1Bh inside a Japanese run would be read
                // as an escape and swallow the byte after it. Because the run never
                // reaches `decodeSpans`, that cannot happen. Register C15.
                let content = blockContent(block)
                if let first = content.first, first != 0 {
                    shiftOpen.append(out.count)
                } else if let start = shiftOpen.popLast() {
                    let raw = Array(out[start...])
                    out.removeSubrange(start...)
                    shiftRuns.append(ShiftRun(offset: start, bytes: raw))
                    out += Array("[shift-jis: \(raw.count) bytes]".utf8)
                }
            } else if cmd == 0x16 {                                // truncation marker
                // The spec says a truncated line shows a literal marker. Nothing in
                // the archive contains one, so this is implemented FROM THE SPEC and
                // has never been checked against a file that really has it. C14.
                out += Array("<TRUNCATED>".utf8)
            } else if cmd == 0x10 {                                // inset graphic
                // An INSET picture placed in the text. The block's content is the
                // image's path, and it was falling through to `UnknownBlock` — which
                // preserves the bytes for diagnostics but drops the text — so a
                // document with figures rendered as if it had none. Register C10.
                //
                // A converter cannot render a 1987 .PIX file, but it must not go quiet
                // about one: the path is recorded and a visible placeholder goes into
                // the text where the picture sat.
                let path = decodeCP437(blockContent(block)
                    .map { $0 & 0x7F }
                    .filter { $0 >= 0x20 && $0 < 0x7F })
                graphics.append(path)
                let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last
                    .map(String.init) ?? path
                out += Array("[image: \(name)]".utf8)
            } else if cmd == 0x0E {                                // index item
                // An inline indexed PHRASE. WordStar prints the phrase in the body —
                // the index ENTRY is the non-printing part — so dropping the block
                // risks losing text outright when the phrase is not duplicated in the
                // visible stream.
                out += blockContent(block)
                    .map { $0 & 0x7F }
                    .filter { $0 >= 0x20 && $0 < 0x7F }
            } else if cmd == 0x11 && block.count >= 6 {            // paragraph style
                // Four LE16 style HANDLES (WSFORMAT: new / previously selected /
                // previous "modified" temp / previous-previous). All 1,727 blocks across
                // the archive are exactly 8 content bytes. Only word 0 — the newly
                // selected style — is joinable: high byte 0x02 tags this file's own
                // library, low byte is the 0-BASED index-item slot in allocation order,
                // DELETED SLOTS COUNTED (validated 60/60 distinct references, 22/22
                // documents). The 0x03xx pool in word 2 names editing-temp styles that
                // were never written to the file: unresolvable by design, reject rather
                // than mask.
                //
                // The old reading took content[0] alone — the LOW BYTE of w0 — and
                // mapped three slot numbers to heading levels. Slot numbers carry no
                // semantics: 0x05 resolves to 'Bulleted List' in one document and 'Body
                // copy font' in another, and NOVEL.WS's real H1/H2/H3 styles sat unmapped
                // while its footer style rendered as a heading. Heading meaning now comes
                // from the RESOLVED entry (see `parseWS`), never from the slot.
                let content = blockContent(block)
                if content.count == 8 {
                    marks[out.count, default: []].append(.style(handle: Int(content[0]) | (Int(content[1]) << 8)))
                } else {
                    unknownBlocks.append(UnknownBlock(cmd: cmd, bytes: block, offset: start))
                }
            } else {
                unknownBlocks.append(UnknownBlock(cmd: cmd, bytes: block, offset: start))
            }
            i += jump + 3
        } else {
            out.append(data[i])
            i += 1
        }
    }
    // An unterminated shift-in runs to the end of the document: the text is Japanese
    // from there on, and dropping the run would lose that fact entirely.
    while let start = shiftOpen.popLast() {
        let raw = Array(out[start...])
        out.removeSubrange(start...)
        shiftRuns.append(ShiftRun(offset: start, bytes: raw))
        out += Array("[shift-jis: \(raw.count) bytes]".utf8)
    }
    shiftRuns.sort { $0.offset < $1.offset }
    let header = (headerVersionBCD == nil && headerLibOffset == nil)
        ? nil
        : WSHeader(versionBCD: headerVersionBCD, release: headerRelease,
                   styleLibraryOffset: headerLibOffset)
    return SymmetricBlocksResult(bytes: out, notes: notes, unknownBlocks: unknownBlocks,
                                 graphics: graphics, colours: colours, fonts: fonts,
                                 includes: includes, shiftRuns: shiftRuns,
                                 printerDriver: driver, header: header,
                                 tabAt: tabAt, marks: marks)
}

/// Python's `bytes(c & 0x7F for c in b if 0x20 <= (c & 0x7F) < 0x7F)` — mask bit 7, keep
/// only what a 1987 screen could show.
private func printableASCII(_ b: [UInt8]) -> [UInt8] {
    b.map { $0 & 0x7F }.filter { $0 >= 0x20 && $0 < 0x7F }
}

/// Python's `str.strip(ch)` for one byte value.
private func stripASCII(_ b: [UInt8], of ch: UInt8) -> [UInt8] {
    var start = 0, end = b.count
    while start < end, b[start] == ch { start += 1 }
    while end > start, b[end - 1] == ch { end -= 1 }
    return Array(b[start..<end])
}

/// `text.find('%F')` — the offset of the two-byte marker, or `nil`.
private func indexOfPercentF(_ b: [UInt8]) -> Int? {
    guard b.count >= 2 else { return nil }
    for k in 0...(b.count - 2) where b[k] == 0x25 && b[k + 1] == 0x46 {
        return k
    }
    return nil
}

/// `block[3:-3] if len(block) >= 6 else block[3:]` — strips the leading length+cmd
/// header and, when there's room, the trailing self-referential length+marker that
/// closes a well-formed symmetric block. Bounds-checked so a truncated/malformed block
/// degrades to whatever content bytes actually exist rather than crashing.
private func blockContent(_ block: [UInt8]) -> [UInt8] {
    if block.count >= 6 {
        return Array(block[3..<(block.count - 3)])
    }
    return block.count > 3 ? Array(block[3...]) : []
}

/// Decode one note block's content (the bytes between the type byte and the closing
/// count+0x1D), per the spec's Notes section. Direct port of `_parse_note`:
///
///     Word: line count of the note text
///     Word: offset to the internal tag sequence (high bit set -> low 15 bits are the
///           offset) OR the note number itself (high bit clear)
///     Byte: conversion flag (used only when there is no internal tag) -- low nybble =
///           target type if converted (0 = not converted), high nybble = numbering
///           format (0 symbols, 1 upper, 2 lower, 3 numeric)
///     Remaining bytes: the note text, which may itself hold ONE nested symmetrical
///           sequence (the internal tag, or a font change) -- spec: "Currently only
///           one level of this recursion is used."
///
/// The tag/conversion-flag word and the internal tag mean different things per kind,
/// though: only footnotes/endnotes carry a NUMBER (the spec is explicit that
/// annotations'/comments' equivalent fields are "not used"). Annotations instead carry
/// a TEXT tag ("the text used to display and print the tag of the note") in the very
/// same position a footnote's internal tag would carry its number -- so the same
/// nested-sequence walk below extracts a number for footnote/endnote and a tag string
/// for annotation, and the outer conversion flag is only trusted where the spec says
/// it's actually used (not annotations).
private func parseNote(kind: NoteKind, cmd: Int, content: [UInt8], offset: Int) -> Note {
    guard content.count >= 5 else { return Note(kind: kind, offset: offset) }
    let lineCount = Int(content[0]) | (Int(content[1]) << 8)
    let tagWord = Int(content[2]) | (Int(content[3]) << 8)
    var convFlag = content[4]
    let numeric = kind == .footnote || kind == .endnote
    var number: Int? = numeric ? ((tagWord & 0x8000) != 0 ? nil : tagWord) : nil
    var tag: String? = nil
    let remainder = Array(content.dropFirst(5))

    var textBytes: [UInt8] = []
    var i = 0
    while i < remainder.count {
        if remainder[i] == 0x1d && i + 3 <= remainder.count {
            let jump = Int(remainder[i + 1]) | (Int(remainder[i + 2]) << 8)
            let innerEnd = min(i + 3 + jump, remainder.count)
            let inner = Array(remainder[(i + 1)..<innerEnd])
            let innerCmd: Int = inner.count > 2 ? Int(inner[2]) : -1
            if innerCmd == cmd {                                   // the internal tag sequence
                let innerContent = blockContent(inner)
                if numeric && innerContent.count >= 5 {
                    number = Int(innerContent[2]) | (Int(innerContent[3]) << 8)
                    convFlag = innerContent[4]
                } else if kind == .annotation && innerContent.count > 5 {
                    let rawTag = innerContent.dropFirst(5).filter { c in
                        (c >= 0x20 && c < 0x7F) || c >= 0x80 || c == 0x09
                    }
                    let decoded = decodeCP437(Array(rawTag)).trimmed()
                    tag = decoded.isEmpty ? nil : decoded
                }
            }
            i += jump + 3                                          // skip the whole nested sequence
        } else {
            textBytes.append(remainder[i])
            i += 1
        }
    }

    let (text, dots) = stripDotCommands(textBytes)
    let numberFormat: Int
    let convertTo: Int
    if kind == .annotation {
        // spec: "Byte: Conversion flag. Not used for annotations." -- don't report
        // noise from a byte the format documents as meaningless here.
        numberFormat = 0
        convertTo = 0
    } else {
        numberFormat = Int((convFlag >> 4) & 0x0F)
        convertTo = Int(convFlag & 0x0F)
    }
    return Note(
        kind: kind, text: text, number: number, tag: tag, lineCount: lineCount,
        numberFormat: numberFormat, convertTo: convertTo, dotCommands: dots, offset: offset
    )
}

/// Split note text into physical lines (the same hard-return bytes the body splits on)
/// and pull any dot-command lines out of it -- a note can carry its own dot commands (a
/// `.rr` ruler, a `..` comment line) exactly like the body can, and the body already
/// never renders those as text. Unrecognised dot commands are kept verbatim, in order,
/// not dropped; surviving text lines are cleaned the same way note text always was and
/// rejoined with a space (notes are short callouts, not reflowed prose). Direct port of
/// `_strip_dot_commands`.
private func stripDotCommands(_ raw: [UInt8]) -> (text: String, dots: [String]) {
    let lines = splitOnLineBreaks(raw)
    var kept: [String] = []
    var dots: [String] = []
    for line in lines {
        let stripped = line.map { $0 & 0x7F }              // same masking the body uses
        if stripped.first == 0x2e {
            dots.append(decodeCP437(stripped).trimmed())
            continue
        }
        let clean = line.filter { c in (c >= 0x20 && c < 0x7F) || c >= 0x80 || c == 0x09 }
        let piece = decodeCP437(clean).trimmed()
        if !piece.isEmpty {
            kept.append(piece)
        }
    }
    return (kept.joined(separator: " "), dots)
}

/// Non-overlapping split on any of WordStar's line-break tokens, matching
/// `re.split(rb'\x8d\x0a|\x0d\x0a|\x8d|\x0d|\x0a', raw)` — every separator is consumed
/// (not kept), including adjacent/leading/trailing ones, which produce empty segments
/// that stay in the result (Python `re.split` never drops them).
private func splitOnLineBreaks(_ data: [UInt8]) -> [[UInt8]] {
    var result: [[UInt8]] = []
    var current: [UInt8] = []
    var i = 0
    while i < data.count {
        let b = data[i]
        let next: UInt8? = (i + 1 < data.count) ? data[i + 1] : nil
        if b == 0x8d && next == 0x0a {
            result.append(current); current = []; i += 2
        } else if b == 0x0d && next == 0x0a {
            result.append(current); current = []; i += 2
        } else if b == 0x8d || b == 0x0d || b == 0x0a {
            result.append(current); current = []; i += 1
        } else {
            current.append(b)
            i += 1
        }
    }
    result.append(current)
    return result
}

/// Tabs and dot leaders (symmetrical sequence type 9, WordStar 7.0 file format spec):
/// Word tab size in HMIs, Word absolute tab size in HMIs, Byte tab type, Byte tab size
/// in tenths. Documented tab-type bytes: ' ' hard tab, soft space (0xA0) soft tab, '#'
/// decimal, '!' center, '[' right-align. ']' is an UNDOCUMENTED right-align variant --
/// WordTsar's author found it by testing against MicroPro's own PRINT.TST (confirmed
/// present there too: a type-9 block with tab type byte 0x5D, ']'). It renders
/// identically to the documented '[': same right-align intent, just a second byte
/// value nobody wrote down. Any other byte is a dot-leader character (spec: "Other
/// character such as '.' or '*' are used for dot leaders.").
///
/// HMI -> columns. An HMI is 1/1800 inch (HORTAB.TXT: "an HMI is 1/1800 inch"; the font
/// block's width word uses the same unit), so one 10-CPI column is 1800/10 = 180 HMI. The
/// old value here was 144, derived by borrowing VMI's 1/1440in unit for the horizontal
/// axis -- the same unit confusion as the font-block word swap, and it made every tab 25%
/// too wide. MEASURED against every type-9 block in the archive (3,617 blocks, later
/// 4,633): the block's own final byte -- "Tab size in 1/10th" (of an inch, and 0.1in IS
/// 180 HMI) -- equals size//180 in all of them. Direct port of `_tab_columns`.
private let tabHMIPerCol = 180
private let tabRightTypes: Set<UInt8> = [0x5B, 0x5D]        // '[' documented, ']' undocumented

/// Python's `round()` is round-half-to-even (banker's rounding), unlike Swift's
/// `FloatingPoint.rounded()` default (round-half-away-from-zero). `size`/`divisor` are
/// always non-negative here (2-byte LE HMI fields), so exact integer arithmetic — no
/// floating point, no libm dependency — reproduces it precisely, including the exact
/// `.5` tie case `round()` handles specially.
private func roundHalfToEven(_ numerator: Int, by divisor: Int) -> Int {
    let quotient = numerator / divisor
    let remainder = numerator % divisor
    let doubledRemainder = remainder * 2
    if doubledRemainder < divisor { return quotient }
    if doubledRemainder > divisor { return quotient + 1 }
    return quotient % 2 == 0 ? quotient : quotient + 1
}

/// We can't reflow text to truly right/center/decimal-align a tab without knowing the
/// width of what follows it -- this pass runs before line/word splitting -- so those
/// types degrade to plain space padding, but of the CORRECT width (from the tab's own
/// HMI size) rather than a guessed constant. Dot-leader tabs (any byte outside the
/// documented/undocumented set) repeat their own leader character.
private func tabColumns(_ content: [UInt8]) -> (cols: Int, leader: UInt8) {
    guard content.count >= 5 else {
        return (4, 0x20)            // malformed/short block: the old fixed-4-spaces
                                     // behaviour as a safe fallback, never a crash
    }
    let size = Int(content[0]) | (Int(content[1]) << 8)
    let tabType = content[4]
    let cols = max(1, roundHalfToEven(size, by: tabHMIPerCol))
    let leader: UInt8
    if tabType == 0x20 || tabType == 0xA0 || tabType == UInt8(ascii: "#")
        || tabType == UInt8(ascii: "!") || tabRightTypes.contains(tabType) {
        leader = 0x20
    } else if tabType >= 0x20 && tabType < 0x7F {
        leader = tabType                                    // dot-leader character
    } else {
        leader = 0x20
    }
    return (cols, leader)
}
