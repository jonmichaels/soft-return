import AppKit
import CtrlKD
import os
import SoftReturnShared
import SwiftUI

// MARK: - Preview pane

/// A tiny full page of the selected file, in the chosen style, plus the Get-Info-style
/// panel underneath.
struct BatchPreview: View {
    let item: BatchItem
    let style: ViewStyle
    let variant: Variant?

    /// Native and Printed render IDENTICAL pixels for this thumbnail purpose — the on-screen
    /// difference between them is only in how a PDF EXPORT's bytes get produced
    /// (`ExportEngine`'s print-path carve-out), never in `PagePreviewRenderer`'s own facsimile
    /// layout, so both map to `RenderStyle.native` here exactly as `ViewStyle.renderStyle`
    /// already documents for "export what you see" (job 265/323).
    private var previewStyle: RenderStyle { style.renderStyle }

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            if let image = PagePreviewRenderer.firstPage(of: item.url, style: previewStyle, variant: variant) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .border(Color(nsColor: .separatorColor))
                    // Job 511 (2a): see `previewColumn` — 400pt lets this reach the column's
                    // full width instead of the old 240pt cap leaving most of it empty.
                    .frame(maxHeight: 400)
                    .accessibilityIdentifier("batch-preview-page")
                    .accessibilityLabel("Preview of \(item.name)")
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .aspectRatio(8.5 / 11, contentMode: .fit)
                    .overlay { Text("No preview").foregroundStyle(.secondary) }
                    .frame(maxHeight: 400)
            }

            // Get-Info-style panel: the spec fixes these rows and their order. Job 511 (2a):
            // centered as a block under the (now full-width) preview above, rather than
            // pinned to the leading edge — the Grid's own label/value columns stay
            // trailing/leading relative to EACH OTHER, only the whole block moves.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(PagePreviewRenderer.info(for: item.url, style: previewStyle, variant: variant), id: \.0) { row in
                    GridRow {
                        Text(row.0 + ":")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        Text(row.1)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.caption)
            .accessibilityIdentifier("batch-info-panel")
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
