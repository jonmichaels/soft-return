import CtrlKD
import SoftReturnCLI

/// The one geometry `sawyer_preset_pdf_sr.json` records, as conversion options: Printed
/// PDF with the `sawyer` page-settings preset and nothing else the CLI would add by
/// default (the engine's own office font names, not the CLI's Mac ones), so the bytes are
/// those of a bare `emitPDF` over the preset page. Quirks stay at their default (`auto`):
/// that is what a document nobody ran `applyQuirks` on gets at render time. The generator writes the file with this job and
/// `CorpusParityTests` checks it with the same job.
public func sawyerPresetJob() throws -> ConversionJob {
    guard let settings = pagePresets["sawyer"] else {
        throw GeneratorError(message: "pagePresets[\"sawyer\"] missing — PageGeometry.swift's " +
            "preset table changed; update this job to match")
    }
    var options = Options()
    options.mode = .printed
    options.formats = ["pdf"]
    options.pageSettings = settings
    options.fontsTarget = EmitOptions().fontsTarget
    return ConversionJob(options: options)
}
