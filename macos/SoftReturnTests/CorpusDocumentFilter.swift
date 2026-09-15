import Foundation
import Testing

/// Planning #262, item 1: `SR_DOC` narrows every corpus-walking oracle to one document or a short
/// list, so proving one page of one document is a short run rather than the whole corpus. The
/// app-test runner's `DOC=` key exports it, plain and `TEST_RUNNER_`-prefixed; unset, every walk
/// sees the whole corpus, exactly as before.
///
/// A name matches case-insensitively, with or without its extension: `LYING.WS`, `lying.ws` and
/// `LYING` all select `LYING.WS`, and `LYING.WS` also selects a list entry spelled `LYING`.
/// Several names are comma-separated.
///
/// Only WALKS are filtered — the lists a test iterates. A test that looks one document up by name
/// (`Oracle.allFixtureURLs.first { … }`) keeps finding it whatever `SR_DOC` says.
///
/// A NAME THAT MATCHES NOTHING FAILS THE WALK THAT MISSES IT (batch 14; batch 25, Athena). Filtered to
/// nothing, a walk would measure nothing and pass: `arguments:` generates zero cases and a `for` loop
/// never runs. So when a requested name matches no document in the list being filtered, the unmatched
/// names and that list are reported on the walk. Inside a running test that is an issue on the test. A
/// list built for `arguments:` is built before any test runs — for every parameterized test in the
/// target, selected or not — so there it gains one sentinel argument carrying the message, and the test
/// that receives it records the issue (`recordIfUnmatched`) instead of measuring. It never stops the run:
/// a name one walk lacks (`DOC=-HOLYMAC.WS` against the 22-document `ws7Fixtures`) must not take down a
/// walk that holds it (b25-geometry-holymac).
enum CorpusDocumentFilter {
    static let variable = "SR_DOC"

    /// The names `SR_DOC` asks for, or nil when it is unset or empty.
    static var requested: [String]? {
        let environment = ProcessInfo.processInfo.environment
        return names(from: environment[variable] ?? environment["TEST_RUNNER_" + variable])
    }

    static func names(from raw: String?) -> [String]? {
        guard let raw else { return nil }
        let names = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    /// Does `document` — a file name, a path or a bare stem — match any of `names`?
    static func matches(_ document: String, _ names: [String]) -> Bool {
        let file = (document as NSString).lastPathComponent
        let stem = (file as NSString).deletingPathExtension
        return names.contains { wanted in
            wanted.caseInsensitiveCompare(file) == .orderedSame
                || wanted.caseInsensitiveCompare(stem) == .orderedSame
                || (wanted as NSString).deletingPathExtension.caseInsensitiveCompare(file) == .orderedSame
        }
    }

    static func apply(_ documents: [String]) -> [String] {
        apply(documents, name: { $0 }, wanted: requested, report: reportUnmatched,
              sentinel: { unmatchedSentinel($0) })
    }

    static func apply(_ urls: [URL]) -> [URL] {
        apply(urls, name: { $0.lastPathComponent }, wanted: requested, report: reportUnmatched,
              sentinel: { URL(fileURLWithPath: "/" + unmatchedSentinel($0)) })
    }

    /// For a list of anything else. There is no sentinel for an arbitrary item, so this is for walks a
    /// running test filters in its own body.
    static func apply<Item>(_ items: [Item], name: (Item) -> String) -> [Item] {
        apply(items, name: name, wanted: requested, report: reportUnmatched)
    }

    /// The filter itself: `wanted` nil keeps every item; otherwise the matching items. A wanted name that
    /// matches none of them is reported — inside a running test, through `report`; outside one (an
    /// `arguments:` list being built, with no test to fail) the list gains one `sentinel` carrying the
    /// message, for the test that receives it to record. With no `sentinel` to give, `report` has it.
    static func apply<Item>(_ items: [Item], name: (Item) -> String, wanted: [String]?,
                            report: (String) -> Void, sentinel: ((String) -> Item)? = nil,
                            insideTest: Bool = Test.current != nil) -> [Item] {
        guard let wanted else { return items }
        let names = items.map(name)
        let unmatched = wanted.filter { requested in !names.contains { matches($0, [requested]) } }
        let kept = items.filter { matches(name($0), wanted) }
        guard !unmatched.isEmpty else { return kept }
        let message = unmatchedMessage(unmatched, in: names)
        if !insideTest, let sentinel {
            return kept + [sentinel(message)]
        }
        report(message)
        return kept
    }

    /// The messages behind the sentinels handed out so far, by sentinel name.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String: String] = [:]

        func add(_ message: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            let name = "SR_DOC-UNMATCHED-\(messages.count + 1)"
            messages[name] = message
            return name
        }

        func message(for name: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return messages[name]
        }
    }

