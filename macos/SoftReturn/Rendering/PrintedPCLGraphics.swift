import AppKit

/// Job 490 (item 1, closing the b29 LJ6DTP title-top divergence): a 0x0F user print
/// control's raw printer payload (`Document.pclPrograms`, indexed by `Span.pcl`) is real
/// PCL, not decoration — LJ6DTP.WS draws its page border (all 8 pages) and page 4's
/// checkerboard entirely this way. The engine (`c1b622d`, b29) executes it as real PDF
/// fills (`CtrlKD/PDFDriverLJ6DTP.swift`'s own `PCLOp`/`parsePCLProgram`/`pclRectOps` — see
/// that file's top doc comment for the byte-inventory citation: exactly four PCL forms in
/// this corpus, cursor push/pop, cursor position, and rectangle fill, solid or shaded). The
/// app had no support for any of it — `job489`'s report grepped the whole rendering layer
/// for `pcl`/`PCL` and found zero matches — so its own topmost page-1 ink was whatever came
/// next in the document flow (LJ6DTP's title, 43pt down) instead of the border the engine
/// now draws ~20pt down. This file is the port: `PCLOp`/`parsePCLProgram` are copied
/// VERBATIM from the engine (pure byte tokenizing, frame-independent — both are `internal`
/// to `CtrlKD`, so this app target cannot call them directly, same "parallel port, not a
/// call" discipline as `PrintedVectorGraphics.swift`'s own box-glyph fills). Only the
/// EXECUTION half (`pclRectOps` there) is re-derived here, in `pclGraphicRects` below,
/// because the engine's version emits PDF content-stream ops in PDF's bottom-up frame and
/// this app draws directly into AppKit's own top-down (flipped) view frame — see that
/// function's own doc comment for the coordinate-frame algebra.
///
/// `PageTextView.drawPCLGraphics` (`PagedDocumentView.swift`) is the draw-time caller: it
/// walks each line fragment's glyphs the same way `drawVectorGraphics`/`graphicCells`
/// already do for box-drawing glyphs, finds any `.printedPCLProgram`-tagged attachment
/// glyph (`DocumentRenderer.pctlAdvanceAttachment`'s own doc comment), and executes that
/// control's own program anchored at the attachment's real, laid-out position.
extension NSAttributedString.Key {
    /// The `Int` index into `RenderedDocument.pclPrograms`/`Document.pclPrograms` this pctl
    /// attachment's own control carries, or absent for a display-only control with no
    /// surviving printer payload. See `DocumentRenderer.pctlAdvanceAttachment`.
    static let printedPCLProgram = NSAttributedString.Key("SoftReturn.printedPCLProgram")
}

/// One tokenized PCL operation. Port of `CtrlKD.PCLOp` (`PDFDriverLJ6DTP.swift`) — see this
/// file's top doc comment for why it's copied rather than called.
enum PCLOp: Hashable {
    case push
    case pop
    case moveX(value: Int, relative: Bool)
    case moveY(value: Int, relative: Bool)
    case fill(w: Int, h: Int, gray: Double)
    case ignored([UInt8])
}

/// HP LaserJet's own logical-page registration — port of `CtrlKD`'s identically-named,
/// identically-valued constants (`PDFDriverLJ6DTP.swift`, both `internal` there).
private let pclAbsXOffsetUnits = 75
private let pclAbsYOffsetUnits = 0
/// PCL unit (1/300in) -> point, exact.
private let pclUnitPt = 72.0 / 300.0

/// Digits at `i`, with an optional leading sign. `nil` when there is no digit there. Port of
/// `CtrlKD`'s private `pclSignedInt`.
private func pclSignedInt(_ data: [UInt8], _ i: Int) -> (value: Int, relative: Bool, end: Int)? {
    var j = i
    var relative = false
    var negative = false
    if j < data.count, data[j] == UInt8(ascii: "+") || data[j] == UInt8(ascii: "-") {
        relative = true
        negative = data[j] == UInt8(ascii: "-")
        j += 1
    }
    let digitsStart = j
    var value = 0
    while j < data.count, data[j] >= 0x30, data[j] <= 0x39 {
        value = value * 10 + Int(data[j] - 0x30)
        j += 1
    }
    guard j > digitsStart else { return nil }
    return (negative ? -value : value, relative, j)
}

