/// Table of Contents / Index compilation — shared core, consumed by every emitter.
///
/// b24 engine wave, round 18 item 1 (RULINGS-LEDGER row 4, "NOT BUILT" — "collected,
/// never compiled"). `doc.tocEntries`/`doc.indexEntries` were captured (correctly kept
/// out of body text — `parseCollectDot`) but no emitter ever compiled a TOC/Index section
/// anywhere. Jon: "It should probably export in all formats even though non-paged ones
/// couldn't be referenced." Direct port of `compile_toc`/`compile_index`/
/// `_toc_index_display` (core.py).

/// One entry's display text — WSFORMAT's own `#` convention for `.tc` ("A '#' indicates
/// where the page number is to go in the entry"), applied to `.ix` too for the same
/// reason (an index entry that happens to carry a literal `#` gets the same substitution;
/// one that doesn't still gets its page number appended, matching the common index
/// convention "Term ... 42"). `pageNumbers` ({blockIndex: page number}, from the REAL
/// paginator) is `nil` for every non-paged format (HTML, Markdown, Text, Modern RTF) — `#`
/// is simply dropped there: honest text and ordering, no page reference a non-paged
/// format could ever resolve. Port of `_toc_index_display`.
func tocIndexDisplay(_ text: String, blockIndex: Int, pageNumbers: [Int: Int]?) -> String {
    guard let pageNumbers else {
        return text.replacingAll("#", with: "").trimmedTrailing()
    }
    let pn = pageNumbers[blockIndex]
    if text.contains("#") {
        return text.replacingAll("#", with: pn.map(String.init) ?? "")
    }
    if let pn {
        return "\(text) \(pn)"
    }
    return text
}

/// `[(level, display_text)]` from `doc.tocEntries`. Register C7. Port of `compile_toc`.
func compileTOC(_ doc: Document, pageNumbers: [Int: Int]? = nil) -> [(level: Int, text: String)] {
    doc.tocEntries.map { entry in
        (level: entry.level, text: tocIndexDisplay(entry.text, blockIndex: entry.blockIndex,
                                                    pageNumbers: pageNumbers))
    }
}

/// `[display_text]` from `doc.indexEntries` — same `#`/page-number resolution as
/// `compileTOC`, flattened (an index entry carries no level). Register C6. Port of
/// `compile_index`.
func compileIndex(_ doc: Document, pageNumbers: [Int: Int]? = nil) -> [String] {
    doc.indexEntries.map { entry in
        tocIndexDisplay(entry.text, blockIndex: entry.blockIndex, pageNumbers: pageNumbers)
    }
}

/// `<nav>`/`<section>` for the compiled TOC/Index — TOC before Index, each clearly headed.
/// Non-paged: `pageNumbers: nil`, honest text and ordering only. A `.tc` level becomes a
/// `margin-left` indent (an ordered-list NESTED per level would be the more "correct" DOM,
/// but a document's own levels are not always well-nested — e.g. a lone `.tc3` with no
/// `.tc2` parent — and a flat, indented list degrades honestly either way; the simpler
/// shape). Port of `_html_toc_index`.
func htmlTOCIndex(_ doc: Document) -> String {
    let toc = compileTOC(doc, pageNumbers: nil)
    let idx = compileIndex(doc, pageNumbers: nil)
    guard !toc.isEmpty || !idx.isEmpty else { return "" }
    var parts: [String] = []
    if !toc.isEmpty {
        // Python's bare f-string float interpolation (`{max(0, level - 1) * 1.5}em`), not
        // a fixed-decimal format -- Swift's default `Double` description matches it for
        // this domain (an integer level times 1.5: 0.0, 1.5, 3.0, 4.5, ...).
        let items = toc.map { entry in
            let indent = Double(max(0, entry.level - 1)) * 1.5
            return "<li style=\"margin-left:\(indent)em\">" + htmlEscape(entry.text) + "</li>"
        }.joined()
        parts.append("<nav aria-label=\"Table of Contents\"><h2>Table of Contents</h2>"
            + "<ol>\(items)</ol></nav>")
    }
    if !idx.isEmpty {
        let items = idx.map { "<li>\(htmlEscape($0))</li>" }.joined()
        parts.append("<section aria-label=\"Index\"><h2>Index</h2><ul>\(items)</ul></section>")
    }
    return parts.joined()
}

/// Plain-text TOC/Index lines — TOC before Index, each clearly headed, a `.tc` entry
/// indented two spaces per level. Every non-paged format (Text, Markdown, HTML, Modern
/// RTF) shares this same `pageNumbers: nil` reading: honest text and ordering, no page
/// reference a non-paged format could ever resolve (Printed PDF/RTF alone borrow a REAL
/// paginator). Port of `_plain_toc_index_lines`.
///
/// `public` (b24 completion, C2): the app's `appKitRenderedPDF` needs the SAME compiled
/// TOC/Index content Modern RTF's own `--toc on` shows — no page references, since
/// AppKit's own pagination for that export is a separate model from any engine paginator
/// (real page numbers here would name a page the export's own output does not actually
/// break on). Shared-API discipline: the app consumes this verdict rather than
/// re-deriving `.tc`/`.ix` compilation itself.
public func plainTOCIndexLines(_ doc: Document) -> [String] {
    let toc = compileTOC(doc, pageNumbers: nil)
    let idx = compileIndex(doc, pageNumbers: nil)
    var lines: [String] = []
    if !toc.isEmpty {
        lines.append("TABLE OF CONTENTS")
        lines.append("")
        lines.append(contentsOf: toc.map { String(repeating: "  ", count: max(0, $0.level - 1)) + $0.text })
        lines.append("")
    }
    if !idx.isEmpty {
        lines.append("INDEX")
        lines.append("")
        lines.append(contentsOf: idx)
    }
    return lines
}
