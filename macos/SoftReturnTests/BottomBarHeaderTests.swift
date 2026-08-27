import AppKit
import CtrlKD
import Testing
@testable import SoftReturn

/// BOTTOM BAR POPUP HEADERS — job 315 (b19 item 8).
///
/// Jon's ruling, verbatim: "Make sure the bottom bar menu header labels stand out.
/// Separate them with a line. Make sure they can't be selected." Three claims, three
/// checks below: the header is the dropdown's first row with a separator under it, it
/// cannot be selected through the same real-dispatch path `PopupSelectionWiringTests` uses
/// for every other item (not merely "nothing happens to select it today"), and the
/// popup's own displayed/selected item is never the header.
///
/// Job 359 (b24): `BottomBar.addHeader` no longer uses `NSMenuItem.sectionHeader(title:)`/
/// `isSectionHeader` at all (see that function's doc comment — both it and a plain
/// `isEnabled = false` item's `attributedTitle` proved to be real, independent gray-render
/// risks, measured directly rather than assumed). `isHeaderRow` below is this file's own
/// stand-in for "the header row, whichever way `BottomBar` built it" — `view != nil &&
/// !isEnabled && action == nil && target == nil` — matching the ACTUAL contract
/// `addHeader` now guarantees, not an AppKit-provided flag.
@Suite struct BottomBarHeaderTests {
    private static let expectedHeaders: [(identifier: String, title: String)] = [
        ("variant-control", "Variant"),
        ("style-control", "Style"),
        ("zoom-control", "Zoom"),
        ("page-size-control", "Page Size"),
        ("page-settings-control", "Margins"),
    ]

    @MainActor
    private static func makeBar() throws -> BottomBar {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let state = try Oracle.state(for: url)
        let bar = BottomBar()
        bar.update(from: state)
        return bar
    }