    private static let registry = Registry()

    /// A new sentinel name standing for `message`: what an `arguments:` list carries in place of a
    /// document `SR_DOC` asked for and the list does not have.
    static func unmatchedSentinel(_ message: String) -> String {
        registry.add(message)
    }

    /// The first line of every test fed an `arguments:` list this filter builds: `true` when `argument` is
    /// a sentinel, after recording its issue — the unmatched names and the list — on the running test,
    /// which then returns without measuring.
    static func recordIfUnmatched(_ argument: String) -> Bool {
        guard let message = registry.message(for: argument) else { return false }
        Issue.record(Comment(rawValue: message))
        return true
    }

    static func recordIfUnmatched(_ argument: URL) -> Bool {
        recordIfUnmatched(argument.lastPathComponent)
    }

    static func unmatchedMessage(_ unmatched: [String], in names: [String]) -> String {
        let shown = names.prefix(40).map { ($0 as NSString).lastPathComponent }
        let more = names.count > shown.count ? ", … (\(names.count) in all)" : ""
        return "\(variable) names \(unmatched.joined(separator: ", ")), which matches no document in this walk's list, "
            + "so the walk would measure nothing and pass. The list: [\(shown.joined(separator: ", "))\(more)]"
    }

    /// Inside a test: an issue on that test. Outside one, only a list with no sentinel to give lands
    /// here (no such `arguments:` list exists in this target); it is printed, never a stop of the run.
    static func reportUnmatched(_ message: String) {
        if Test.current != nil {
            Issue.record(Comment(rawValue: message))
        } else {
            print("SR_DOC-UNMATCHED \(message)")
        }
    }
}

extension Tag {
    /// A suite or test that walks the corpus — every document, not one. The Fast test plan skips
    /// these; the Corpus plan, the release gate, runs everything.
    @Tag static var corpus: Self
}

@Suite struct CorpusDocumentFilterTests {
    @Test func namesSplitOnCommasAndIgnoreBlanks() {
        #expect(CorpusDocumentFilter.names(from: nil) == nil)
        #expect(CorpusDocumentFilter.names(from: " , ") == nil)
        #expect(CorpusDocumentFilter.names(from: "LYING.WS, -README ,") == ["LYING.WS", "-README"])
    }

    @Test func aNameMatchesWithOrWithoutItsExtensionInAnyCase() {
        #expect(CorpusDocumentFilter.matches("LYING.WS", ["lying.ws"]))
        #expect(CorpusDocumentFilter.matches("LYING.WS", ["LYING"]))
        #expect(CorpusDocumentFilter.matches("LYING", ["LYING.WS"]))
        #expect(CorpusDocumentFilter.matches("/private/tmp/ws7/LYING.WS", ["lying"]))
        #expect(!CorpusDocumentFilter.matches("LYING.WS4", ["LYING.WS"]))
        #expect(!CorpusDocumentFilter.matches("WARPRAYR.WS", ["LYING.WS", "-README"]))
    }

    @Test(.enabled(if: CorpusDocumentFilter.requested == nil, "SR_DOC is set for this run"))
    func unsetKeepsEveryDocumentInOrder() {
        #expect(CorpusDocumentFilter.apply(["B.WS", "A.WS"]) == ["B.WS", "A.WS"])
    }

