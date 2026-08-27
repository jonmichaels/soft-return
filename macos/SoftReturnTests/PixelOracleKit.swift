import AppKit
import Foundation
import Testing

/// PIXEL ORACLE — a reusable region-level visual-diff engine.
///
/// Job 223 (Jon's generalization ruling, finding E, supersedes the job's narrower framing):
/// inputs are (a) any page-producer (a closure yielding page bitmaps) and (b) any
/// reference-producer (same shape); output is a region-diff report + PNG artifacts. Nothing in
/// THIS file knows about Soft Return, WordStar, CtrlKD, or PDF — that knowledge lives entirely
/// in the ADAPTER (`PixelOracleAppEngineTests.swift`, the FIRST CUSTOMER: the app's real view
/// pipeline vs the engine's real `emitPDF`, not the shape of the harness). Same clean-boundary
/// convention `RenderProbeKit.swift` already established for this repo's probe utilities — no
/// separate package/target yet, just a module with no app-specific hardcodes, adoptable as-is
/// by a future iOS app (a UIKit page-producer + the same engine reference-producer, compared
/// through the identical core below — only the `PageImage` production changes per platform).
public enum PixelOracleKit {

    // MARK: - Inputs

    /// One rendered page, ready to compare. `label` is caller-defined (`"p1"`, whatever the
    /// adapter's own page numbering is) — the core never assumes a numbering scheme, and never
    /// assumes the two sides used the same PAGE COUNT (that mismatch is itself surfaced as an
    /// error, not silently zipped/truncated).
    /// `@unchecked`: `NSBitmapImageRep` predates Swift concurrency and isn't marked `Sendable`,
    /// but every `PageImage` in this harness is built and consumed synchronously on the main
    /// actor within one test — never mutated after construction, never shared across a real
    /// concurrency boundary.
    public struct PageImage: @unchecked Sendable {
        public let label: String
        public let bitmap: NSBitmapImageRep
        /// The page's size in POINTS — independent of the bitmap's own pixel dimensions/scale,
        /// so actual and reference can be produced at different backing scales and still
        /// compare correctly (each side's ink density is measured in its own pixel grid, then
        /// expressed in the shared point-space grid).
        public let pointSize: CGSize
        public init(label: String, bitmap: NSBitmapImageRep, pointSize: CGSize) {
            self.label = label
            self.bitmap = bitmap
            self.pointSize = pointSize
        }
    }

    public enum PixelOracleError: Error, CustomStringConvertible {
        case pageCountMismatch(actual: Int, reference: Int)
        case emptyBitmap(String)
        case cannotEncodePNG(String)
        public var description: String {
            switch self {
            case .pageCountMismatch(let a, let r):
                return "actual produced \(a) page(s), reference produced \(r) — page count "
                    + "itself is a finding, not something to zip/truncate past"
            case .emptyBitmap(let label):
                return "\(label): zero-size bitmap, nothing to scan"
            case .cannotEncodePNG(let label):
                return "\(label): could not encode a diff artifact as PNG"
            }
        }
    }

    // MARK: - Output

    /// Region-diff classes. A small closed set rather than free text: the findings TABLE
    /// (fixture x page x region class, this job's Part 1 deliverable) needs a stable class
    /// column to group and count by.
    public enum RegionClass: String, Sendable, CaseIterable {
        /// Ink present in the reference, absent in actual — content the actual side never drew
        /// at all (a missing banner, a missing knockout, a hidden running line that should show).
        case missingInActual
        /// Ink present in actual, absent in the reference — content actual drew that the
        /// reference renderer does not (a leaked control string, a policy-divergent glyph).
        case extraInActual
        /// Ink present on BOTH sides in this region, but density disagrees beyond tolerance —
        /// wrong content, wrong colour/gray (white-on-black knockout rendering as invisible
        /// text on white), or geometry drift too small to move a region's grid cell but large
        /// enough to change how much ink lands inside it (a shifted word, a wrong font size).
        case contentDiffers
    }