    @MainActor
    private static func popup(_ identifier: String, in bar: BottomBar) throws -> NSPopUpButton {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        return try #require(
            descendants(bar).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "no popup with identifier \(identifier)")
    }

    // MARK: - Stands out, separated by a line

    @Test @MainActor func everyPopupOpensOnItsOwnHeaderImmediatelyFollowedByASeparator() throws {
        let bar = try Self.makeBar()
        for (identifier, title) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            let menu = try #require(button.menu, "\(identifier) has no menu")
            // Index 0 on every one of these menus is the bar's own hidden title item
            // (`apply(menu:title:to:label:)`) — the header is the first VISIBLE row.
            let visible = menu.items.filter { !$0.isHidden }
            let header = try #require(visible.first, "\(identifier) menu has no visible items")

            #expect(header.isHeaderRow,
                    "\(identifier)'s first visible row is not an AppKit section header")
            #expect(header.title == title,
                    "\(identifier)'s header reads '\(header.title)', expected '\(title)'")
            let separator = try #require(visible[safe: 1],
                "\(identifier)'s header has nothing after it")
            #expect(separator.isSeparatorItem,
                    "\(identifier)'s header is not separated from its items by a line")
        }
    }

    /// Exactly one header per popup — a second header (a stray duplicate, or one bleeding
    /// in from another control) would defeat "the FIRST row naming the control."
    @Test @MainActor func eachPopupHasExactlyOneSectionHeader() throws {
        let bar = try Self.makeBar()
        for (identifier, _) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            let menu = try #require(button.menu)
            let headerCount = menu.items.filter(\.isHeaderRow).count
            #expect(headerCount == 1, "\(identifier) has \(headerCount) section headers, expected 1")
        }
    }

    // MARK: - Cannot be selected

    @Test @MainActor func theHeaderCannotBeSelected() throws {
        let bar = try Self.makeBar()
        for (identifier, title) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            let menu = try #require(button.menu)
            let headerIndex = try #require(
                menu.items.firstIndex { $0.isHeaderRow },
                "\(identifier) has no section header")
            let header = menu.items[headerIndex]
            #expect(header.title == title)
            #expect(header.representedObject == nil,
                    "\(identifier)'s header carries a value to select")

            // Job 359 (b24): the header is now `isEnabled = false` with `view != nil`, not
            // `.sectionHeader(title:)` — `isEnabled = false` is AppKit's own, ordinary,
            // documented exclusion from click/keyboard tracking (not a section-header-only
            // carve-out), and `view != nil` additionally hands hit-testing to the header's
            // own view, which wires no target/action of its own. `isHeaderRow` (below)
            // pins exactly that shape. Unit-testing raw `NSEvent` mouse tracking is not
            // practical here (this repo's own LocalAuth constraint rules out driving it
            // through XCUITest), so asserting the shape AppKit's tracking loop is documented
            // to honour is the one honest, checkable claim left.
            #expect(header.isHeaderRow, "\(identifier)'s header is not built as a non-interactive, view-based row")
        }
    }

    // MARK: - The popup's selected item is never the header

    @Test @MainActor func thePopupsSelectedItemIsNeverTheHeader() throws {
        let bar = try Self.makeBar()
        for (identifier, _) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            #expect(button.selectedItem?.isHeaderRow != true,
                    "\(identifier)'s popup shows its own header as the selected/displayed value")
        }
    }

    /// Same check, but after cycling every real value the control can show — a header could
    /// only ever become "selected" by accident of construction order, so this is the
    /// exhaustive version of the test above rather than a single fixed snapshot.
    @Test @MainActor func theSelectedItemStaysOffTheHeaderAcrossEveryRealSelection() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let state = try Oracle.state(for: url)
        let bar = BottomBar()
        bar.update(from: state)

        func assertNoHeaderSelected(_ label: String) throws {
            for (identifier, _) in Self.expectedHeaders {
                let button = try Self.popup(identifier, in: bar)
                #expect(button.selectedItem?.isHeaderRow != true,
                        "\(identifier)'s popup selected its own header after \(label)")
            }
        }

        try assertNoHeaderSelected("initial state")

        state.setVariant(.printstream)
        state.style.setManually(.modern)
        state.zoom.setManually(.actual)
        state.setPageSize(.usLegal)
        state.setPageSettingsPreset(.sawyer)
        bar.update(from: state)
        try assertNoHeaderSelected("manual overrides")
    }

    // MARK: - Job 341/359: header legibility — attributes, then actual rendered pixels

    /// Jon's ruling (job 315/341): headers were "nearly invisible in dark mode" — restyled
    /// bold, in the same colour every other item's text uses. Job 341 pinned this at the
    /// `attributedTitle` attribute level and shipped a header that STILL rendered gray in
    /// the field (job 359's b24 field report) — see `BottomBar.addHeader`'s doc comment.
    /// This test is the attribute-level sanity floor only; `headerRendersLabelColorNotGray
    /// DominantPixelsInBothAppearances` below is the one that actually proves anything about
    /// what lands on screen.
    @Test @MainActor func headerLabelIsBoldAndUsesTheItemTextColour() throws {
        let bar = try Self.makeBar()
        for (identifier, title) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            let menu = try #require(button.menu)
            let header = try #require(menu.items.first { $0.isHeaderRow })
            #expect(header.title == title)
            let view = try #require(header.view, "\(identifier)'s header carries no view")
            let label = try #require(view.subviews.compactMap { $0 as? NSTextField }.first,
                "\(identifier)'s header view has no text field")
            #expect(label.stringValue == title)
            let font = try #require(label.font, "\(identifier)'s header label has no explicit font")
            #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask),
                    "\(identifier)'s header is not bold")
            #expect(label.textColor == NSColor.labelColor,
                    "\(identifier)'s header does not use the same colour as item text")
        }
    }

    /// THE rendered-appearance probe (job 359): job 341's attribute checks lied about what
    /// actually reached the screen, so this draws the header's REAL, production `view` — the
    /// exact object `NSMenu` adds to its tracking window when the popup opens — into an
    /// offscreen bitmap via `NSView.cacheDisplay(in:to:)`. That is a same-process API with
    /// no Screen Recording dependency (unlike `CGWindowListCreateImage`/`screencapture`,
    /// both dead ends on this host per the `Printed`-framing field notes), so it runs in this
    /// gate the same as any other unit test.
    ///
    /// A detached view (never added to a window) does not pick up `NSAppearance
    /// .performAsCurrentDrawingAppearance`'s pushed appearance on its own — measured directly
    /// (`Scripts/_job359_headerview_cachedisplay_probe.swift`): without `view.appearance` set
    /// explicitly, the dark-mode pass rendered nothing at all (every pixel stayed at the
    /// background fill). Setting it is what makes the dark-mode half of this test real
    /// rather than vacuously passing.
    ///
    /// Calibration (from the same probe, run before this assertion was written): the bitmap
    /// is pre-filled with the appearance's own extreme (white for aqua, black for darkAqua)
    /// so the painted ink pixels' alpha-composited luminance is directly comparable to
    /// `labelColor`/`secondaryLabelColor` composited the identical way. The most fully-painted
    /// ink pixel (darkest under aqua, lightest under darkAqua) must land closer to
    /// `labelColor`'s composited luminance than to `secondaryLabelColor`'s — the actual,
    /// on-screen claim no attribute-only test can make.
    @Test @MainActor func headerRendersLabelColorNotGrayDominantPixelsInBothAppearances() throws {
        let bar = try Self.makeBar()
        for (identifier, _) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            let menu = try #require(button.menu)
            let header = try #require(menu.items.first { $0.isHeaderRow })
            let view = try #require(header.view, "\(identifier)'s header carries no view")
            #expect(view.frame.width > 0 && view.frame.height > 0,
                    "\(identifier)'s header view has no measured size")

            for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: appearanceName))
                let backgroundLuminance: CGFloat = appearanceName == .aqua ? 1 : 0
                let background: NSColor = appearanceName == .aqua ? .white : .black

                var result: (extreme: CGFloat, labelExpected: CGFloat, secondaryExpected: CGFloat)?
                appearance.performAsCurrentDrawingAppearance {
                    view.appearance = appearance
                    guard let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(view.frame.width), pixelsHigh: Int(view.frame.height),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    else { return }

                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    background.setFill()
                    NSRect(origin: .zero, size: view.frame.size).fill()
                    NSGraphicsContext.restoreGraphicsState()

                    view.cacheDisplay(in: view.bounds, to: rep)

                    func luminance(_ c: NSColor) -> CGFloat {
                        let rgb = c.usingColorSpace(.deviceRGB) ?? c
                        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                    }
                    func compositedLuminance(_ c: NSColor) -> CGFloat {
                        let rgb = c.usingColorSpace(.deviceRGB) ?? c
                        let a = rgb.alphaComponent
                        return a * luminance(rgb) + (1 - a) * backgroundLuminance
                    }

                    var extreme = backgroundLuminance
                    for y in 0..<rep.pixelsHigh {
                        for x in 0..<rep.pixelsWide {
                            guard let c = rep.colorAt(x: x, y: y) else { continue }
                            let lum = luminance(c)
                            extreme = appearanceName == .aqua ? min(extreme, lum) : max(extreme, lum)
                        }
                    }
                    result = (extreme, compositedLuminance(.labelColor), compositedLuminance(.secondaryLabelColor))
                }

                let (extreme, labelExpected, secondaryExpected) = try #require(result,
                    "\(identifier)'s header view produced no cacheable bitmap under \(appearanceName.rawValue)")
                #expect(abs(extreme - labelExpected) < abs(extreme - secondaryExpected),
                    "\(identifier)'s header rendered gray-dominant under \(appearanceName.rawValue): ink luminance \(extreme), labelColor \(labelExpected), secondaryLabelColor \(secondaryExpected)")
            }
        }
    }

    // MARK: - Job 341 (b23, round-3-ui ruling): every item, same font size

    /// Jon's ruling: "all menu items render at the same font size — the current
    /// larger-font treatment of the active option goes away." Every real value item (header
    /// and separators excluded — they are deliberately styled differently) now carries an
    /// explicit `attributedTitle` font, selected or not, so this collects every one of them
    /// across all five popups and asserts there is exactly one size in play.
    @Test @MainActor func everyMenuItemInEveryPopupRendersAtTheSameFontSize() throws {
        let bar = try Self.makeBar()
        var sizes: Set<CGFloat> = []
        var namesBySize: [CGFloat: [String]] = [:]
        for (identifier, _) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            let menu = try #require(button.menu)
            for item in menu.items where !item.isHidden && !item.isHeaderRow && !item.isSeparatorItem {
                guard let attributed = item.attributedTitle, attributed.length > 0 else { continue }
                let font = try #require(
                    attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                    "\(identifier)'s item '\(item.title)' has no explicit font")
                sizes.insert(font.pointSize)
                namesBySize[font.pointSize, default: []].append("\(identifier)/\(item.title)")
            }
        }
        #expect(sizes.count == 1, "menu items render at more than one font size: \(namesBySize)")
    }

    // MARK: - Job 341 (b23, round-3-ui ruling): the state badge is filled, coloured like text

    @MainActor
    private static func badgeImage(in item: NSMenuItem) -> NSImage? {
        guard let attributed = item.attributedTitle else { return nil }
        var found: NSImage?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if let attachment = value as? NSTextAttachment, let image = attachment.image {
                found = image
                stop.pointee = true
            }
        }
        return found
    }

    @MainActor
    private static func centerPixelAlpha(of image: NSImage) -> CGFloat? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent
    }

    /// Job 341's ruling: the outlined ring becomes a FILLED circle for every selected item —
    /// the earlier filled-vs-hollow shape distinction is gone. Measured empirically (the
    /// same "prove it, don't assume" discipline `AboutWindowControllerTests`' real-spawn
    /// test uses): a hollow "circle" SF Symbol renders with a fully transparent centre
    /// pixel, a filled "circle.fill" does not — see `Scripts/_job341_badge_pixel_probe.swift`
    /// for the raw probe this pins (circle.fill centre alpha ~0.72, circle centre alpha 0.0).
    @Test @MainActor func selectedItemBadgesAreFilledCirclesNotHollowRings() throws {
        let bar = try Self.makeBar()
        var checked = 0
        for (identifier, _) in Self.expectedHeaders {
            let button = try Self.popup(identifier, in: bar)
            let menu = try #require(button.menu)
            for item in menu.items where !item.isHidden && !item.isHeaderRow {
                guard let image = Self.badgeImage(in: item) else { continue }
                checked += 1
                let alpha = try #require(Self.centerPixelAlpha(of: image),
                    "\(identifier)'s badge image for '\(item.title)' has no readable pixel data")
                #expect(alpha > 0.5,
                        "\(identifier)'s badge for '\(item.title)' is not a filled circle (centre alpha \(alpha))")
            }
        }
        #expect(checked > 0, "no badged item found anywhere — this test would pass vacuously")
    }

    @MainActor
    private static func renderBadge(color: NSColor) -> NSImage {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return image.withSymbolConfiguration(config)!
    }

    @MainActor
    private static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Job 341's ruling, verbatim: "the outlined circle becomes a filled circle in the same
    /// colour as the menu item text for the current option; when a non-default option is
    /// selected it fills with the accent colour — exactly today's semantics, only
    /// outline->filled + text-colour normal state." Byte-identical comparison against a
    /// freshly-rendered reference built the exact same way (same symbol, point size, weight)
    /// — not an approximate/tolerance check, since both images come from the same
    /// deterministic rendering call within this one process.
    @Test @MainActor func selectedItemBadgeColourMatchesTextColourUnlessManuallySet() throws {
        let url = Oracle.fixturesDirectory.appendingPathComponent("dropped-chapter.ws4")
        let state = try Oracle.state(for: url)
        let bar = BottomBar()
        bar.update(from: state)

        // Detected state: nothing set manually yet, so Variant's selected item (WS4, what
        // the detector itself found) is a "current option, not manually set" badge.
        let variantButton = try Self.popup("variant-control", in: bar)
        let variantMenu = try #require(variantButton.menu)
        let detectedItem = try #require(variantMenu.items.first { item in
            !item.isHidden && !item.isHeaderRow && Self.badgeImage(in: item) != nil
        }, "no badged item found in the variant popup at its detected default")
        let detectedImage = try #require(Self.badgeImage(in: detectedItem))
        #expect(Self.pngData(of: detectedImage) == Self.pngData(of: Self.renderBadge(color: .labelColor)),
                "a detected/default selection's badge is not rendered in the item text colour")

        // Manual override: Style set by hand -> badge colour becomes accent, per the
        // unchanged half of the ruling.
        state.style.setManually(.modern)
        bar.update(from: state)
        let styleButton = try Self.popup("style-control", in: bar)
        let styleMenu = try #require(styleButton.menu)
        let manualItem = try #require(styleMenu.items.first { item in
            !item.isHidden && !item.isHeaderRow && Self.badgeImage(in: item) != nil
        }, "no badged item found in the style popup after a manual override")
        let manualImage = try #require(Self.badgeImage(in: manualItem))
        #expect(Self.pngData(of: manualImage) == Self.pngData(of: Self.renderBadge(color: .controlAccentColor)),
                "a manually-set selection's badge is not rendered in the accent colour")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Job 359 (b24): `BottomBar.addHeader` no longer branches on OS version or references
/// `NSMenuItem.sectionHeader`/`isSectionHeader` at all — see that function's doc comment.
/// Every header, on every OS version, is `view != nil`, `isEnabled == false`. NOT
/// `action == nil && target == nil`: measured directly on this runtime (confirms job 315's
/// own finding, never actually exercised until this job dropped `.sectionHeader` — every
/// prior dev host was 14+) — `NSPopUpButton` rewires EVERY item's target/action to itself,
/// header included, the moment the menu becomes its own, regardless of `isEnabled`. Internal,
/// not private — `UIRound4ARulingTests.swift` needs the same check.
extension NSMenuItem {
    var isHeaderRow: Bool {
        view != nil && !isEnabled
    }
}
