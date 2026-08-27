/// WordStar's own inline colour (symmetric type 1) — shared CGA/EGA palette table and
/// helpers, consumed by both `emitRTF` and `emitHTML`.
///
/// b24 engine wave, round 18 item 2 (RULINGS-LEDGER row 10, "NOT BUILT"). WordStar's own
/// inline colour is a 0-15 PALETTE INDEX, the standard 16-colour CGA/EGA screen palette
/// every DOS-era text program shared — distinct from LJ6DTP's own driver-specific PDF gray
/// table (`PDFDriverLJ6DTP.swift`'s colour-to-gray mapping, untouched by this round). Index
/// 0 (Black) never reaches a span as a tag at all (`Span.colour` is `nil` for it — see
/// `Span.swift`'s own doc comment), so the table only needs to answer for 1-15, but is
/// defined for all 16 for completeness. Port of `_CGA_PALETTE` (emit.py).
let cgaPalette: [(r: Int, g: Int, b: Int)] = [
    (0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170),
    (170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
    (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
    (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255),
]

/// Two-digit lowercase hex, for a CSS `#RRGGBB` colour.
func hex2(_ v: Int) -> String {
    let hexDigits = Array("0123456789abcdef")
    let clamped = max(0, min(255, v))
    return String(hexDigits[clamped / 16]) + String(hexDigits[clamped % 16])
}

/// The fixed 16-entry `\colortbl` group covering the whole CGA palette — emitted only
/// when the document actually uses a colour tag (see `emitRTF`'s own gate). Port of
/// `_RTF_COLOURTBL`.
let rtfColourTable: String = {
    var out = #"{\colortbl;"#
    for (r, g, b) in cgaPalette {
        out += "\\red\(r)\\green\(g)\\blue\(b);"
    }
    return out + "}"
}()

/// WordStar index N -> `\cf(N+1)` — `\colortbl`'s FIRST real entry (index 0, "Black") is
/// `\cf1` (RTF colour numbers are 1-based; index 0 before the first `;` is the reader's
/// own "automatic" colour). Port of `_rtf_colour_num`.
func rtfColourNum(_ index: Int) -> Int { index + 1 }

/// Every WordStar colour INDEX (0-15, the raw palette value — unlike `fontN`, `colourN`'s
/// own N is not an array index into anything) that appears on a span anywhere in the
/// document, sorted. Port of `_html_colour_used`.
func coloursUsed(_ doc: Document) -> [Int] {
    var used = Set<Int>()
    for block in doc.blocks {
        for line in block.lines {
            for span in line.spans {
                if let colour = span.colour {
                    used.insert(colour)
                }
            }
        }
    }
    return used.sorted()
}
