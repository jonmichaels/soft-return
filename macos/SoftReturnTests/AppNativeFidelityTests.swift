import CtrlKD
import Foundation
import Testing
@testable import SoftReturn

/// THE APP'S OWN PCL COORDINATE TIER — Jon's ruling, 2026-09-07: Soft Return's views are
/// held to the SAME tests ctrl-kd and `sr` run, which means the real WordStar captures, not
/// only agreement with our own engine.
///
/// ## Why this suite has to exist
///
/// Everything the app had before this was APP-VS-ENGINE parity —
/// `PrintedStructuralParityTests`, `NativeVsEngineGeometryTests`, `PixelOracleAppEngineTests`
/// all compare the app's render against this repo's own `emitPDF`. That is a PROXY. It
/// establishes that the app agrees with the engine; it establishes nothing directly about
/// whether either agrees with what WordStar 7 actually put on paper. The app's fidelity
/// claim was therefore transitive, riding on the engine's own PCL-tier result — which runs
/// on the maintainer's own dev host, over the ENGINE's PDF, and had never been run over the
/// app's own Printed output. This suite closes that gap by measuring the app's bytes against the captures
/// directly.
///
/// ## What it renders
///
/// The app's AppKit-rendered Printed PDF — `ExportEngine.render(formats: [.pdf], style:
/// .printed, viewStyle: .native)`, which is the facsimile pass `makePrintOperation` renders
/// for a Native window, i.e. the same bytes Cmd-P produces. Deliberately NOT the library
/// path (`convertData`), which would just re-measure the engine and reproduce the proxy this
/// suite exists to escape.
///
/// ## What it compares against
///
/// ctrl-kd's OWN gate, unmodified and unforked, through the driver `sr`'s own
/// `PCLFidelityTests` already uses: `Tests/CtrlKDTests/Support/run_pcl_fidelity_gate.py
/// report --doc=NAME --pdf=PATH`. That script splices a caller-supplied PDF into ctrl-kd's
/// `pcl_tolerance.doc_report()`, so the font-class tolerances, the named-divergence
/// manifest and the clean/divergent verdict are ctrl-kd's, computed over the app's bytes.
/// Reusing it rather than writing a second gate is the whole point: two implementations of
/// a tolerance model is two things to drift.
///
/// ## Expected result, and why a difference here is interesting
///
/// `sr`'s own per-document set is 14 clean with LJ6DTP, LYING, WARPRAYR and -SCREEN named.
/// The app SHOULD land on the same set. Where it does not, the difference is specifically
/// the app's own rendering — the AppKit text stack, its font substitution, its own
/// placement — rather than anything the engine does, because the engine's result for the
/// same document is already known. That is the one thing this suite can say that the
/// engine's own PCL tier cannot.
///
/// ## Inputs, and why this skips rather than fails without them
///
/// Needs `ws7-prints/v3` inside `CTRLKD_PRIVATE_CORPUS` (the PRISTINE.EXE captures — v1 is
/// Sawyer's WSCHANGE-customized install and is DEPRECATED as an oracle by Jon's ruling of
/// 2026-08-24) and a ctrl-kd checkout via `CTRLKD_SRC`. Neither is on every machine, and a
/// missing tool is an environment fact, not a failure of the app — so it is a NAMED skip
/// saying exactly which input is absent, never a silent pass and never a red gate.
// The arming condition lives on the @Test below, not on @Suite: a `@Suite` trait that
// reads the attached type's own static members is a circular macro reference and does
// not compile ("circular reference resolving attached macro 'Suite'"). This is the same
// shape `AppAnswerKeyParityTests` already uses, and it produces the identical NAMED skip.
/// `.serialized` — this suite lays out the armed corpus through AppKit on the main actor.
/// See the register: "a suite that lays out the armed corpus is serialized." Measured
/// 2026-09-07: concurrent corpus-wide layout walks turned 21-27s tests into 14-35 MINUTE
/// stalls that killed two full runs; serialized, they match their run-alone times exactly.
@Suite(.serialized)
struct AppNativeFidelityTests {

