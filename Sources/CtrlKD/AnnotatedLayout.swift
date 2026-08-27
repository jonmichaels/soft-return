/// Show Invisibles, part 1/4 (job 255): the document as an ordered stream where
/// WordStar's five classes of invisible ink — dot commands, comments, soft/hard
/// returns, style toggles, and page-break origin — are present and tagged, ready for a
/// viewer to render inline and reflow. Spec: `soft-return-show-invisibles-spec.md`.
///
/// ADDITIVE ONLY: reads `Document`/`Block`/`Line`/`Span`/`Style`/`FontChange` and the
/// existing note/dot-position/pagination machinery; emits nothing of its own and
/// changes no existing emission path. The one non-additive touch is `PDFLayout.swift`'s
/// `layoutPrintedPagesPlain` losing its `private` — a pure visibility widening (see the
/// comment there) so natural page-break detection can call the real paginator instead
/// of re-deriving its budget math here, per the registry rule: the engine is the single
/// source of truth, USE it, do not re-parse.
///
/// `annotatedLayout` walks the RAW parsed IR (`Document.blocks[].lines[].spans`) in
/// document order — physical lines, exactly as `docToPagelines(doc, printed: true)`
/// renders them — not the reflowed Modern semantic flow (`Layout.swift`'s
/// `SemanticItem`), which already discards soft-return/page geometry this feature
/// exists to show.

/// One class of "ink" a span or line can carry — five invisible, one visible. Visible
/// spans are UNCHANGED from what `Line.spans`/`Document.dotCommands` already hold: this
/// type only ever ADDS spans/lines around them, never edits or removes one, which is
/// what makes the visible-only projection exactly reproduce today's plain text stream
/// (see `AnnotatedLayoutTests.swift`'s round-trip test).
public enum InkKind: Hashable, Sendable {
    case visible
    /// A whole dot-command line (`.cp4`, `.h1 Running head`, …), full text, inserted at
    /// its recorded `DotPosition`.
    case dotCommand
    /// A `Note(kind: .comment)`'s text, inserted beside its `fnref` reference span — the
    /// mark WordStar itself renders as a small reference number is left untouched
    /// (`.visible`); this is the note's actual content, added alongside it.
    case comment
    /// End-of-line marker: `Line.soft == true` (WordStar's own word wrap).
    case softReturn
    /// End-of-line marker: `Line.soft == false` (the author's own Return).
    case hardReturn
    /// A style toggle boundary — WordStar's own screen token (`"^B"`, `"^Y"`, …) for the
    /// byte(s) `rtToggleDiff` would emit crossing this boundary.
    case styleToggle(String)
    /// Pagination begins a page here. The reason is the verbatim dot-command text
    /// (`".pa"`, `".cp4"`), `"\u{0C}"` for a literal form-feed byte (`Block.origin ==
    /// .ff`, no dot line to quote), or `""` for a natural overflow break the paginator's
    /// own budget math decided, not the author.
    case pageBreakOrigin(String)
}

/// One run of text OR one invisible mark, tagged with the kind above and the host
/// run's style/font — so a viewer can size a mark like the line it sits in without
/// re-deriving the surrounding run.
public struct AnnotatedSpan: Hashable, Sendable {
    /// Visible text for `.visible`; the mark's own glyph/token otherwise (a dot
    /// command's full text, a comment's text, a style toggle's caret token).
    public let text: String
    public let kind: InkKind
    public let style: Style
    public let font: FontChange?

    public init(text: String, kind: InkKind, style: Style = [], font: FontChange? = nil) {
        self.text = text
        self.kind = kind
        self.style = style
        self.font = font
    }
}

/// One physical line, annotated. `spans` interleaves `.visible` runs (unmodified) with
/// inserted invisible marks (comments beside their reference, style toggles at their
/// boundary); a line built purely to carry a dot command or a page-break-before marker
/// on an otherwise empty page has no `.visible` spans at all.
public struct AnnotatedLine: Hashable, Sendable {
    public let spans: [AnnotatedSpan]
    /// `nil` only for a line this feature fabricates that has no return of its own (a
    /// pure `.dotCommand` line, or the empty placeholder for a blank page). Every real
    /// `Line` sets this from `Line.soft`.
    public let endMark: InkKind?
    /// Set on the first line pagination places on a new page — see `InkKind.pageBreakOrigin`.
    public let pageBreakBefore: InkKind?

