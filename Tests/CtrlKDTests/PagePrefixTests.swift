/// `docToPagelines(..., maxPages:)` — the first N pages, and nothing else laid out.
///
/// WHY. The QuickLook THUMBNAIL draws page 1 and throws the rest away (planning #271
/// M10). Before this, asking for page 1 of `-HOLYMAC.WS` paginated all 367 of them
/// first. An extension has a time and memory budget it does not get to argue with, so
/// the work it does not need is work it must not do.
///
/// THE ONE THING THAT MATTERS. A thumbnail that disagrees with the document is worse
/// than a slow one, so the contract is byte identity, not approximation:
/// `pages(maxPages: 1)[0] == pages()[0]`, exactly, for every curated document. `Page`
/// is `Hashable`, so this really is every field — lines, spans, headers, footers,
/// overrides, geometry, the lot — not a rendered comparison that could agree by
/// accident.
///
/// WHAT IS NOT SHORT-CIRCUITED, and why (see `docToPagelines`' own comment): a print
/// stream, whose leading-blank strip is a minimum over every page in the document; and
/// a document with placeable notes, whose bottom-of-page reservation is decided while
/// walking the whole body. Both still answer `maxPages:` correctly — they just answer
/// it at full price. Those two are named in the parameter list below like the rest, so
/// the identity is proved for them too rather than assumed away.
import Foundation
import Testing
@testable import CtrlKD

/// The same ten documents the structural checks curate (`StructuralChecksTests`), for
/// the same reason: between them they carry columns, a head redefined mid-document,
/// notes, `.cp`, merge variables, a print stream and the corpus's longest reference
/// prose — every shape that makes page 1 depend on something other than page 1.
private let prefixDocs = [
    "REF/WINGDING.CHT",       // `.co5` — five sub-pages fold into one sheet
    "MICKEE/MICKEE.WS",       // columns on and off, `.cb`, a head change
    "MACROS/HOLYMAC/1-3MAC",  // a head redefined mid-document, `.cp`
    "MACROS/HOLYMAC/-HOLYMAC.WS",  // 367 pages: the reason this exists
    "OLDTIMES.WS",            // `.cp`, a running head, notes
    "LJ6DTP.WS",              // a driver document: substitutions, print controls
    "REF/WSFORMAT.WS",        // long, heavily dot-commanded reference prose
    "STRENGTH.WS",            // space-centred lines, no head or foot at all
    "RTF-RJS/NOVEL.WS",       // styles, `.tc` entries, merge variables
    "REF/TOCTRICK.WS",        // the merge page-number variable
    "VERSIONS.TXT",           // a printstream — the machine-margin exclusion
]

private func prefixDocument(_ name: String) throws -> Document {
    let url = URL(fileURLWithPath: sawyerArchivePath).appendingPathComponent(name)
    return try parse([UInt8](try Data(contentsOf: url)))
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: prefixDocs, [true, false])
func firstPageOfAPrefixIsTheFirstPageOfTheWholeRun(name: String, printed: Bool) throws {
    let doc = try prefixDocument(name)
    let full = docToPagelines(doc, printed: printed)
    let one = docToPagelines(doc, printed: printed, maxPages: 1)
    #expect(one.count == min(1, full.count), "\(name) printed=\(printed)")
    guard let a = one.first, let b = full.first else { return }
    #expect(a == b, "\(name) printed=\(printed): page 1 differs under maxPages: 1")
}

@Test(.enabled(if: sawyerArchiveArmed, sawyerArchiveSkipReason),
      arguments: prefixDocs)
func aTwoPagePrefixIsTheFirstTwoPagesOfTheWholeRun(name: String) throws {
    // One page is the thumbnail's case and the easy one — a cap that lands mid-document
    // rather than at its very start is where an off-by-one in the sub-page budget (a
    // `.co5` region is five sub-pages to one sheet) would actually show.
    let doc = try prefixDocument(name)
    let full = docToPagelines(doc, printed: true)
    let two = docToPagelines(doc, printed: true, maxPages: 2)
    #expect(two.count == min(2, full.count), "\(name)")
    for i in two.indices {
        #expect(two[i] == full[i], "\(name): page \(i + 1) differs under maxPages: 2")
    }
}

@Test
func noMaxPagesMeansEveryPage() throws {
    // The default must be exactly what it always was: a caller that passes nothing gets
    // the whole document, and `maxPages: 0` is not a way to ask for nothing.
    let doc = try parse(makeProse())
    #expect(docToPagelines(doc, printed: true)
            == docToPagelines(doc, printed: true, maxPages: nil))
    #expect(docToPagelines(doc, printed: true, maxPages: 0)
            == docToPagelines(doc, printed: true))
}