/// Tokenize one 0x0F control's raw printer payload into the small, explicit op list this
/// corpus actually uses. Verbatim port of `CtrlKD.parsePCLProgram` — same grammar, same
/// four recognised forms (cursor push/pop, position, rectangle fill plain or shaded),
/// anything else recorded as `.ignored` rather than guessed at.
func parsePCLProgram(_ data: [UInt8]) -> [PCLOp] {
    var ops: [PCLOp] = []
    var i = 0
    let n = data.count
    func lit(_ at: Int, _ s: String) -> Bool {
        let want = Array(s.utf8)
        guard at + want.count <= n else { return false }
        for (k, b) in want.enumerated() where data[at + k] != b { return false }
        return true
    }
    while i < n {
        if lit(i, "\u{1B}&f0S") { ops.append(.push); i += 5; continue }
        if lit(i, "\u{1B}&f1S") { ops.append(.pop); i += 5; continue }
        if lit(i, "\u{1B}*p") {
            var j = i + 3
            var xPart: (value: Int, relative: Bool)? = nil
            if let first = pclSignedInt(data, j), first.end < n,
               data[first.end] == UInt8(ascii: "x") {
                xPart = (first.value, first.relative)
                j = first.end + 1
            }
            if let second = pclSignedInt(data, j), second.end < n,
               data[second.end] == UInt8(ascii: "Y") {
                if let x = xPart { ops.append(.moveX(value: x.value, relative: x.relative)) }
                ops.append(.moveY(value: second.value, relative: second.relative))
                i = second.end + 1
                continue
            }
        }
        if lit(i, "\u{1B}*c") {
            var j = i + 3
            var fields: [Int] = []
            var ok = true
            for terminator in [UInt8(ascii: "a"), UInt8(ascii: "b")] {
                guard let f = pclSignedInt(data, j), !f.relative, f.end < n,
                      data[f.end] == terminator else { ok = false; break }
                fields.append(f.value)
                j = f.end + 1
            }
            if ok, let f = pclSignedInt(data, j), !f.relative, f.end < n {
                fields.append(f.value)
                j = f.end
                var shade: Int? = nil
                if data[j] == UInt8(ascii: "g"), let g = pclSignedInt(data, j + 1),
                   !g.relative, g.end < n, data[g.end] == UInt8(ascii: "P") {
                    shade = g.value
                    j = g.end
                }
                if data[j] == UInt8(ascii: "P") {
                    let w = fields[0], h = fields[1], f0 = fields[2]
                    if shade != nil {
                        ops.append(.fill(w: w, h: h, gray: 1.0 - Double(f0) / 100.0))
                    } else if f0 == 0 {
                        ops.append(.fill(w: w, h: h, gray: 0.0))
                    } else {
                        ops.append(.ignored(Array(data[i...j])))
                    }
                    i = j + 1
                    continue
                }
            }
        }
        if data[i] == 0x1B {
            var j = i + 1
            while j < n, data[j] != 0x1B { j += 1 }
            ops.append(.ignored(Array(data[i..<j])))
            i = j
        } else {
            i += 1
        }
    }
    return ops
}

