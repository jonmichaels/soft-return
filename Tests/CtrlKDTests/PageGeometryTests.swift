@testable import CtrlKD
import Testing

/// `modernMargins` is one rule for two units: Modern PDF's points and Modern RTF's
/// twips must describe the same margin, declared or not, for any value a document can
/// declare.
@Suite("Page geometry")
struct PageGeometryTests {
    private func page(mt: Double, mb: Double, po: Double, declared: Provenance) -> PageGeometry {
        PageGeometry(
            plLines: 66, heightIn: 11, sizeName: "Letter", sizeSource: .default,
            mtLines: mt, mtSource: declared, mbLines: mb, mbSource: declared,
            poCols: po, poSource: declared, hmLines: 2, hmSource: .default,
            fmLines: 2, fmSource: .default, lh48: 8, lhSource: .default,
            ls: 1, lsSource: .default, cw120: 12, cwSource: .default, textLines: 55)
    }

    @Test("Modern margins in points and twips agree")
    func pointsAndTwipsAgree() {
        for value in stride(from: 0.0, through: 40.0, by: 0.5) {
            let geometry = page(mt: value, mb: value, po: value, declared: .file)
            let pts = modernMargins(geometry, unitsPerInch: pointsPerInch)
            let twips = modernMargins(geometry, unitsPerInch: twipsPerInch)
            #expect(abs(pts.top * 20 - twips.top) < 1e-9)
            #expect(abs(pts.bottom * 20 - twips.bottom) < 1e-9)
            #expect(abs(pts.left * 20 - twips.left) < 1e-9)
        }
    }

    @Test("An undeclared field is one inch")
    func undeclaredIsOneInch() {
        let geometry = page(mt: 3, mb: 8, po: 8, declared: .default)
        let pts = modernMargins(geometry, unitsPerInch: pointsPerInch)
        #expect(pts.top == 72 && pts.bottom == 72 && pts.left == 72)
        let none = modernMargins(nil, unitsPerInch: twipsPerInch)
        #expect(none.top == 1440 && none.bottom == 1440 && none.left == 1440)
    }

    @Test("The named presets keep their numbers")
    func presets() {
        #expect(PageSettings.modern.mtLines == 6 && PageSettings.modern.poCols == 10)
        #expect(PageSettings.sawyer.poCols == 7)
        #expect(PageSettings.sawyer.mtLines == 1195.0 / 1440.0 * 6.0)
        #expect(pagePresets["default"] == PageSettings())
    }
}
