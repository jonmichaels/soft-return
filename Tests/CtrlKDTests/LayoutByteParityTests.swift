/// The layout format's BYTE-parity guard (ruled 2026-08-18, "fix it all"): sr's layout
/// JSON is byte-identical to the Python oracle's, like every other format — the old
/// "compared as parsed data" carve-out is abolished and must never silently reopen.
///
/// `Resources/layout-parity-fixture.ws` is a synthetic WS5+ document (invented text,
/// real framing via ctrl-kd's own `tools/ws_fixture.py`) that exercises the parts of
/// the serializer that diverged before the ruling closed them:
///
///   - Python int-vs-float numeric spelling: `.lm 6`/`.rm 58` dot margins are Python
///     FLOATS (`"indent_cols": 5.0`, a float `cut_cols`), the `or 0` default is the
///     int 0, and `structure.col` inherits the flavor;
///   - the page dict's key order (pn/pc first) and its float geometry values;
///   - `json.dumps`' short escapes: the literal form feed's break `"origin": "\f"`;
///   - all four note kinds: labels, `fnref` runs, the printed footnote area (the
///     notes-path pages carry `{}` headers/footers, Python's plain-list truth);
///   - structure classification (bullets, def-list, spaces-centered line), `.tb` tab
///     stops, running heads, `.cp`, `.pa`, and a soft-return merge.
///
/// The expected files are the PYTHON ORACLE'S OWN OUTPUT, committed verbatim
/// (ctrl-kd @ 7fa1d5c, refreshed @ 3c5eb9f for the b26 visual pass note-marker-hang
/// fix -- the fixture's own footnote/endnote/annotation area mixes marker widths, so
/// `notesMarkerPadCols`/`_notes_marker_pad_cols` now pads three of its entries:
/// `ctrl-kd -t layout --fonts mac [--comments]` on the fixture) — regenerate them
/// from the oracle, never by hand and never from sr itself.
/// `layout-parity-modern-comments.json` covers the non-default `--comments` path: kept
/// comments produce zero-width anchor runs (`"text": ""` + `ref`) and positional
/// comment labels (1, 2 — not the offset-collapsed 1, 1 the pre-ruling code produced).
import Foundation
import Testing
@testable import CtrlKD

private func loadResource(_ name: String, ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext),
                           "\(name).\(ext) missing from the test bundle")
    return try Data(contentsOf: url)
}

@Test func layoutJSONIsByteIdenticalToPythonOracle() throws {
    let bytes = [UInt8](try loadResource("layout-parity-fixture", ext: "ws"))
    let expected = String(decoding: try loadResource("layout-parity-default", ext: "json"),
                          as: UTF8.self)
    let doc = parseWS(bytes)
    // Python's emit_layout ignores the mode — both must produce the same bytes.
    #expect(emitLayout(doc, mode: .modern) == expected)
    #expect(emitLayout(doc, mode: .printed) == expected)
}

@Test func layoutJSONWithCommentsIsByteIdenticalToPythonOracle() throws {
    let bytes = [UInt8](try loadResource("layout-parity-fixture", ext: "ws"))
    let expected = String(decoding: try loadResource("layout-parity-modern-comments",
                                                     ext: "json"),
                          as: UTF8.self)
    let doc = parseWS(bytes)
    var options = EmitOptions()
    options.notes = EmitOptions.allNotes            // --comments: keep all four kinds
    #expect(emitLayout(doc, mode: .modern, options: options) == expected)
}

@Test func layoutJSONOfAContentFreeDocumentBlanksHeadersFootersLikeThePythonOracle() throws {
    // Companion to PDFWriterTests' `printedPDFOfAContentFreeDocumentStillHonoursItsOwnMarginsAndHeader`
    // (REF/ADVANCE.DOT / REF/GALLEYS.DOT, Sawyer WS7 archive): b56040b made
    // `finalizePages`'s `pages.isEmpty` fallback synthesize a REAL `Page` carrying the
    // document's own final headers/footers, so the PDF renders them correctly. But
    // `docToPagelines` is the SAME function `emitLayout` calls to build the `printed.pages`
    // JSON block, and ctrl-kd's own equivalent fallback (`pages or [[]]`, pdf.py) returns a
    // bare Python list with no `.headers` attribute at all -- `emit_layout`'s
    // `getattr(page, 'headers', {})` therefore yields `{}` for that page. That's the exact
    // duck-typing gap the PDF fix worked around, left unpatched on ctrl-kd's JSON path, so
    // matching it byte-for-byte means blanking headers/footers here too -- the same
    // treatment `notesPath` already gets for its own analogous gap (see the doc comment
    // above `jsonHFDict`'s call site in `emitLayout`). Before this fix this test failed:
    // sr's JSON carried a real "1": "HEADER-#" entry where ctrl-kd's has `{}`.
    let doc = parseWS(bytes(".mt .7i\r\n.mb .6i\r\n.he HEADER-#\r\n.fo FOOTER-#\r\n"))
    for mode in [EmitMode.modern, .printed] {
        let json = emitLayout(doc, mode: mode)
        #expect(json.contains("\"headers\": {}"),
                "content-free document's printed page must have BLANK headers in the JSON (ctrl-kd's own `pages or [[]]` fallback has no `.headers` attribute), even though the PDF driver keeps the real header for rendering")
        #expect(json.contains("\"footers\": {}"))
        #expect(!json.contains("HEADER-1"), "the real header text must not leak into the JSON")
        #expect(!json.contains("FOOTER-1"), "the real footer text must not leak into the JSON")
    }
}