/// Execute one parsed PCL program into this app's own top-down (flipped) view frame —
/// `anchorX`/`anchorY` are the real, laid-out AppKit position (points, distance from the
/// page's own top-left) of the pctl attachment glyph this control sits at, the same anchor
/// convention `graphicCells` already uses for cp437 fills (`PrintedVectorGraphics.swift`).
///
/// This is NOT a call into `CtrlKD.pclRectOps` (that function is `internal` to `CtrlKD` and
/// works in PDF's own bottom-up frame besides) — it re-derives the same cursor arithmetic
/// directly in this view's frame:
///   - An ABSOLUTE move is frame-INDEPENDENT once converted: PCL's own Y is already "units
///     down from the page's own top edge" (the engine's `pageHeight - (value+offset)*unit`
///     only exists to flip that into PDF's bottom-up Y — this view's frame IS top-down, so
///     the flip is simply omitted: `curY = (value + offset) * unit`). LJ6DTP's own border
///     control opens `ESC*p0002x0085Y` — absolute (2, 85) units, i.e. (18.48, 20.4)pt from
///     the page's top-left corner, which is exactly this test's own expected ~20pt
///     title-top; confirmed against the raw fixture bytes, not assumed.
///   - A RELATIVE move's sign flips from the engine's own formula (`curY -= value*unit`,
///     bottom-up) to `curY += value*unit` here — moving DOWN the page is decreasing Y in a
///     bottom-up frame but increasing Y in this view's top-down one.
///   - `moveX` needs no sign flip either way (X's sense is frame-independent).
///   - A fill's own anchor is its TOP edge in this frame (mirrors the engine's own anchor
///     being the rect's bottom-up TOP): `CGRect(x: curX, y: curY, width: wPt, height: hPt)`
///     extends DOWN the page from the cursor, matching `PrintedVectorGraphics`'s own
///     `cellTop`/`addRect` convention (smaller Y is higher on the page).
func pclGraphicRects(_ progOps: [PCLOp], anchorX: Double, anchorY: Double) -> [GraphicRect] {
    var rects: [GraphicRect] = []
    // Register b31 (job 506): the printer's own logical-page registration offset
    // (`pclAbsXOffsetUnits`'s own doc comment above) now applies to a RELATIVE
    // program's starting anchor too, not just an absolute move's own value — port of
    // the engine's `lineOpsPrinted` (`PDFWriter.swift`, b31 register E1): a relative
    // program (LJ6DTP's checkerboard) inherits the running text pen position as its
    // anchor, but raw PCL bypasses WordStar's own margin/cursor machinery to address
    // the physical page directly, so that anchor needs the SAME printer registration
    // correction an absolute move already gets. Gated on `pclProgramIsAbsoluteOnly`
    // rather than applied unconditionally (which the engine can do safely, since PDF
    // content-stream order makes it provably inert there too): for an ABSOLUTE-only
    // program (the border) this correction would be inert anyway — its own first
    // `moveX`/`moveY` op overwrites `curX`/`curY` outright before any `fill` ever
    // reads them — but gating explicitly documents the intent without depending on
    // that overwrite, and leaves the border's own already-verified (job 503 item 3)
    // arithmetic byte-for-byte unchanged.
    let correctAnchor = !pclProgramIsAbsoluteOnly(progOps)
    var curX = anchorX + (correctAnchor ? Double(pclAbsXOffsetUnits) * pclUnitPt : 0)
    var curY = anchorY + (correctAnchor ? Double(pclAbsYOffsetUnits) * pclUnitPt : 0)
    var stack: [(Double, Double)] = []

    for op in progOps {
        switch op {
        case .push:
            stack.append((curX, curY))
        case .pop:
            if let top = stack.popLast() { curX = top.0; curY = top.1 }
        case .moveX(let value, let relative):
            if relative {
                curX += Double(value) * pclUnitPt
            } else {
                curX = Double(value + pclAbsXOffsetUnits) * pclUnitPt
            }
        case .moveY(let value, let relative):
            if relative {
                curY += Double(value) * pclUnitPt
            } else {
                curY = Double(value + pclAbsYOffsetUnits) * pclUnitPt
            }
        case .fill(let wUnits, let hUnits, let fillGray):
            if wUnits != 0, hUnits != 0 {
                let wPt = Double(wUnits) * pclUnitPt
                let hPt = Double(hUnits) * pclUnitPt
                let rect = CGRect(x: curX, y: curY, width: wPt, height: hPt)
                rects.append(GraphicRect(shape: .rect(rect), gray: CGFloat(fillGray)))
            }
        case .ignored:
            break
        }
    }
    return rects
}

