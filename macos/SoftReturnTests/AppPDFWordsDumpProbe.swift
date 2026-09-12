import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// A DIAGNOSTIC, not a gate: writes the app's own Printed PDF and this extractor's reading of
/// it somewhere a sandboxed session can actually open them.
///
/// The PCL tier renders the app's facsimile into a temp file and deletes it, which is right
/// for a gate and useless when the question is "what did the extractor actually see?". That
/// question has now come up three times — the Form XObject blind spot, the word-splitting
/// rule, and the zero-words regression this file was added for — and each time the answer
/// took a whole round-trip through a test failure message to get at. Dumping the bytes and
/// the JSON side by side turns that into one read.
///
/// Writes into the drop box directory because that is the one place both sides of the fence
/// can reach: the test host runs as Jon outside the sandbox, and the coder session can read
/// it. Nothing here asserts anything, so it cannot fail a run; it is gated on the corpus
/// purely so it does not write files on a machine that has nothing to dump.
@Suite(.serialized, .enabled(if: PrivateCorpusSupport.isArmed, PrivateCorpusSupport.skipReason))
struct AppPDFWordsDumpProbe {

    static var dumpDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/coder-apptest/wordsdump",
                                    isDirectory: true)
    }

    /// Which documents to dump: whatever `AppNativeFidelityTests` is currently failing on.
    ///
    /// `WORDSDUMP_DOCS` (comma-separated) overrides it — but NOT through the drop box, whose
    /// runner refuses any key outside `MODE ONLY_TESTING SAWYER CORPUS CTRLKD PARALLEL
    /// RESULT` and says so in `agent.log` while still running the request with the key
    /// dropped. Cost me one cycle; recorded here so it costs nobody a second.
    static let defaultDocuments = ["PREVIEW", "-README", "SAWYER"]

    static let documents: [String] = {
        guard let raw = ProcessInfo.processInfo.environment["WORDSDUMP_DOCS"] else {
            return defaultDocuments
        }
        let names = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return names.isEmpty ? defaultDocuments : names
    }()

    @Test(arguments: AppPDFWordsDumpProbe.documents) @MainActor func dumpAppAndEngineWords(doc: String) throws {
        let directory = Self.dumpDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The app's own Native facsimile — the exact bytes the tier measures.
        let appPDF = try AppNativeFidelityTests.appNativePDF(forDocumentNamed: doc)
        try Data(appPDF).write(to: directory.appendingPathComponent("\(doc)-app.pdf"))
        let appWords = try AppPDFWords.payload(from: appPDF)
        try AppPDFWords.json(from: appPDF)
            .write(to: directory.appendingPathComponent("\(doc)-app-words.json"))
        try AppPDFWords.charsJSON(from: appPDF)
            .write(to: directory.appendingPathComponent("\(doc)-app-chars.json"))

        // The engine's, for the same document, through the same extractor.
        if let source = AppNativeFidelityTests.resolveSource(doc) {
            let enginePDF = try AppAnswerKeyParityTests.documentOperationsBytes(
                fixture: source, format: "pdf", mode: .printed,
                title: "", fontsTarget: .office, pictures: .embed)
            try Data(enginePDF).write(to: directory.appendingPathComponent("\(doc)-engine.pdf"))
            try AppPDFWords.json(from: enginePDF)
                .write(to: directory.appendingPathComponent("\(doc)-engine-words.json"))
            // OUR reading of the ENGINE's PDF, in the same schema ctrl-kd's
            // --dump-engine-chars produces — the two are directly comparable, and any
            // difference here is this extractor's, not the app's rendering.
            try AppPDFWords.charsJSON(from: enginePDF)
                .write(to: directory.appendingPathComponent("\(doc)-engine-chars.json"))
        }

        // Printed, not asserted — this is the line that says whether the extractor saw
        // anything at all, which is the whole question.
        print("WORDSDUMP \(doc): app pages=\(appWords.n_pages) "
              + "words=\(appWords.words.count) rasters=\(appWords.rasters.count)")
        for word in appWords.words.prefix(8) {
            print("WORDSDUMP   \(word.page) \"\(word.text)\" x=\(word.x_pt) y=\(word.y_top_pt) "
                  + "font=\(word.font ?? "nil") class=\(word.font_class)")
        }
    }
}