    public struct Finding: Sendable, CustomStringConvertible {
        public let page: String
        public let regionClass: RegionClass
        /// The region's bounding box, in POINTS, TOP-LEFT origin — the same convention as
        /// every other geometry figure in this repo (`RenderedDocument.textFrame`,
        /// `EngineTruth.StructuralLine.yFromTop`), so a finding can be cross-referenced against
        /// existing structural oracles without a coordinate translation.
        public let regionPt: CGRect
        /// Ink-coverage fraction (0...1) inside this region, actual vs reference — the raw
        /// evidence the classification above was computed from.
        public let actualInk: Double
        public let referenceInk: Double

        public var description: String {
            String(format: "%@ [%@] rect=(%.1f,%.1f %.1fx%.1f)pt actualInk=%.3f referenceInk=%.3f",
                   page, regionClass.rawValue, regionPt.minX, regionPt.minY,
                   regionPt.width, regionPt.height, actualInk, referenceInk)
        }
    }

    public struct PageReport: Sendable {
        public let page: String
        public let findings: [Finding]
        public let sideBySideURL: URL?
        public let deltaURL: URL?
    }

    public struct FixtureReport: Sendable {
        public let fixture: String
        public let pages: [PageReport]
        public var findings: [Finding] { pages.flatMap(\.findings) }
    }

    // MARK: - Method

