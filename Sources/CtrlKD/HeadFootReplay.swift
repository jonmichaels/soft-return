/// The running head/foot occurrences of a document, grouped by where the printed body walk
/// meets them, so `resolvePrintedBody` can replay each one as an `.hf` item at the point
/// the paginator should apply it.
///
/// `doc.hfEvents` is the document's flat list. Each `HFEvent` carries its `parity`
/// (planning #250: `nil` for a plain `.h1`/`.he`/`.f1`/`.fo`, else `.even`/`.odd` for
/// `.h1e`/`.h1o`/`.f1e`/`.f1o`), its `pcl` (cause 10: the 0x0F user print controls of the
/// line, empty for every document whose running heads carry none) and its `within` (triage
/// Q9). An event read INSIDE a block carries its own line position and is replayed THERE,
/// between that block's own lines; any other is replayed at the block boundary its
/// `blockAnchor` names.
struct HeadFootReplay {
    typealias Event = (kind: HFKind, line: Int, text: String, parity: HFParity?,
                       pcl: [HFPrintControl])

    private var atBlock: [Int: [Event]] = [:]
    private var inside: [HFWithin: [Event]] = [:]

    init(_ doc: Document) {
        for event in doc.hfEvents {
            let entry: Event = (event.kind, event.line, event.text, event.parity, event.pcl)
            if let within = event.within {
                inside[within, default: []].append(entry)
            } else {
                atBlock[event.blockAnchor, default: []].append(entry)
            }
        }
    }

    private static func items(_ events: [Event]) -> [PrintedBodyItem] {
        events.map { .hf(kind: $0.kind, line: $0.line, text: $0.text, parity: $0.parity,
                         pcl: $0.pcl) }
    }

    /// Events anchored at the boundary before block `bi`.
    func beforeBlock(_ bi: Int) -> [PrintedBodyItem] {
        Self.items(atBlock[bi] ?? [])
    }

    /// Events recorded `linesBefore` lines into block `bi`.
    func within(block bi: Int, linesBefore: Int) -> [PrintedBodyItem] {
        Self.items(inside[HFWithin(block: bi, linesBefore: linesBefore)] ?? [])
    }

    /// Events whose recorded line index is at or past block `bi`'s line count belong at the
    /// block's END, the same place the block-boundary anchor would have put them. The
    /// block's lines are not always `block.lines` (`.pf on` re-wraps), so this is a scan, not
    /// an equality: an event must never be dropped for landing past it.
    func atEnd(ofBlock bi: Int, lineCount: Int) -> [PrintedBodyItem] {
        var out: [PrintedBodyItem] = []
        for key in inside.keys.filter({ $0.block == bi && $0.linesBefore >= lineCount })
                              .sorted(by: { $0.linesBefore < $1.linesBefore }) {
            out.append(contentsOf: Self.items(inside[key] ?? []))
        }
        return out
    }
}
