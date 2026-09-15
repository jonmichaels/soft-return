import Foundation
import os

/// #271 M7: signposted intervals around opening a document and changing page, for Instruments
/// (subsystem `me.beforeti.softreturn`, category `Performance`) and for `HolymacTimingTests`, which
/// reads the same intervals back through `startRecording()` / `stopRecording()`.
///
/// The names say where the time goes:
/// - `open.parse`: `DocumentState` from the file's bytes — the engine's detect and parse, and the
///   document's pictures (`WSDocument.read`);
/// - `open.window`: the document window built, its first content loaded (`DocumentWindowController.init`);
/// - `open.showWindow`: the first-open geometry, the window on screen, the zoom settled;
/// - `open.firstPageDrawn`: from the window's construction to the first draw of the pages;
/// - `render.content` / `render.pageSize`: `DocumentRenderer` — the engine's layout
///   (`docToPagelines`) and the attributed text built from it — for the page on screen, and for
///   any caller that only wanted the page's size;
/// - `pages.setContent`: TextKit's page chain built and laid out for every page (`PagedDocumentView`);
/// - `printed.emit` / `printed.load`: the engine's Printed PDF, and PDFKit loading it;
/// - `zoom.apply`, `bottomBar.update`, `page.change`.
///
/// A progressive open (batch 25) adds:
/// - `render.engine`: the engine's pagination for Native (`DocumentRenderer.nativeRenderSession`);
/// - `render.firstPages`: the text for the pages shown first;
/// - `render.chunk`: the text for one later chunk of pages, one turn of the main run loop;
/// - `pages.setContent.all`: every page laid out once the last chunk is rendered;
/// - `open.allPages`: from the window's construction until every page is laid out.
///
/// Batch 26 (the progressive load) adds:
/// - `open.parse` and `render.engine` / `printed.emit` as work done OFF the main thread, recorded when it returns
///   (`record(_:startedAt:)`);
/// - `render.session`: a render's main-thread setup, once the engine's half is in;
/// - `render.chunk`: one turn's slice of text (Native pages or Modern flow items);
/// - `render.finish`: the rendered document built from the last slice;
/// - `pages.layOut`: one turn's slice of pages laid out (`PagedDocumentView.layOutMorePages(until:)`).
///
/// Recording is off unless a test turns it on; a signpost costs next to nothing without Instruments.
@MainActor
enum PerformanceSignposts {
    static let signposter = OSSignposter(subsystem: "me.beforeti.softreturn", category: "Performance")

    /// One finished interval, as a test reads it.
    struct Interval: Codable, Equatable {
        let name: String
        let milliseconds: Double
    }

    /// An interval under way.
    struct Token {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let start: UInt64
    }

    private static var isRecording = false
    private static var recorded: [Interval] = []

    /// Starts keeping every interval that ends from now on, forgetting any kept before.
    static func startRecording() {
        recorded = []
        isRecording = true
    }

    /// Stops keeping intervals and hands back the ones kept, in the order they ended.
    static func stopRecording() -> [Interval] {
        isRecording = false
        defer { recorded = [] }
        return recorded
    }

    static func begin(_ name: StaticString) -> Token {
        Token(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()),
              start: DispatchTime.now().uptimeNanoseconds)
    }

    static func end(_ token: Token) {
        signposter.endInterval(token.name, token.state)
        guard isRecording else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - token.start) / 1_000_000
        recorded.append(Interval(name: "\(token.name)", milliseconds: elapsed))
    }

    /// Batch 26: an interval that ran off the main thread — the engine's work for a render or a parse —
    /// recorded once it is over, back on the main thread. `start` is `DispatchTime.now().uptimeNanoseconds`
    /// when it began. Instruments sees an event; a recording test sees the whole interval.
    static func record(_ name: StaticString, startedAt start: UInt64) {
        signposter.emitEvent(name)
        guard isRecording else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        recorded.append(Interval(name: "\(name)", milliseconds: elapsed))
    }

    /// `body`, inside an interval named `name`.
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let token = begin(name)
        defer { end(token) }
        return try body()
    }
}
