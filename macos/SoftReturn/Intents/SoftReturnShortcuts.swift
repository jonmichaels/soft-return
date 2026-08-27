import AppIntents

/// What makes "Convert WordStar Document" and "Diagnose WordStar Document" show up in the
/// Shortcuts app and answer to Siri phrases, rather than merely existing as `AppIntent`
/// types Shortcuts never learns about.
struct SoftReturnShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertWordStarDocumentIntent(),
            phrases: [
                "Convert a document with \(.applicationName)",
                "Convert a WordStar document with \(.applicationName)",
            ],
            shortTitle: "Convert Document",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: DiagnoseWordStarDocumentIntent(),
            phrases: [
                "Diagnose a document with \(.applicationName)",
                "Diagnose a WordStar document with \(.applicationName)",
            ],
            shortTitle: "Diagnose Document",
            systemImageName: "stethoscope"
        )
    }
}