    /// Batch 14: a typo filters to nothing, and says so, naming the name and the list.
    @Test func aNameMatchingNothingIsReportedWithTheList() {
        var reports: [String] = []
        let kept = CorpusDocumentFilter.apply(["LYING.WS", "WARPRAYR.WS"], name: { $0 },
                                              wanted: ["LYNIG.WS"], report: { reports.append($0) })
        #expect(kept.isEmpty)
        #expect(reports.count == 1)
        #expect(reports.first?.contains("LYNIG.WS") == true)
        #expect(reports.first?.contains("[LYING.WS, WARPRAYR.WS]") == true)
    }

    /// A list that holds every requested name reports nothing; one name missing from a list of
    /// several still reports, naming only the missing one.
    @Test func onlyTheUnmatchedNamesAreReported() {
        var reports: [String] = []
        let all = CorpusDocumentFilter.apply(["LYING.WS", "-README.WS"], name: { $0 },
                                             wanted: ["lying", "-README.WS"], report: { reports.append($0) })
        #expect(all == ["LYING.WS", "-README.WS"])
        #expect(reports.isEmpty)
        let some = CorpusDocumentFilter.apply(["LYING.WS", "-README.WS"], name: { $0 },
                                              wanted: ["LYING.WS", "SAWYER"], report: { reports.append($0) })
        #expect(some == ["LYING.WS"])
        #expect(reports.count == 1)
        #expect(reports.first?.hasPrefix("SR_DOC names SAWYER,") == true)
    }

    /// Inside a running test the real reporter records an issue: `withKnownIssue` fails this test
    /// if none is recorded, so a quiet reporter cannot pass here.
    @Test func insideATestAnUnmatchedNameRecordsAnIssue() {
        withKnownIssue("an SR_DOC typo must fail the walk that sees it") {
            _ = CorpusDocumentFilter.apply(["LYING.WS"], name: { $0 }, wanted: ["LYNIG.WS"],
                                           report: CorpusDocumentFilter.reportUnmatched)
        }
    }

    /// Batch 25: building `arguments:`, outside any test, an unmatched name never stops the run. The list
    /// keeps what matched and gains one sentinel; nothing is reported until a test receives the sentinel,
    /// which records the issue naming the name and the list, and a real document is never one.
    @Test func outsideATestAnUnmatchedNameBecomesOneSentinelArgument() {
        var reports: [String] = []
        let list = CorpusDocumentFilter.apply(["LYING.WS", "-README.WS"], name: { $0 },
                                              wanted: ["LYING.WS", "-HOLYMAC.WS"], report: { reports.append($0) },
                                              sentinel: { CorpusDocumentFilter.unmatchedSentinel($0) }, insideTest: false)
        #expect(reports.isEmpty, "outside a test the list reports through its sentinel, not directly")
        #expect(list.count == 2 && list.first == "LYING.WS", "list \(list)")
        withKnownIssue("the sentinel fails the test that receives it") {
            #expect(CorpusDocumentFilter.recordIfUnmatched(list[1]))
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("-HOLYMAC.WS") && $0.rawValue.contains("[LYING.WS, -README.WS]") }
        }
        #expect(!CorpusDocumentFilter.recordIfUnmatched("LYING.WS"), "a real document is not a sentinel")
    }

    /// The same for a list of URLs: the sentinel is a URL the receiving test recognises.
    @Test func aURLListGainsASentinelURL() {
        let list = CorpusDocumentFilter.apply([URL(fileURLWithPath: "/corpus/LYING.WS")], name: { $0.lastPathComponent },
                                              wanted: ["-HOLYMAC.WS"], report: { _ in },
                                              sentinel: { URL(fileURLWithPath: "/" + CorpusDocumentFilter.unmatchedSentinel($0)) },
                                              insideTest: false)
        #expect(list.count == 1, "list \(list)")
        withKnownIssue("the sentinel URL fails the test that receives it") {
            #expect(CorpusDocumentFilter.recordIfUnmatched(list[0]))
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("-HOLYMAC.WS") }
        }
        #expect(!CorpusDocumentFilter.recordIfUnmatched(URL(fileURLWithPath: "/corpus/LYING.WS")))
    }
}
