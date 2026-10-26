/// Print-time column layout for a `.co n` region: folds the paginators' per-column sub-pages
/// into the physical sheets they sit side by side on.

func applyColumns(_ doc: Document, _ pages: [Page]) -> [Page] {
    if pages.isEmpty { return pages }
    let size = printedSize(doc)
    var out: [Page] = []
    var i = 0
    let nPages = pages.count
    while i < nPages {
        let pg = pages[i]
        // A page's own columnar-ness is decided by the FIRST columnar block referenced
        // anywhere on it (see this function's own doc comment for why NOT just the
        // first line's).
        let firstColBI = pg.lines.first { pl in
            guard let bi = pl.bi, bi >= 0, bi < doc.blocks.count else { return false }
            return (doc.blocks[bi].columns ?? 1) > 1
        }?.bi
        let cols = firstColBI.map { doc.blocks[$0].columns ?? 1 } ?? 1
        if pg.isEmpty || cols <= 1 {
            out.append(pg)
            i += 1
            continue
        }
        let blk = doc.blocks[regionFirstBI(doc, firstColBI!)]
        let gutterCols = blk.columnGutter ?? 0.0
        let rmCols = blk.rightMargin ?? 65.0
        let gutterPt = gutterCols * pdfPtPerCol
        let rmPt = rmCols * pdfPtPerCol
        var merged = Page([])
        // Group metadata (headers/footers/margins/geometry) comes from the FIRST
        // sub-page in the group -- "page just started" state, exactly what an ordinary
        // page's own metadata already means.
        merged.headers = pg.headers
        merged.footers = pg.footers
        merged.footerInUse = pg.footerInUse
        // cause 10: the running head's own print controls travel with its text through
        // the merge, same passthrough as `headers`/`footers`.
        merged.headerPcl = pg.headerPcl
        merged.footerPcl = pg.footerPcl
        // planning #250: carry the source page's own parity font/tab override through
        // the merge, same passthrough as headers/footers just above.
        merged.headHfOverride = pg.headHfOverride
        merged.footHfOverride = pg.footHfOverride
        merged.mtLines = pg.mtLines
        merged.mbLines = pg.mbLines
        merged.plLines = pg.plLines
        merged.orientation = pg.orientation
        merged.hmLines = pg.hmLines
        merged.fmLines = pg.fmLines
        merged.poCols = pg.poCols
        merged.poParity = pg.poParity
        merged.autoPagenoPo = pg.autoPagenoPo
        merged.explicitBreak = pg.explicitBreak
        merged.explicitBreakBI = pg.explicitBreakBI
        // planning #227 follow-up (2026-09-09): this page's own column geometry,
        // recorded once here rather than re-derived per line by every consumer --
        // `emitLayout` and Soft Return.app's Native view both need it to draw column
        // boundaries/reset the vertical flow at each column change (see `PageLine.col`'s
        // own doc comment). `columnWidthPt` is captured from the FIRST real line below
        // (whichever column it's in -- the formula is the same for all of them), not
        // re-derived from `printedLeft` here, so it agrees exactly with the per-line
        // `left` values this same loop sets.
        merged.columns = cols
        merged.columnGutterPt = gutterPt
        // planning #227 follow-up (2026-09-12): A COLUMN GROUP SHARES ONE TOP. Every
        // column of this sheet begins where the COLUMNAR REGION begins on it, not at
        // the sheet's own first text line -- so a sheet that opened with a
        // non-columnar prefix (`REF/WINGDING.CHT` and `REF/SYMBOL.CHT`: a title line
        // and its blank, ahead of the `.co5`; `PRINTERS/fontcrib.ws` and `PRINTER.PS`:
        // the same shape) pushes columns 1..n-1 down by exactly that prefix's height.
        // MEASURED against real WS7 (`ws7-prints/v4`, PRISTINE.EXE):
        //   REF/WINGDING.CHT  WS7 columns 2-5 open at 153.2pt, which is `.mt 1.6"`
        //                     (115.2) + 12 + 12 + their own 14pt lead -- NOT the
        //                     sheet's own 129.2pt first line. Same 45 lines as column
        //                     1's columnar part; this engine gave them 46.
        //   REF/SYMBOL.CHT    WS7 124.4pt, 47 lines (engine: 100.4pt, 48).
        //   fontcrib.ws, PRINTER.PS   WS7 66.8pt, 51 lines (engine: 42.8pt, 52).
        // Summed from the prefix lines' OWN leads, the same quantity the paginator
        // charged against each column's budget (`colOffsetPt`) -- derived twice from
        // the same leads rather than threaded. Port of Python's `_apply_columns`.
        var prefixPt = 0.0
        for pl0 in pages[i].lines {
            if let bi0 = pl0.bi, bi0 >= 0, bi0 < doc.blocks.count,
               (doc.blocks[bi0].columns ?? 1) > 1 { break }
            prefixPt += pl0.lead ?? printedLead(doc)
        }
        merged.columnTopOffsetPt = prefixPt
        let groupEnd = Swift.min(i + cols, nPages)
        // A later sub-page belonging to a DIFFERENT columns/gutter pair (a new `.co`
        // restatement) or a non-columnar page ends the group early -- the forced break
        // on state-change (research §7) means this should only ever happen exactly at
        // `i + cols`, never inside it, but the check is cheap insurance.
        var colIdx = 0
        for j in i..<groupEnd {
            let sub = pages[j]
            let subColBI = sub.lines.first { pl in
                guard let bi = pl.bi, bi >= 0, bi < doc.blocks.count else { return false }
                return (doc.blocks[bi].columns ?? 1) > 1
            }?.bi
            let subRegionBlk = subColBI.map { doc.blocks[regionFirstBI(doc, $0)] }
            let subCols = subRegionBlk.map { $0.columns ?? 1 } ?? 1
            let subGutter = subRegionBlk.map { $0.columnGutter ?? 0.0 } ?? 0.0
            if subCols != cols || subGutter != gutterCols { break }
            for var pl in sub.lines {
                let baseLeft = pl.left ?? printedLeft(doc, size: size)
                // `.rm` IS the column's own width. WordStar measures `.rm` from the
                // `.po` origin, not from the paper's left edge -- the same reading
                // `printedHfRight` already uses for an ordinary line's right edge --
                // so there is nothing to subtract.
                //
                // This used to read `rmPt - baseLeft`, and planning #227's own
                // research validated that against `sawyer/REF/SYMBOL.CHT`, whose
                // `.po .0"` is ZERO: the two formulas are identical when `.po` is 0,
                // which is why the subtraction survived. Every OTHER `.co` document in
                // the corpus has a non-zero `.po`, and all of them landed their columns
                // `.po` points per column too far left, overprinting column 1
                // (`sawyer/REVIEW.DOC` page 1 was unreadable for it). MEASURED against
                // real WS7 (ws7-prints/v4, PRISTINE.EXE), column origins in points:
                //   REF/WINGDING.CHT `.po .3"` `.rm .88"` gutter .75"
                //       WS7: 21.6 / 138.9 / 256.3 / 373.6 / 491.0
                //       this formula: 21.6 + i*(63.36 + 54) -- exact
                //       old formula: 21.6 + i*(41.76 + 54)  -- 21.6pt/col short
                //   REVIEW.DOC `.rm 3.13"` gutter .25": WS7 57.6 / 300.9
                //   REF/SYMBOL.CHT `.po .0"` -- unchanged either way.
                // Port of Python's `pdf._apply_columns`.
                let columnWidthPt = rmPt
                if merged.columnWidthPt == nil { merged.columnWidthPt = columnWidthPt }
                pl.left = baseLeft + Double(colIdx) * (columnWidthPt + gutterPt)
                // planning #227 follow-up: the unambiguous "which column, RESET Y"
                // signal -- see `PageLine.col`'s own doc comment. Every real line this
                // loop touches belongs to a column (0 for the page's own non-columnar
                // prefix lines too, per this function's own doc comment: column 0's x
                // IS the page's ordinary left origin).
                pl.col = colIdx
                merged.lines.append(pl)
            }
            colIdx += 1
        }
        out.append(merged)
        i += colIdx > 0 ? colIdx : 1
    }
    return out
}