    public init(spans: [AnnotatedSpan], endMark: InkKind? = nil, pageBreakBefore: InkKind? = nil) {
        self.spans = spans
        self.endMark = endMark
        self.pageBreakBefore = pageBreakBefore
    }
}

public struct AnnotatedDocument: Hashable, Sendable {
    public let lines: [AnnotatedLine]

    public init(lines: [AnnotatedLine]) {
        self.lines = lines
    }
}

/// The six inline toggles a WordStar screen token exists for — `rtTogglable` minus
/// `.altFont`, which is a printer-only flag with no on-screen caret token of its own
/// (`Style.altFont`'s own doc comment: "Stored, never rendered"). Scope decision for
/// this job: "WordStar's own ^B/^S/^Y/^T/^V tokens" names exactly this set.
private let invisibleToggleScope: Style = [.bold, .underline, .sup, .sub, .strike, .italic]

/// WordStar's own screen token for a toggle byte — caret notation, the same convention
/// the file format's own documentation uses. Every byte `rtToggleDiff` can emit for
/// `invisibleToggleScope` is a C0 control code below 0x20, so `byte + 0x40` is always a
/// printable ASCII letter.
private func caretToken(_ byte: UInt8) -> String {
    "^" + String(UnicodeScalar(byte &+ 0x40))
}

/// The `.pa`/`.cp` reason text `DotPosition` recorded at a pagebreak/condpage block's
/// own anchor (`blockIndex`, `lineIndex: 0`) — the verbatim dot line that caused it, when
/// one exists. `nil` blocks (a raw form-feed byte, `Block.origin == .ff`) have none.
private func explicitBreakReason(_ block: Block, anchoredDotText: [String]) -> InkKind {
    switch block.kind {
    case .pagebreak:
        if let text = anchoredDotText.last(where: { $0.uppercased().hasPrefix(".PA") }) {
            return .pageBreakOrigin(text)
        }
        return .pageBreakOrigin(block.origin == .ff ? "\u{0C}" : ".pa")
    case .condpage:
        if let text = anchoredDotText.last(where: { $0.uppercased().hasPrefix(".CP") }) {
            return .pageBreakOrigin(text)
        }
        return .pageBreakOrigin(".cp\(block.heading)")
    case .para:
        preconditionFailure("explicitBreakReason called on a non-pagebreak block")
    }
}