    /// Region-level diff via a GRID (fixed-size cells, in points) merged into connected
    /// components — a hybrid, and the reason this job's brief names both methods ("grid or
    /// connected-component diff").
    ///
    /// **Why grid-first, not a raw per-pixel diff:** two honestly-identical renders from two
    /// independent rasterizers (AppKit glyph drawing vs PDFKit/CGPDF) never agree pixel-for-
    /// pixel at a shared glyph edge — antialiasing alone would flag thousands of 1px fringe
    /// pixels as "different" and bury real structural findings (a missing 72pt banner, a
    /// missing knockout bar) in noise. Cell-level INK DENSITY (fraction of non-background
    /// pixels inside the cell, sampled on a fixed sub-grid rather than every pixel — see
    /// `sampleStride` below) absorbs antialiasing automatically: an honestly-matching cell's
    /// density differs by a few percent at most between rasterizers, while a cell blank on one
    /// side and painted on the other differs by tens of percentage points. `tolerance` (default
    /// 0.12 — 12 points of coverage) sits above realistic antialiasing/hinting drift and below
    /// any real structural gap.
    ///
    /// **Why connected-component merge after the grid pass:** a single defect (a missing banner
    /// spanning dozens of cells) must read as ONE finding/region in the table, not one row per
    /// grid cell — the table is meant to be human-scannable evidence of DEFECT CLASSES, not a
    /// raw cell dump. 4-connected same-`RegionClass` cells are flood-filled into one region;
    /// its reported ink figures are the mean across its cells.
    ///
    /// **What this method is blind to, by design:** anything smaller than one grid cell (a
    /// single stray pixel), and any content whose average density over a whole cell still
    /// lands within tolerance of a correct render (e.g. a 1-2pt position drift on a single thin
    /// vertical rule might not move a 12pt cell's density enough to register). `gridCellPt`
    /// exists to be tuned per caller when a finer or coarser structural resolution is needed —
    /// no silent cap: whatever cell size is passed is exactly what gets enforced, and is
    /// recorded in the report so a reader knows the resolution the "no divergence" verdict was
    /// measured at.
    ///
    /// ## Noise floor (job 231 calibration — read before trusting a "0 findings" verdict)
    /// Two noise classes are now KNOWN and, to the extent job 231 could calibrate for them,
    /// suppressed. A "0 findings" result means "no divergence beyond this floor" — never
    /// "pixel-identical."
    /// 1. **Sub-pixel rasterizer fringe** (job 230's discovery, job 231's own re-diagnosis
    ///    widened it): AppKit's `cacheDisplay` and PDFKit's `PDFPage.thumbnail` are independent
    ///    rasterizers whose ink for the SAME honestly-correct geometry differs by <=1 device
    ///    pixel at feature edges — two confirmed sub-cases, both from direct pixel-level
    ///    inspection of WORDSTAR.WS's rows (job 230's evidence fixture): (a) a thin feature (an
    ///    underline) lands on a sub-pixel-different ROW (job 230's own finding — e.g. the exact
    ///    same dashed underline pattern, one device row apart between renderers); (b) ordinary
    ///    glyph-edge antialiasing differs by <=1px scattered along BOTH axes across a dense text
    ///    line (job 231's own finding — visually indistinguishable, confirmed by row-by-row
    ///    pixel dump). In a mostly-blank 12pt cell, either sub-case's presence/absence swings the
    ///    cell's measured density by tens of percentage points even though nothing is actually
    ///    wrong. `blurRadiusDevicePx` (see `inkDensity` below) exists to absorb exactly this
    ///    class — calibrated (empirically, against WORDSTAR.WS) to radius 2, which took
    ///    WORDSTAR.WS's known-all-noise 21 rows to 0/0.
    /// 2. **Glyph-shape substitution noise** (job 229, LJ6DTP.WS's `contentDiffers` floor): when
    ///    a face is absent on this machine and both the app and the engine substitute to the
    ///    same base-14 font, the TWO RASTERIZERS' ink for that substituted glyph is still never
    ///    bit-exact (hinting/AA differ) — a real, un-closeable `contentDiffers` floor on any
    ///    page using a substituted face. No parameter here suppresses this; it is a property of
    ///    comparing two independent rasterizers, not a calibration bug.
    /// Neither class is swallowed unconditionally: `blurRadiusDevicePx` softens SUB-PIXEL
    /// (fringe-scale) disagreement only, so genuine multi-pixel content gaps still cross
    /// `tolerance`. Job 231's own positive-control proof, at this exact calibration: reverting
    /// `DocumentRenderer`/`PagedDocumentView` to their pre-227 state (job 227's parent commit,
    /// `e1b4be0a`) re-surfaces LJ6DTP.WS's missing 72pt banner as a 22-row finding set (the
    /// banner region alone: `missingInActual` actualInk=0.000 referenceInk=0.711 over a
    /// 312x60pt area — job 227's own commit measured 0.000->0.730 vs ref 0.714 for the same
    /// banner); reverting to their pre-228 state (job 228's parent, job 227's merge commit
    /// `3c7a0d2e`) re-surfaces the running-head vertical-drift regression as 12/21/24 rows on
    /// WORDSTAR.WS/OLDTIMES.WS/YOURWAY.WS respectively, isolated to p2+ exactly as job 228's own
    /// report described. Both regenerated defects are unambiguously flagged at this calibration
    /// — see this job's report for the full transcript before assuming a real defect could be
    /// hiding behind this floor, and before changing `blurRadiusDevicePx`'s default without
    /// re-running this same proof.
    public static func compareFixture(
        fixture: String,
        actual: [PageImage],
        reference: [PageImage],
        outputDirectory: URL,
        gridCellPt: CGFloat = 12,
        tolerance: Double = 0.12,
        inkThreshold: Double = 0.02,
        sampleStride: Int = 4,
        blurRadiusDevicePx: Int = 2,
        background: NSColor = .white,
        attach: Bool = true
    ) throws -> FixtureReport {
        guard actual.count == reference.count else {
            throw PixelOracleError.pageCountMismatch(actual: actual.count, reference: reference.count)
        }
        var pageReports: [PageReport] = []
        for (a, r) in zip(actual, reference) {
            let report = try comparePage(
                fixture: fixture, actual: a, reference: r, outputDirectory: outputDirectory,
                gridCellPt: gridCellPt, tolerance: tolerance, inkThreshold: inkThreshold,
                sampleStride: sampleStride, blurRadiusDevicePx: blurRadiusDevicePx,
                background: background, attach: attach)
            pageReports.append(report)
        }
        return FixtureReport(fixture: fixture, pages: pageReports)
    }

    // MARK: - Per-page comparison