    /// The 18 documents `ws7-prints/v3` captures.
    static let documents = [
        "BOXES", "DOCA", "DOCB", "DOCC", "DOCD", "LYING", "OCAPTAIN", "DOCE", "PREVIEW",
        "-README", "SAWYER", "-SCREEN", "SCRIPT", "DOCF", "TWAINLET", "VERSIONS",
        "WARPRAYR", "LJ6DTP",
    ]

    /// WHICH DOCUMENTS ARE EXPECTED TO DIVERGE IS READ FROM CTRL-KD'S OWN MANIFEST, never
    /// held as a copy here.
    ///
    /// This used to be `["LJ6DTP", "LYING", "WARPRAYR", "-SCREEN"]` in Swift, and that list
    /// went stale the moment ctrl-kd 227e020 made word segmentation symmetric and -SCREEN
    /// came back CLEAN (15 of 18). A stale expectation is worse here than a wrong number: it
    /// would have treated -SCREEN as "known divergent, report don't fail" on a document the
    /// engine now renders perfectly, so the app's OWN missing glyphs on that page would have
    /// been absorbed as expected instead of reported as the app bug they are.
    ///
    /// The gate's own report already carries the manifest entry as `recorded`, so the
    /// verdict comes from there — one source of truth, the same reasoning that keeps the
    /// Symbol substitution in the engine rather than ported into the app.

    // MARK: - Inputs