/// `true` when every move in `progOps` is ABSOLUTE — the anchor-independent case
/// `pclGraphicRects`'s own doc comment cites (LJ6DTP's page border: `ESC*p0002x0085Y`, no
/// leading sign, addresses the page's own top-left corner regardless of where the running
/// cursor is). `false` for a program that opens with a push and moves RELATIVE to it
/// (LJ6DTP's page-4 checkerboard) — its own real anchor is wherever the pctl attachment's
/// glyph lands, which two independently-laid-out renderers of the SAME document are not
/// guaranteed to agree on down to the point (confirmed: `QLCLIByteParityTests
/// .qlMatchesAppNativeRendering` disagreed with the main app's own on-screen render at
/// page 4 once this file started executing the checkerboard's relative ops — the
/// QuickLook extension's own `NSTextView` lays the SAME line out at a very slightly
/// different container width than the main app's, moving the anchor by enough to show up
/// as a real pixel diff). Gating on this keeps the border (this job's actual target,
/// item 1) while not drawing content whose placement isn't yet provably stable across
/// every renderer that calls into this file.
func pclProgramIsAbsoluteOnly(_ progOps: [PCLOp]) -> Bool {
    for op in progOps {
        switch op {
        case .push, .pop: return false
        case .moveX(_, let relative), .moveY(_, let relative): if relative { return false }
        case .fill, .ignored: continue
        }
    }
    return true
}