/// IR -> the annotated stream. See the file header for the additive contract.
public func annotatedLayout(_ doc: Document) -> AnnotatedDocument {
    let refNotes = inlineReferenceNotes(doc)

    // Every dot command's recorded position, grouped for insertion: the block it
    // precedes, then the line within that block it precedes — DotPosition's own
    // (blockIndex, lineIndex) anchor, preserved in document order (dotPositions
    // already is). blocks.count is a valid key: trailing dot commands with no block
    // after them anchor there (ParseWS.swift's own trailing-dot-comment case).
    var dotsByBlock: [Int: [Int: [String]]] = [:]
    for dp in doc.dotPositions {
        dotsByBlock[dp.blockIndex, default: [:]][dp.lineIndex, default: []].append(dp.text)
    }

    var out: [AnnotatedLine] = []
    // Parallel to the paginator's own `.line` item order (every block this loop visits
    // contributes its lines in order; pagebreak/condpage blocks contribute none, exactly
    // like `resolvePlainBody`) — natural-overflow correlation below indexes through this.
    var realLineOutIndices: [Int] = []

    // Running inline-style/font state, threaded across the WHOLE document: a toggle is
    // inline formatting, not a per-paragraph reset, and font runs cross block boundaries
    // the same way (Style.swift/Span.font).
    var runningStyle: Style = []
    var currentFontIndex: Int?

    func currentFont() -> FontChange? { spanFontEntry(currentFontIndex, doc.fonts) }

    func dotCommandLines(_ texts: [String]) -> [AnnotatedLine] {
        texts.map { text in
            AnnotatedLine(spans: [AnnotatedSpan(text: text, kind: .dotCommand, font: currentFont())])
        }
    }

    func annotatedSpans(_ line: Line) -> [AnnotatedSpan] {
        var spans: [AnnotatedSpan] = []
        for span in line.spans {
            if let f = span.font { currentFontIndex = f }
            let wanted = span.styles.intersection(invisibleToggleScope)
            let had = runningStyle.intersection(invisibleToggleScope)
            if wanted != had {
                for byte in rtToggleDiff(had, wanted) {
                    let token = caretToken(byte)
                    spans.append(AnnotatedSpan(text: token, kind: .styleToggle(token),
                                               style: span.styles, font: currentFont()))
                }
            }
            runningStyle = span.styles
            spans.append(AnnotatedSpan(text: span.text, kind: .visible, style: span.styles,
                                       font: currentFont()))
            if span.styles.contains(.fnref), let k = Int(span.text), k >= 1, k <= refNotes.count,
               refNotes[k - 1].kind == .comment {
                spans.append(AnnotatedSpan(text: refNotes[k - 1].text, kind: .comment,
                                           font: currentFont()))
            }
        }
        return spans
    }

    func attach(_ reason: InkKind?, to line: AnnotatedLine) -> AnnotatedLine {
        guard let reason else { return line }
        return AnnotatedLine(spans: line.spans, endMark: line.endMark, pageBreakBefore: reason)
    }

    for (bi, block) in doc.blocks.enumerated() {
        var reason: InkKind? = (block.kind == .para) ? nil
            : explicitBreakReason(block, anchoredDotText: dotsByBlock[bi]?[0] ?? [])
        for li in 0...block.lines.count {
            for dotLine in dotCommandLines(dotsByBlock[bi]?[li] ?? []) {
                out.append(attach(reason, to: dotLine))
                reason = nil
            }
            guard li < block.lines.count else { continue }
            let line = block.lines[li]
            let annotated = AnnotatedLine(spans: annotatedSpans(line),
                                          endMark: line.soft ? .softReturn : .hardReturn)
            realLineOutIndices.append(out.count)
            out.append(attach(reason, to: annotated))
            reason = nil
        }
        // A pagebreak/condpage block with no dot-command line of its own (a raw 0x0C)
        // and no lines either (two breaks back to back — "even an empty page, which IS
        // a blank sheet", PDFLayout.swift) still needs somewhere to carry its marker.
        if let reason {
            out.append(AnnotatedLine(spans: [], pageBreakBefore: reason))
        }
    }
    // Dot commands anchored past the last block (document ends in dot lines with no
    // content after them).
    for dotLine in dotCommandLines(dotsByBlock[doc.blocks.count]?[0] ?? []) {
        out.append(dotLine)
    }

    // Natural-overflow page breaks: only where the real paginator can tell us, and only
    // for the plain (no footnote/endnote/annotation area) path — the notes-aware
    // paginator's page-bottom area growth has no line-for-line correlation back to the
    // source Lines this pass can cheaply reconstruct, and misreporting a break is worse
    // than omitting one. `.pa`/`.cp` origins above are unaffected either way — they come
    // from `Block.kind` directly, never from pagination.
    if !hasPlaceableNotes(doc) {
        let pages = layoutPrintedPagesPlain(doc)
        var pageIndexByOrdinal: [Int] = []
        for (pi, page) in pages.enumerated() {
            pageIndexByOrdinal.append(contentsOf: Array(repeating: pi, count: page.lines.count))
        }
        // A break is "already explained" if its annotation sits on the new page's first
        // real line OR anywhere in the ink-free run immediately before it — explicit
        // `.pa`/`.cp` reasons ride a dot-command line or an empty placeholder line
        // (the no-lines pagebreak-block path above), never the following real line.
        // Stamping that real line too would double-report the same break as a phantom
        // unlabeled origin.
        func breakAlreadyExplained(at outIdx: Int) -> Bool {
            if out[outIdx].pageBreakBefore != nil { return true }
            var i = outIdx - 1
            while i >= 0, out[i].spans.allSatisfy({ $0.kind == .dotCommand }) {
                if out[i].pageBreakBefore != nil { return true }
                i -= 1
            }
            return false
        }
        var prevPage = 0
        for (ordinal, outIdx) in realLineOutIndices.enumerated() {
            guard ordinal < pageIndexByOrdinal.count else { break }
            let pi = pageIndexByOrdinal[ordinal]
            if ordinal > 0, pi != prevPage, !breakAlreadyExplained(at: outIdx) {
                out[outIdx] = AnnotatedLine(spans: out[outIdx].spans, endMark: out[outIdx].endMark,
                                            pageBreakBefore: .pageBreakOrigin(""))
            }
            prevPage = pi
        }
    }

    return AnnotatedDocument(lines: out)
}