    private static func comparePage(
        fixture: String, actual: PageImage, reference: PageImage, outputDirectory: URL,
        gridCellPt: CGFloat, tolerance: Double, inkThreshold: Double, sampleStride: Int,
        blurRadiusDevicePx: Int, background: NSColor, attach: Bool
    ) throws -> PageReport {
        guard actual.pointSize.width > 0, actual.pointSize.height > 0 else {
            throw PixelOracleError.emptyBitmap("\(fixture)/\(actual.label) (actual)")
        }
        guard reference.pointSize.width > 0, reference.pointSize.height > 0 else {
            throw PixelOracleError.emptyBitmap("\(fixture)/\(reference.label) (reference)")
        }
        // Both sides are measured on a grid sized from ACTUAL's own point geometry — a page
        // whose two sides disagree on paper SIZE is itself exactly the kind of structural
        // finding this harness exists to surface, so it is not silently reconciled; the grid
        // walks actual's points and reference is sampled at the corresponding FRACTIONAL
        // position, which stays meaningful even if the two point sizes differ slightly.
        let cols = max(1, Int((actual.pointSize.width / gridCellPt).rounded(.up)))
        let rows = max(1, Int((actual.pointSize.height / gridCellPt).rounded(.up)))

        var actualGrid = [[Double]](repeating: [Double](repeating: 0, count: cols), count: rows)
        var referenceGrid = [[Double]](repeating: [Double](repeating: 0, count: cols), count: rows)

        for row in 0..<rows {
            for col in 0..<cols {
                let cellPt = CGRect(x: CGFloat(col) * gridCellPt, y: CGFloat(row) * gridCellPt,
                                     width: gridCellPt, height: gridCellPt)
                actualGrid[row][col] = inkDensity(
                    bitmap: actual.bitmap, pageSize: actual.pointSize, cellPt: cellPt,
                    sampleStride: sampleStride, blurRadiusDevicePx: blurRadiusDevicePx,
                    background: background)
                let refCellPt = CGRect(
                    x: cellPt.minX / actual.pointSize.width * reference.pointSize.width,
                    y: cellPt.minY / actual.pointSize.height * reference.pointSize.height,
                    width: cellPt.width / actual.pointSize.width * reference.pointSize.width,
                    height: cellPt.height / actual.pointSize.height * reference.pointSize.height)
                referenceGrid[row][col] = inkDensity(
                    bitmap: reference.bitmap, pageSize: reference.pointSize, cellPt: refCellPt,
                    sampleStride: sampleStride, blurRadiusDevicePx: blurRadiusDevicePx,
                    background: background)
            }
        }

        // Classify every cell, then flood-fill 4-connected same-class cells into regions.
        var classGrid = [[RegionClass?]](repeating: [RegionClass?](repeating: nil, count: cols), count: rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let a = actualGrid[row][col], r = referenceGrid[row][col]
                guard abs(a - r) > tolerance else { continue }
                if a <= inkThreshold, r > inkThreshold {
                    classGrid[row][col] = .missingInActual
                } else if r <= inkThreshold, a > inkThreshold {
                    classGrid[row][col] = .extraInActual
                } else {
                    classGrid[row][col] = .contentDiffers
                }
            }
        }