    /// ctrl-kd's checkout ROOT. `CTRLKD_SRC` names its `src/` directory, so the value has
    /// to be normalized before `runGate` re-appends `src` for the child process — see
    /// `PrivateCorpusSupport.ctrlkdCheckoutRoot(default:)`, which owns that rule.
    static var ctrlkdSource: URL? {
        let sibling = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("projects/ctrl-kd", isDirectory: true)
        let root = PrivateCorpusSupport.ctrlkdCheckoutRoot(default: sibling)
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    /// `ws7-prints/v3` specifically. v1 present is NOT good enough — it is the contaminated
    /// capture set, and measuring against it would mark the very corrections this round
    /// landed (auto-leading, page numbering, `.mt`/`.hm`) as failures.
    static var v3Captures: URL? {
        guard let root = ProcessInfo.processInfo.environment["CTRLKD_PRIVATE_CORPUS"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_CTRLKD_PRIVATE_CORPUS"]
        else { return nil }
        let v3 = URL(fileURLWithPath: root).appendingPathComponent("ws7-prints/v3", isDirectory: true)
        return FileManager.default.fileExists(atPath: v3.path) ? v3 : nil
    }

    static var driverScript: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SoftReturnTests
            .deletingLastPathComponent()      // macos
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Tests/CtrlKDTests/Support/run_pcl_fidelity_gate.py")
    }

    static var isArmed: Bool {
        ctrlkdSource != nil && v3Captures != nil && PrivateCorpusSupport.isArmed
            && FileManager.default.fileExists(atPath: driverScript.path)
    }

    static var skipReason: Comment {
        if PrivateCorpusSupport.isArmed == false {
            return "the private corpus is not armed — set CTRLKD_PRIVATE_CORPUS. NOT a pass."
        }
        if v3Captures == nil {
            return """
            ws7-prints/v3 is not in the corpus on this machine — the PRISTINE.EXE captures \
            this tier measures against. v1 is present but is DEPRECATED as an oracle (Jon, \
            2026-08-24: Sawyer's WSCHANGE-customized install) and is deliberately NOT used \
            as a fallback. Pull the corpus. NOT a pass: these documents were not checked.
            """
        }
        if ctrlkdSource == nil {
            return """
            no ctrl-kd checkout — set CTRLKD_SRC or clone to ~/projects/ctrl-kd. This tier \
            runs ctrl-kd's OWN tolerance gate; without it there is nothing to run. NOT a pass.
            """
        }
        return "the PCL gate driver is missing from Tests/CtrlKDTests/Support. NOT a pass."
    }

    // MARK: - Rendering the app's own Printed bytes

    /// The app's AppKit-rendered Printed PDF for one document — the Cmd-P facsimile pass,
    /// not the library emitter.
    @MainActor
    static func appPrintedPDF(forDocumentNamed name: String) throws -> [UInt8] {
        let url = try #require(resolveSource(name), "no .WS/.WS4 source for \(name) in this corpus")
        let bytes = [UInt8](try Data(contentsOf: url))
        let defaults = UserDefaults(suiteName: "AppPCLFidelity.\(UUID().uuidString)")!
        let state = try DocumentState(data: bytes, settings: SettingsStore(defaults: defaults),
                                      docPath: url.path)
        let products = try ExportEngine.render(
            document: state.document, state: state, formats: [.pdf], notes: NoteSelection(),
            style: .printed, viewStyle: .native,
            title: url.deletingPathExtension().lastPathComponent, docPath: url.path)
        return try #require(products.first?.bytes, "the app produced no Printed PDF for \(name)")
    }

    /// Where a captured document's source lives. The gate's own `--doc` phase-1 call answers
    /// this authoritatively (ctrl-kd's `resolve_doc_paths`), so this asks IT rather than
    /// duplicating a resolution table that would drift from the corpus index.
    static func resolveSource(_ name: String) -> URL? {
        guard let report = try? runGate(doc: name, pdf: nil),
              report["resolvable"] as? Bool == true,
              let path = report["ws_path"] as? String
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Driving ctrl-kd's own gate

    /// `words` is the app's own Printed bytes already extracted into ctrl-kd's engine-CHARS
    /// schema. It is passed INSTEAD of `--pdf`, and that is the whole point of this round:
    /// ctrl-kd's PDF parser reads its own emitter's op shape by regex and finds ZERO words
    /// in a Quartz PDF, which is why every document reported `pdf=None` before. The two
    /// flags are mutually exclusive in the driver.
    static func runGate(doc: String, pdf: URL?, words: URL? = nil) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["python3", driverScript.path, "report", "--doc=\(doc)"]
        if let pdf { args.append("--pdf=\(pdf.path)") }
        if let words { args.append("--engine-chars=\(words.path)") }
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        if let src = ctrlkdSource { environment["CTRLKD_SRC"] = src.appendingPathComponent("src").path }
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GateError.badOutput("\(doc): gate produced no JSON (status \(process.terminationStatus)): \(errText)")
        }
        return object
    }

    enum GateError: Error { case badOutput(String) }

    // MARK: - The Native font licence

    struct Licence: Sendable {
        let id: String
        let substitutedFace: String
        let reasons: Set<String>
        let ceiling: Int
    }