/// Job 495 (Class 7 residual, LJ6DTP.WS pages 5-8): `PageTextView.drawPCLGraphics`'s own
/// walk (above) only ever visits a page's REAL base fragments — but LJ6DTP's own border
/// control does not always sit on an ordinary line. On 4 of this fixture's 8 pages it sits
/// on that page's own OVERSIZED opening line (`docToPagelines`'s page-open banner/heading),
/// whose REAL AppKit fragment is `DocumentRenderer.renderPrinted`'s blank placeholder (`let
/// content = oversized ? PageLine([], soft:) : base` — same gap `AppOutput.passVectors`'s
/// own citation already names for cp437 box fills). The control's `.printedPCLProgram`
/// attribute survives fine — `naturalPass`/`attributedLine` build the self-pass from the
/// SAME `appendSpan` this file's own attachment comes from — it just lands on the SELF-PASS
/// overlay's own isolated `NSTextStorage`, which neither `drawPCLGraphics` nor (before this
/// job) this harness's own measurement ever inspected. Confirmed directly: LJ6DTP.WS's 8
/// border controls (`Document.pclPrograms` indices 0-3, 37-40) attach to pages 1-4's
/// ordinary body lines (found by the base-fragment walk) and pages 5-8's own line 0 (found
/// only here, `overprint == false` on every one of them — an oversized-line gap, not an
/// `.overprint`-chain one).
///
/// For an ABSOLUTE-only program (the border), the anchor this function computes is
/// provably inert: every op either ignores the running cursor entirely (`moveX`/`moveY`'s
/// non-relative branch overwrites `curX`/`curY` outright, `pclGraphicRects`'s own doc
/// comment) or draws relative to a cursor that was always just freshly overwritten that way
/// (no `push`/`pop`, `pclProgramIsAbsoluteOnly`'s own gate) — so the LIVE `manager`/`storage`
/// this function is handed is safe to read directly regardless of which renderer built it.
///
/// For a RELATIVE program (LJ6DTP.WS page 4's checkerboard), job 490's own diagnosis
/// ("the QuickLook extension's own NSTextView lays the SAME line out at a very slightly
/// different container width... moving the anchor by enough to show up as a real pixel
/// diff") turned out to be WRONG — job 495 measured the real anchor both renderers compute
/// for all 33 checkerboard controls (`PCL-ANCHOR-DEBUG`, since discarded) and found them
/// BYTE-IDENTICAL, both before and after routing the horizontal component through a fresh,
/// always-windowless `isolatedLineLayout` re-measurement (the SAME determinism
/// `passVectors`/`drawOversizedSelfPasses` already rely on elsewhere) — so this function
/// still does that re-measurement (cheap, and correct in principle for a genuinely unpinned
/// per-glyph X), but it was never the cause of job 490's regression. The REAL cause,
/// confirmed by comparing the two capture techniques' own output images directly
/// (`pixel-oracle-report/LJ6DTP.WS/p4-side-by-side.png`): a RELATIVE program's own pctl
/// attachment sits on an ORDINARY line squarely INSIDE the text flow, not in a page margin
/// like the border — `PagedDocumentView.drawPCLGraphics`'s own call site draws at the PAGE
/// level, UNDER every `PageTextView` subview in z-order (this file's own top doc comment:
/// "subviews ALWAYS composite on top of their superview's own drawing, regardless of call
/// order"). Invisible for the border (nothing else paints in the margin) but genuinely
/// covered, in the app's own LIVE `cacheDisplay` capture specifically, by whatever the
/// covering `PageTextView` paints at that same position — QuickLook's own `dataWithPDF`
/// capture (a from-scratch PDF walk, not a live view snapshot) did not exhibit the same
/// cover-up, which is what made this look like a cross-renderer POSITION disagreement
/// instead of the same-renderer Z-ORDER one it actually is. Fixed not in this function but
/// at its call sites: a relative program now draws from `OversizedPassOverlayView`'s own
/// overlay (`PagedDocumentView.drawPCLGraphicsOverlay`, added job 495) — the SAME
/// "draws on top of every PageTextView" mechanism `drawOversizedSelfPasses` already proves
/// out — while an absolute one keeps drawing from the base page level unchanged.
///
/// `manager`/`storage`/`glyphRange`/`fragment` are this line's own layout, live OR already
/// isolated — the SAME four `graphicCells` is already called with at every one of this
/// function's call sites (`PagedDocumentView.drawPCLGraphics`/`drawPCLGraphicsOverlay`/
/// `drawOversizedSelfPasses`, `AppOutput`'s test-harness mirrors) — `containerWidth` is only
/// consulted for the relative-program fallback relayout, `offset` is that SAME call's own
/// already-computed isolated-to-real (or live-to-real, now identity) transform, and
/// `includeAbsolute`/`includeRelative` let a caller draw only the kind that belongs at its
/// OWN z-order layer (the test harness, which has no z-order concept, keeps both true).
func pclRectsInIsolatedPass(
    manager: NSLayoutManager, storage: NSTextStorage, glyphRange: NSRange,
    fragment: CGRect, offset: CGPoint, containerWidth: CGFloat, pclPrograms: [[UInt8]],
    includeAbsolute: Bool = true, includeRelative: Bool = true
) -> [GraphicRect] {
    guard !pclPrograms.isEmpty else { return [] }
    var rects: [GraphicRect] = []
    let text = storage.string as NSString
    var g = glyphRange.location
    let end = glyphRange.location + glyphRange.length
    while g < end {
        defer { g += 1 }
        let charIndex = manager.characterIndexForGlyph(at: g)
        guard charIndex < text.length else { continue }
        guard let idx = storage.attribute(.printedPCLProgram, at: charIndex, effectiveRange: nil) as? Int,
              pclPrograms.indices.contains(idx)
        else { continue }
        let prog = parsePCLProgram(pclPrograms[idx])
        let isAbsolute = pclProgramIsAbsoluteOnly(prog)
        guard isAbsolute ? includeAbsolute : includeRelative else { continue }
        let loc = manager.location(forGlyphAt: g)
        var glyphX = Double(loc.x)
        if !isAbsolute {
            let charRange = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let fragmentText = storage.attributedSubstring(from: charRange)
            guard let isolated = isolatedLineLayout(fragmentText, width: containerWidth) else { continue }
            let isoG = isolated.glyphRange.location + (g - glyphRange.location)
            guard isolated.glyphRange.contains(isoG) else { continue }
            glyphX = Double(isolated.manager.location(forGlyphAt: isoG).x)
        }
        let anchorX = Double(fragment.origin.x) + glyphX + Double(offset.x)
        let anchorY = Double(fragment.origin.y + loc.y + offset.y)
        rects.append(contentsOf: pclGraphicRects(prog, anchorX: anchorX, anchorY: anchorY))
    }
    return rects
}