        var visited = [[Bool]](repeating: [Bool](repeating: false, count: cols), count: rows)
        var findings: [Finding] = []
        for row in 0..<rows {
            for col in 0..<cols {
                guard let cls = classGrid[row][col], !visited[row][col] else { continue }
                var stack = [(row, col)]
                visited[row][col] = true
                var cells: [(Int, Int)] = []
                while let (cr, cc) = stack.popLast() {
                    cells.append((cr, cc))
                    for (dr, dc) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nr = cr + dr, nc = cc + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < cols, !visited[nr][nc],
                              classGrid[nr][nc] == cls else { continue }
                        visited[nr][nc] = true
                        stack.append((nr, nc))
                    }
                }
                let minRow = cells.map(\.0).min()!, maxRow = cells.map(\.0).max()!
                let minCol = cells.map(\.1).min()!, maxCol = cells.map(\.1).max()!
                let regionPt = CGRect(
                    x: CGFloat(minCol) * gridCellPt, y: CGFloat(minRow) * gridCellPt,
                    width: CGFloat(maxCol - minCol + 1) * gridCellPt,
                    height: CGFloat(maxRow - minRow + 1) * gridCellPt)
                let meanActual = cells.map { actualGrid[$0.0][$0.1] }.reduce(0, +) / Double(cells.count)
                let meanReference = cells.map { referenceGrid[$0.0][$0.1] }.reduce(0, +) / Double(cells.count)
                findings.append(Finding(page: actual.label, regionClass: cls, regionPt: regionPt,
                                         actualInk: meanActual, referenceInk: meanReference))
            }
        }
        // Deterministic order: top-to-bottom, left-to-right — matches reading order, and makes
        // the findings table reproducible run to run (flood-fill visitation order alone is not
        // guaranteed stable across grid shapes).
        findings.sort { lhs, rhs in
            if lhs.regionPt.minY != rhs.regionPt.minY { return lhs.regionPt.minY < rhs.regionPt.minY }
            return lhs.regionPt.minX < rhs.regionPt.minX
        }

        let safeFixture = fixture.replacingOccurrences(of: "/", with: "_")
        let safePage = actual.label.replacingOccurrences(of: "/", with: "_")
        let fixtureDir = outputDirectory.appendingPathComponent(safeFixture, isDirectory: true)
        let sideBySideURL = fixtureDir.appendingPathComponent("\(safePage)-side-by-side.png")
        let deltaURL = fixtureDir.appendingPathComponent("\(safePage)-delta.png")

        try writeSideBySide(actual: actual, reference: reference, findings: findings,
                             gridCellPt: gridCellPt, to: sideBySideURL)
        try writeDelta(pageSize: actual.pointSize, classGrid: classGrid,
                        actualGrid: actualGrid, referenceGrid: referenceGrid,
                        gridCellPt: gridCellPt, to: deltaURL)

        if attach {
            attachPNG(at: sideBySideURL, named: "\(safeFixture)-\(safePage)-side-by-side.png")
            attachPNG(at: deltaURL, named: "\(safeFixture)-\(safePage)-delta.png")
        }

        return PageReport(page: actual.label, findings: findings,
                           sideBySideURL: sideBySideURL, deltaURL: deltaURL)
    }

    // MARK: - Ink density (sub-sampled, not exhaustive — see compareFixture's doc comment)

    /// Mean "ink-ness" of sampled points inside `cellPt` (page points) — a `sampleStride x
    /// sampleStride` sub-grid per cell rather than every pixel, the difference between a page
    /// comparison that finishes in a couple of seconds and one that walks millions of `colorAt`
    /// calls per page. Dense enough to reliably detect anything structural (a banner, a
    /// knockout bar, a multi-line block of leaked control text all span many cells at full
    /// coverage); sparse enough to run the full `TestDocs/ws7` corpus in one test.
    ///
    /// Each sample point is itself a small 2D box average, `blurRadiusDevicePx` device pixels
    /// in every direction around the point (job 231 calibration — see `compareFixture`'s "noise
    /// floor" doc section). Two confirmed sub-mechanisms, both from job 231's own positive-
    /// control work re-diagnosing WORDSTAR.WS's rows (job 230's evidence fixture) pixel-by-
    /// pixel: (1) job 230's own finding — AppKit's `cacheDisplay` and PDFKit's `PDFPage
    /// .thumbnail` land a whole thin feature's (an underline) ink on a sub-pixel-different
    /// (<=1 device row) ROW for honestly-identical geometry; (2) job 231's own finding —
    /// ordinary glyph-edge antialiasing differs by <=1 device px scattered along BOTH axes at
    /// glyph boundaries across a dense text line (visually indistinguishable, verified by direct
    /// row-by-row pixel dump: WORDSTAR.WS p5's residual region shows near-identical glyph shapes
    /// with only 1px edge noise, not a real divergence). A single exact-point sample flips
    /// between "ink"/"no ink" depending on which rasterizer's fringe pixel it lands on for
    /// either mechanism; averaging a small 2D window turns that flip into a small CONTINUOUS
    /// change instead of a discrete one — while a genuine content difference (missing banner,
    /// several points of vertical shift, a wrong glyph) still spans pixels well beyond the
    /// window and still drives the averaged density past `tolerance`. Radius 2 (a 5x5-px
    /// window) is this job's calibrated default, chosen empirically against WORDSTAR.WS (21
    /// rows -> 7 at radius 2; radius 3-4 plateaued at 6, confirming the remaining rows are a
    /// stable, non-vertical-blur-reducible residual worth reporting individually rather than
    /// chasing to zero) — the positive-control proof (this job's report) is what justifies
    /// trusting radius 2 rather than assuming it; a caller suspecting a wider fringe on some
    /// future rasterizer pairing should re-run that proof before changing this default.
    private static func inkDensity(bitmap: NSBitmapImageRep, pageSize: CGSize, cellPt: CGRect,
                                    sampleStride: Int, blurRadiusDevicePx: Int,
                                    background: NSColor) -> Double {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        guard width > 0, height > 0, pageSize.width > 0, pageSize.height > 0 else { return 0 }
        guard let bg = background.usingColorSpace(.deviceRGB) else { return 0 }
        let bgR = bg.redComponent, bgG = bg.greenComponent, bgB = bg.blueComponent

        func inkAt(px: Int, py: Int) -> Double {
            guard let c = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return 0 }
            let devR = abs(c.redComponent - bgR), devG = abs(c.greenComponent - bgG)
            let devB = abs(c.blueComponent - bgB)
            return max(devR, devG, devB) > 0.06 ? 1 : 0
        }

        let scaleX = CGFloat(width) / pageSize.width
        let scaleY = CGFloat(height) / pageSize.height

        var hits = 0.0
        var total = 0
        for sy in 0..<sampleStride {
            let fy = (CGFloat(sy) + 0.5) / CGFloat(sampleStride)
            let pt = cellPt.minY + fy * cellPt.height
            guard pt >= 0, pt < pageSize.height else { continue }
            let py = min(height - 1, max(0, Int(pt * scaleY)))
            for sx in 0..<sampleStride {
                let fx = (CGFloat(sx) + 0.5) / CGFloat(sampleStride)
                let ptx = cellPt.minX + fx * cellPt.width
                guard ptx >= 0, ptx < pageSize.width else { continue }
                let px = min(width - 1, max(0, Int(ptx * scaleX)))
                total += 1
                var windowSum = 0.0
                var windowCount = 0
                let rowsBelow = min(blurRadiusDevicePx, py)
                let rowsAbove = min(blurRadiusDevicePx, height - 1 - py)
                let colsLeft = min(blurRadiusDevicePx, px)
                let colsRight = min(blurRadiusDevicePx, width - 1 - px)
                for dy in -rowsBelow...rowsAbove {
                    for dx in -colsLeft...colsRight {
                        windowSum += inkAt(px: px + dx, py: py + dy)
                        windowCount += 1
                    }
                }
                hits += windowCount > 0 ? windowSum / Double(windowCount) : 0
            }
        }
        guard total > 0 else { return 0 }
        return hits / Double(total)
    }

    // MARK: - Artifacts

    private static func writeSideBySide(actual: PageImage, reference: PageImage,
                                         findings: [Finding], gridCellPt: CGFloat,
                                         to url: URL) throws {
        let gap: CGFloat = 8
        let totalWidth = actual.bitmap.pixelsWide + reference.bitmap.pixelsWide + Int(gap)
        let totalHeight = max(actual.bitmap.pixelsHigh, reference.bitmap.pixelsHigh)
        guard let composite = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: totalWidth, pixelsHigh: totalHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw PixelOracleError.cannotEncodePNG("\(actual.label) side-by-side") }
        composite.size = NSSize(width: totalWidth, height: totalHeight)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: composite) else {
            throw PixelOracleError.cannotEncodePNG("\(actual.label) side-by-side")
        }
        NSGraphicsContext.current = ctx
        NSColor.lightGray.setFill()
        NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight).fill()
        NSImage(cgImage: actual.bitmap.cgImage!, size: NSSize(width: actual.bitmap.pixelsWide, height: actual.bitmap.pixelsHigh))
            .draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSImage(cgImage: reference.bitmap.cgImage!, size: NSSize(width: reference.bitmap.pixelsWide, height: reference.bitmap.pixelsHigh))
            .draw(at: NSPoint(x: actual.bitmap.pixelsWide + Int(gap), y: 0), from: .zero, operation: .sourceOver, fraction: 1)
        // Outline every finding's region on BOTH halves — same page-point rect, converted into
        // each half's own pixel scale, so a reader can eyeball exactly what the table's row N
        // is pointing at without cross-referencing coordinates by hand.
        NSColor.red.setStroke()
        for finding in findings {
            for (bitmap, xOffset) in [(actual.bitmap, 0), (reference.bitmap, actual.bitmap.pixelsWide + Int(gap))] {
                let scaleX = CGFloat(bitmap.pixelsWide) / actual.pointSize.width
                let scaleY = CGFloat(bitmap.pixelsHigh) / actual.pointSize.height
                let rect = NSRect(
                    x: CGFloat(xOffset) + finding.regionPt.minX * scaleX,
                    y: CGFloat(bitmap.pixelsHigh) - (finding.regionPt.minY + finding.regionPt.height) * scaleY,
                    width: finding.regionPt.width * scaleX, height: finding.regionPt.height * scaleY)
                NSBezierPath(rect: rect).stroke()
            }
        }
        ctx.flushGraphics()

        guard let data = composite.representation(using: .png, properties: [:]) else {
            throw PixelOracleError.cannotEncodePNG("\(actual.label) side-by-side")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func writeDelta(pageSize: CGSize, classGrid: [[RegionClass?]],
                                    actualGrid: [[Double]], referenceGrid: [[Double]],
                                    gridCellPt: CGFloat, to url: URL) throws {
        let rows = classGrid.count
        let cols = rows > 0 ? classGrid[0].count : 0
        let width = max(1, Int(pageSize.width))
        let height = max(1, Int(pageSize.height))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { throw PixelOracleError.cannotEncodePNG("delta") }
        bitmap.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PixelOracleError.cannotEncodePNG("delta")
        }
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for row in 0..<rows {
            for col in 0..<cols {
                guard let cls = classGrid[row][col] else { continue }
                let delta = abs(actualGrid[row][col] - referenceGrid[row][col])
                let alpha = CGFloat(min(1.0, max(0.25, delta / 0.5)))
                switch cls {
                case .missingInActual: NSColor.red.withAlphaComponent(alpha).setFill()
                case .extraInActual: NSColor.blue.withAlphaComponent(alpha).setFill()
                case .contentDiffers: NSColor.orange.withAlphaComponent(alpha).setFill()
                }
                // Flipped: row 0 is the page TOP (this file's own point convention), while the
                // bitmap's fill origin is bottom-left.
                let rect = NSRect(x: CGFloat(col) * gridCellPt,
                                   y: CGFloat(height) - (CGFloat(row) + 1) * gridCellPt,
                                   width: gridCellPt, height: gridCellPt)
                rect.fill()
            }
        }
        ctx.flushGraphics()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PixelOracleError.cannotEncodePNG("delta")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Lands the PNG in the test's own result bundle (Apple's own attachment machinery, per
    /// this job's generalization mandate) IN ADDITION to the PNG directory on disk — the two
    /// are complementary, not redundant: the result bundle travels with `xcrun xcresulttool`
    /// inspection and CI artifact collection, the on-disk copy is what a human (or the next
    /// job) can open directly at a known path without extracting an xcresult bundle first.
    private static func attachPNG(at url: URL, named name: String) {
        guard let data = try? Data(contentsOf: url) else { return }
        Attachment.record(data, named: name)
    }
}