    /// `Fixtures/native-divergences.json`, filtered to the rows that apply to this document.
    /// A `document` of `*` is a class ruling and applies to every document.
    static func licensedDivergence(for doc: String) throws -> Licence? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-divergences.json")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        guard let root = raw as? [String: Any],
              let rows = root["divergences"] as? [[String: Any]] else { return nil }
        // A row naming this document wins over a `*` class row: it carries the measured
        // ceiling, which is the whole point of naming it.
        let applicable = rows.filter {
            ($0["applies_to"] as? String) == "native"
                && (($0["document"] as? String) == doc || ($0["document"] as? String) == "*")
        }
        guard let row = applicable.first(where: { ($0["document"] as? String) == doc })
                ?? applicable.first(where: { $0["gate_reasons"] != nil })
        else { return nil }
        guard let reasons = row["gate_reasons"] as? [String] else { return nil }
        return Licence(
            id: row["id"] as? String ?? "(unnamed row)",
            substitutedFace: row["substituted_face"] as? String ?? "(face not named)",
            reasons: Set(reasons),
            ceiling: row["count_ceiling"] as? Int ?? 0)
    }

    // MARK: - The gate

    /// Every captured document, through the app's own Printed view, measured against the
    /// real WordStar captures by ctrl-kd's own tolerance model.
    @Test(.enabled(if: isArmed, skipReason), arguments: documents)
    @MainActor func appPrintedViewMatchesTheWordStarCapture(doc: String) throws {
        let pdf = try Self.appPrintedPDF(forDocumentNamed: doc)
        // Extracted on THIS side, by AppPDFWords, because ctrl-kd cannot read these bytes.
        // AppPDFWordsProofTests is what makes that trustworthy: it runs ctrl-kd's own
        // --dump-engine-words and this extractor over the SAME engine PDF and requires them
        // to agree to 0.01pt. Without that proof standing, a divergence reported here would
        // be unattributable between the app's rendering and our reading of it.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPCL-\(UUID().uuidString).json")
        // CHARACTERS, not words: ctrl-kd segments both sides with one implementation
        // (engine-chars schema v2). The app used to segment its own side, and a second copy
        // of that rule is what this deletes.
        try AppPDFWords.charsJSON(from: pdf).write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let report = try Self.runGate(doc: doc, pdf: nil, words: scratch)
        guard report["resolvable"] as? Bool == true else {
            Issue.record("\(doc): not resolvable in this corpus — \(report["reason"] as? String ?? "no reason given")")
            return
        }

        let live = report["live"] as? [String: Any] ?? [:]
        let counts = live["counts_by_reason"] as? [String: Int] ?? [:]
        // ctrl-kd's own "clean" bar: font substitution is a ruled, expected difference for
        // ANY renderer that is not WordStar on a LaserJet; everything else is a real gap.
        // The literal is `font-substitution`, HYPHENATED — it is `ACCEPTED_REASON` in
        // run_pcl_fidelity_gate.py and `real_bugs` in ctrl-kd's own test_pcl_fidelity.py,
        // and this file previously spelled it with an underscore, which matches no reason
        // ctrl-kd ever emits. Harmless today (no call site emits that reason yet, as the
        // driver's own comment says) and silently wrong the day one does.
        let realBugs = counts.filter { $0.key != "font-substitution" }.values.reduce(0, +)

        // ctrl-kd's own per-divergence lines, verbatim in test_pcl_fidelity.py's format:
        // "[reason] page N words=... ws7=... pdf=... font_class=... -- detail". Without
        // these a failure here is a bare integer, which is not a report anybody can act on;
        // with them a Swift failure and a `pytest -m pcl` failure read the same.
        let rawLines = live["divergence_lines"] as? [String] ?? []
        let lines = rawLines.joined(separator: "\n  ")
        let named = lines.isEmpty ? "(the gate listed no per-divergence lines)" : "\n  " + lines

        // THE GATE COULD NOT READ THIS PDF AT ALL. `pdf=None` on a divergence line means the
        // WS7 word matched nothing anywhere in the supplied PDF — not "in the wrong place",
        // but "no words found". When that is true of EVERY listed divergence, the run is
        // measuring the extractor, not the renderer, and reporting it as N-hundred
        // rendering defects would be a false report of the worst kind.
        //
        // ctrl-kd's tools/fidelity_gate.py extracts words by a hand-written regex over its
        // OWN emitter's op shape — its docstring says so outright: "Every text-drawing
        // operation pdf.py writes has one shape: BT /Fn SIZE Tf [SCALE Tz ]RISE Ts X Y Td
        // (TEXT) Tj ET -- one regex covers the whole emitter". It requires `Td` positioning,
        // that exact operand order, and a single `(TEXT) Tj`. A Quartz/AppKit PDF positions
        // with `Tm` and draws with a `TJ` array, so the regex matches zero ops (verified
        // directly against _TEXT_OP_RE: ctrl-kd's shape 1 match, `Tm`+`TJ` 0, `Td`+`TJ` 0).
        //
        // This suite renders the app's AppKit facsimile ON PURPOSE (see the header — the
        // library path would just re-measure the engine), so the two are incompatible by
        // construction, and no amount of app-side fixing changes it. Named here rather than
        // silently absorbed, and NOT wrapped in a withKnownIssue: there is no ruling to cite
        // and this is a real open gap in the tier, not an accepted divergence.
        if !rawLines.isEmpty, rawLines.allSatisfy({ $0.contains("pdf=None") || $0.hasPrefix("... and") }) {
            Issue.record("""
                \(doc): THE GATE EXTRACTED NO WORDS FROM THE APP'S PDF — every divergence \
                reads `pdf=None` ("no corresponding word anywhere"), \
                counts_by_reason=\(counts). This is not \(realBugs) rendering defects. \
                ctrl-kd's fidelity_gate parses ITS OWN emitter's op shape by regex \
                (`... Td (TEXT) Tj ET`); the app's Printed view is Quartz/AppKit, which \
                writes `Tm` + `TJ`, and the regex matches zero ops against it. Verified two \
                ways: the same driver on the ENGINE's PDF for BOXES returns clean with \
                matches_recorded=true, and _TEXT_OP_RE matches 1 op of ctrl-kd's shape and \
                0 of either Quartz shape. The tier needs a real PDF text extractor on the \
                app side (PDFKit) feeding the gate word positions instead of PDF bytes, or \
                a ruling that the app's Printed facsimile is measured some other way. \
                Named: \(named)
                """)
            return
        }

        // THE LICENCE IS A FILE, AND IT IS FONT-CLASS ONLY.
        //
        // Jon's rule (decision register 2026-08-12) is that Printed IS the engines' output —
        // and it literally is: `ViewStyle.printed` shows `emitPDF(.printed)`'s own bytes in a
        // PDFView, so a coordinate tier over THAT view would compare the engine to itself and
        // pass vacuously. This suite measures NATIVE, the AppKit facsimile Cmd-P produces
        // from a Native window, which is the only surface where the question has content.
        //
        // Native's licence is fonts and nothing else. So a document may diverge here only if
        // `Fixtures/native-divergences.json` names it, only for the gate reasons that row
        // lists, and only up to that row's own ceiling. A licensed divergence with no ceiling
        // could not tell a font substitution from a new defect hiding behind one.
        let licence = try Self.licensedDivergence(for: doc)
        if let licence {
            let unlicensedReasons = counts.keys.filter { !licence.reasons.contains($0) }
            #expect(unlicensedReasons.isEmpty, """
                \(doc): licensed for font-class divergence (\(licence.id), \
                \(licence.substitutedFace)) but reported reasons this licence does not \
                cover: \(unlicensedReasons.sorted()). counts_by_reason=\(counts). A row in \
                native-divergences.json licenses a FONT difference, never a missing \
                character or a misplaced line.\nNamed: \(named)
                """)
            #expect(realBugs <= licence.ceiling, """
                \(doc): \(realBugs) divergences against this licence's ceiling of \
                \(licence.ceiling) (\(licence.id)). The substituted face explains a stable \
                number of these; a rise past the ceiling is a new defect wearing the \
                licence's clothes.\nNamed: \(named)
                """)
            return
        }

        // A document ctrl-kd records CLEAN must be clean for the app too — there is no
        // remaining allowance, and `recordedVerdict` being nil (no manifest entry at all)
        // deliberately lands here rather than in the tolerant branch.
        #expect(realBugs == 0, """
            \(doc): the APP's Printed view diverges from the real WordStar capture in \
            \(realBugs) non-font-substitution place(s) — counts_by_reason=\(counts). The \
            engine renders this document CLEAN against the same capture, so this is the \
            app's own rendering, not a shared engine gap.\nNamed: \(named)
            """)
    }
}
