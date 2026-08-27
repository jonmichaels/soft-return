import AppIntents
import CtrlKD
import Foundation

/// Shortcuts' "Diagnose WordStar Document" — a thin translation over
/// `DocumentOperations.diagnose(data:path:)`. Never throws for a bad file: diagnosis is
/// exactly the operation that must say something about a file "Convert" would refuse (the
/// same distinction `sr --diagnose` draws in `Run.swift`), so its result always carries a
/// variant, even `binary`.
struct DiagnoseWordStarDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Diagnose WordStar Document"
    static let description = IntentDescription(
        "Reports a WordStar-era document's detected variant, page count, dot commands, and unrecognized codes.")

    // Job 342 (b23 floor drop): see `ConvertWordStarDocumentIntent`'s header comment —
    // `@Parameter(title:supportedContentTypes:)` needs macOS 15 for an `IntentFile`
    // property; `diagnose(data:path:)` below never rejects a file anyway (it is defined to
    // report even `binary`), so dropping the content-type filter loses nothing functional.
    @Parameter(title: "Document")
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Diagnose \(\.$file)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WordStarDiagnosis> {
        let bytes = [UInt8](file.data)
        let diagnosis = DocumentOperations.diagnose(data: bytes, path: file.filename)
        let result = WordStarDiagnosis(
            variantName: diagnosis.variant.rawValue,
            pageCount: diagnosis.pageCount,
            dotCommands: diagnosis.dotCommands,
            unknownCodeCount: diagnosis.unknownCodeCount)
        return .result(value: result)
    }
}

/// The structured "Diagnose" result Shortcuts can pull fields off of ("Get Variant from
/// Diagnosis Result", etc.) — a one-off value, not a persisted/looked-up entity, so
/// `TransientAppEntity` rather than a full `AppEntity` with its own `EntityQuery`.
struct WordStarDiagnosis: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "WordStar Diagnosis"

    @Property(title: "Variant") var variantName: String
    /// `nil` only when the file didn't parse at all (`variant` is `binary`).
    @Property(title: "Page Count") var pageCount: Int?
    @Property(title: "Dot Commands") var dotCommands: [String]
    @Property(title: "Unknown Code Count") var unknownCodeCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(variantName)",
            subtitle: "\(dotCommands.count) dot command(s) · \(unknownCodeCount) unknown code(s)")
    }

    init() {
        variantName = ""
        pageCount = nil
        dotCommands = []
        unknownCodeCount = 0
    }

    init(variantName: String, pageCount: Int?, dotCommands: [String], unknownCodeCount: Int) {
        self.variantName = variantName
        self.pageCount = pageCount
        self.dotCommands = dotCommands
        self.unknownCodeCount = unknownCodeCount
    }
}
