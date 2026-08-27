import AppKit
import CtrlKD

/// What the bottom bar reports and lets you change.
@MainActor
protocol BottomBarDelegate: AnyObject {
    func bottomBarDidChooseVariant(_ variant: Variant?)      // nil == Auto
    func bottomBarDidChooseStyle(_ style: ViewStyle)
    func bottomBarDidChooseZoom(_ zoom: ZoomSetting)
    func bottomBarDidChoosePageSize(_ size: NamedPageSize)
    /// `nil` == "Embedded", the app's default page geometry — unchanged. Quick Look's own
    /// margins default is set from Settings now (job 315), not from this popup.
    func bottomBarDidChoosePageSettings(_ preset: DocumentOperations.PageSettingsPreset?)
}

/// The document window's bottom bar: five value-only controls, no labels.
///
/// Each one REPORTS a resolved setting and, clicked, changes it — so the bar is both the
/// status line and the control surface, which is why none of them carries a label. The BAR
/// itself shows the bare value only — "WS4", "Printed", "Fit", "Letter" — never the
/// "(Manual)"/"(Detected)"/"(Default)" provenance suffix (Jon's round 4a ruling: the
/// suffix cluttered a 24pt bar four controls wide). Provenance still reaches the popup
/// MENU beneath each control — the state badge next to the current item, per below — and
/// VoiceOver, whose accessibility label spells the provenance out in words regardless of
/// what the button displays.
///
/// The badge sits AFTER the item's name, not before (round 4a): a leading badge read as
/// part of the word to VoiceOver and to the eye scanning left to right; trailing, it reads
/// as what it is — a status mark on a value already named. Job 341 (b23, round-3-ui ruling):
/// the badge is a FILLED disc for every selected item now, coloured the same as the item's
/// own text for a detected/default value, accent-coloured for a manually-set one — the
/// earlier filled-vs-hollow shape distinction is gone (colour is still doubled up by the
/// badge's accessibility description, "Set manually" vs "Detected", for VoiceOver). Every
/// item in every popup, selected or not, renders at the SAME font size — none of them fall
/// back to AppKit's own default item styling anymore, so a look at the menu can never show
/// one item bigger than its neighbours.
final class BottomBar: NSView {
    weak var delegate: BottomBarDelegate?

    static let barHeight: CGFloat = 24

    private let variantButton = BottomBar.makeButton(identifier: "variant-control")
    private let styleButton = BottomBar.makeButton(identifier: "style-control")
    private let zoomButton = BottomBar.makeButton(identifier: "zoom-control")
    private let pageButton = BottomBar.makeButton(identifier: "page-size-control")
    private let pageSettingsButton = BottomBar.makeButton(identifier: "page-settings-control")
    /// Job 450 (b6) introduced this as a Single-Page-mode-only, multi-page-only affordance.
    /// Job 454: Jon ruled that coming-and-going behaviour confusing — "Always on." It is now
    /// shown in every style and display mode, including a one-page document ("Page 1 of 1" is
    /// the correct, intended reading there, not furniture). A plain label, not a popup: unlike
    /// the five controls above there is nothing to CHOOSE here, only a fact to report, so it
    /// carries no menu and no target/action.
    private let pageIndicatorLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = itemTextColor
        label.setAccessibilityIdentifier("page-indicator")
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document status")
        setAccessibilityIdentifier("document-bottom-bar")

        let stack = NSStackView(views: [variantButton, styleButton, zoomButton, pageButton, pageSettingsButton, pageIndicatorLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // A11Y AUDIT FIX (parent/child mismatch, finding 2 of 2): a pure layout container
        // with no role of its own, sitting between this view's `.group` and the four
        // popups' own roles. Explicitly out of the accessibility tree rather than relying
        // on NSStackView's usual default, so the four controls parent directly to the bar
        // that names them ("Document status") and there is exactly one group between the
        // window and a control, not two.
        stack.setAccessibilityElement(false)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])

        // Target/action lives HERE, on the button, and ONLY here. Round 3's real bug: the
        // items built in buildXMenu() used to carry this SAME target/action too. AppKit
        // does not layer those — a menu item with its own target/action is dispatched
        // exactly like an ordinary NSMenuItem, direct to that target, with the ITEM as
        // sender, bypassing the popup's own action entirely. So every real click sent an
        // NSMenuItem into a handler declared to take an NSPopUpButton — a mismatch the
        // Objective-C message send does not check, and objects vend to Swift as whatever
        // static type the call site expects. That is why selecting an item did nothing a
        // person could see (or worse): variantChosen(_:) never ran with the sender it
        // expected. `NSApp.sendAction(_:to:from:)`, which the old test drove directly, is
        // NOT what a real click sends — it let the test pass the BUTTON as `from:` by
        // hand, which no real menu tracking ever does, and that is exactly how the break
        // hid behind a green suite. With items carrying no target/action of their own
        // (see buildXMenu below), AppKit's default behaviour applies: choosing ANY item
        // sends the BUTTON's action, sender = the button, `selectedItem` already updated —
        // which is what every handler below actually assumes.
        variantButton.target = self;       variantButton.action = #selector(variantChosen(_:))
        styleButton.target = self;         styleButton.action = #selector(styleChosen(_:))
        zoomButton.target = self;          zoomButton.action = #selector(zoomChosen(_:))
        pageButton.target = self;          pageButton.action = #selector(pageChosen(_:))
        pageSettingsButton.target = self;  pageSettingsButton.action = #selector(pageSettingsChosen(_:))

        // Fixed widths, sized to each control's own widest possible item — never to
        // whatever happens to be selected. Without this a popup's width tracks its
        // SELECTED title, so it grows and shrinks as the user cycles values ("content
        // hugging" — Jon's baseline finding). The candidate lists below are exhaustive
        // over each control's own domain, so this is a hard ceiling: nothing that domain
        // can ever display is wider than what was measured here.
        NSLayoutConstraint.activate([
            variantButton.widthAnchor.constraint(equalToConstant: Self.variantControlWidth),
            styleButton.widthAnchor.constraint(equalToConstant: Self.styleControlWidth),
            zoomButton.widthAnchor.constraint(equalToConstant: Self.zoomControlWidth),
            pageButton.widthAnchor.constraint(equalToConstant: Self.pageControlWidth),
            pageSettingsButton.widthAnchor.constraint(equalToConstant: Self.pageSettingsControlWidth),
        ])
    }

    // MARK: - Fixed widths

    /// The parenthesized provenance suffix is part of the displayed text on every control
    /// (see the type's doc comment), so it has to be part of what "widest possible item"
    /// measures — a control showing "(Detected)" for the first time must not grow past a
    /// width sized only from bare value names.
    private static let provenanceSuffixes: [String] = [
        SettingProvenance.detected.suffix,
        SettingProvenance.manual.suffix,
        SettingProvenance.default.suffix,
    ]

    /// Every string `buildVariantMenu` could ever hand to `apply(menu:title:to:label:)` as
    /// the button's own title, PLUS every string it could add as a dropdown item (the "Auto
    /// (<detected>)" item's own title is never the button's displayed text, but it is
    /// still an item in the menu, and the ruling says "widest possible item").
    private static let variantCandidates: [String] = {
        let names = [Variant.ws4, .ws5plus, .printstream, .text].map { variantName($0) }
        var out: [String] = []
        for name in names {
            out += provenanceSuffixes.map { name + $0 }
            out.append("Auto (\(name))")
        }
        return out
    }()

    private static let styleCandidates: [String] = ViewStyle.allCases.flatMap { style in
        provenanceSuffixes.map { style.displayName + $0 }
    }

    private static let zoomCandidates: [String] = {
        let names = ["Fit", "Actual"] + ZoomSetting.steps.map { "\($0)%" }
        return names.flatMap { name in provenanceSuffixes.map { name + $0 } }
    }()

    /// Includes "Custom" — a document whose geometry matches no named size (see
    /// `buildPageMenu`) shows that instead of a size name, and it must not be wider than
    /// what the control was sized for.
    private static let pageCandidates: [String] = {
        let names = NamedPageSize.allCases.map(\.shortName) + ["Custom"]
        return names.flatMap { name in provenanceSuffixes.map { name + $0 } }
    }()

    private static let pageSettingsCandidates: [String] = {
        DocumentOperations.PageSettingsPreset.marginsChoiceNames
            .flatMap { name in provenanceSuffixes.map { name + $0 } }
    }()

    /// Jon's round 3 ruling: the popups were too wide at their full computed max-item width,
    /// so each control is fixed at 75% of that figure — still a hard ceiling derived from
    /// the same exhaustive candidate lists, just scaled down. Still fixed, still never
    /// resizing on selection: only the constant each button is pinned to has changed.
    private static let widthFraction: CGFloat = 0.75

    /// Job 454, Part C. Jon, live on b27: "the bar is getting too wide now for the beginning
    /// width of the window on my laptop... the bottom bar buttons all need to lose a few
    /// pixels in width. 5? I don't know how wide they are... Same amount lost on each."
    ///
    /// Measured (`ZZProbeJob454ButtonWidths.swift`, run against `fixedWidth`'s own real output,
    /// against every bare title a button can ever actually show — never the provenance suffix,
    /// which only ever appears inside the dropdown, per this type's own doc comment): the
    /// TIGHTEST control is `variant-control` at 48.4pt of slack (widest bare title
    /// "Printstream", 60.6pt, against a 109pt button) — not `page-settings-control`
    /// ("Embedded", 56.2pt against 106pt, 49.8pt of slack) as Jon guessed from what he sees
    /// day to day; the two are close, but variant edges it out by about a point. Every other
    /// control carries even more (`style-control` 53.7pt, `zoom-control` 55.0pt,
    /// `page-size-control` 53.6pt). 5pt comes out of a 48.4pt floor, leaving >43pt of real
    /// padding on the tightest button — nowhere near the title, so Jon's own guessed number is
    /// exactly right and there is no case for shading it down further.
    /// `Job454ButtonWidthTests.noReachableTitleClipsItsButton` is the permanent guard: it fails
    /// the day any future title (a new variant, a new preset, a longer localization) eats into
    /// that padding.
    private static let buttonWidthReduction: CGFloat = 5

    private static let variantControlWidth = fixedWidth(candidates: variantCandidates) - buttonWidthReduction
    private static let styleControlWidth = fixedWidth(candidates: styleCandidates) - buttonWidthReduction
    private static let zoomControlWidth = fixedWidth(candidates: zoomCandidates) - buttonWidthReduction
    private static let pageControlWidth = fixedWidth(candidates: pageCandidates) - buttonWidthReduction
    private static let pageSettingsControlWidth = fixedWidth(candidates: pageSettingsCandidates) - buttonWidthReduction

    /// 75% of the widest intrinsic content size AppKit itself computes across `candidates`,
    /// for a scratch button configured exactly like the real ones. Asking AppKit rather than
    /// measuring text by hand is what makes the underlying figure exact for the popup's own
    /// font, control size, and dropdown-arrow chrome — all of which a hand-rolled
    /// `NSAttributedString` measurement would have to reproduce separately and could drift
    /// from.
    private static func fixedWidth(candidates: [String]) -> CGFloat {
        let probe = makeButton(identifier: "width-probe")
        var widest: CGFloat = 0
        for title in candidates {
            probe.removeAllItems()
            probe.addItem(withTitle: title)
            widest = max(widest, probe.intrinsicContentSize.width)
        }
        return (widest * widthFraction).rounded(.up)
    }

    /// Belt and braces with the `bounds.fill()` in `draw(_:)`: since macOS 14 a view's
    /// drawing is not clipped to its own rectangle unless it says so, and a bar that paints
    /// outside itself is what made the document window look blank for three sessions.
    override var clipsToBounds: Bool {
        get { true }
        set { _ = newValue }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // `bounds`, NOT `dirtyRect`. Since macOS 14 `NSView.clipsToBounds` defaults to
        // FALSE, so drawing is no longer confined to the view's own rectangle — and
        // `dirtyRect` during a full-window redraw is the whole content area. This 24pt bar
        // was therefore painting its background over the ENTIRE window, and because it is
        // added to the content view AFTER the scroll view, it painted last and won.
        //
        // That is the blank document window. Three sessions looked for a page that was not
        // drawing; the page drew correctly every time and was covered by this fill a moment
        // later. Every measurement said the view tree was healthy because it WAS healthy.
        NSColor.softReturnTitlebar.setFill()
        bounds.fill()
        // A hairline above the bar, the standard separator weight.
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        _ = dirtyRect
    }

    // MARK: - Populating

    func update(from state: DocumentState) {
        buildVariantMenu(state)
        buildStyleMenu(state)
        buildZoomMenu(state)
        buildPageMenu(state)
        buildPageSettingsMenu(state)
    }

    /// Job 450 (b6): `currentPage`/`pageTotal` live on `DocumentWindowController`, not
    /// `DocumentState` (job 439's own doc comment notes `pageTotal`/`currentPage` only ever
    /// fed menu-item enablement and the "Go to Page" dialog before this) — so this takes them
    /// as plain values rather than folding into `update(from:)`.
    ///
    /// Job 454: no conditional visibility of any kind — Jon's ruling was "it can't be coming
    /// and going... always on." There is no `visible` parameter and no `pageTotal` threshold;
    /// the label is unconditionally shown and set on every call, including "Page 1 of 1" for a
    /// one-page document.
    func updatePageIndicator(currentPage: Int, pageTotal: Int) {
        let text = "Page \(currentPage + 1) of \(pageTotal)"
        pageIndicatorLabel.stringValue = text
        pageIndicatorLabel.setAccessibilityLabel(text)
        pageIndicatorLabel.isHidden = false
    }

    /// Job 315 (b19 item 8): every popup's dropdown opens on a header row naming the
    /// control — Jon's ruling: "make sure the bottom bar menu header labels stand out,
    /// separate them with a line, make sure they can't be selected." Job 341 (b23,
    /// round-3-ui ruling) tried a BOLD `attributedTitle` in the same colour every other
    /// item's text uses, applied on top of `NSMenuItem.sectionHeader(title:)` (macOS 14+)
    /// with a hand-rolled `isEnabled = false` item as the pre-14 fallback — attribute
    /// checks on `attributedTitle` passed, but the RENDERED bar still showed gray headers
    /// in the field (job 359, b24 field report on b23). The lesson job 341's own tests
    /// missed: `attributedTitle` is what you ASK a menu item to draw, not proof of what it
    /// actually draws — an item can override it at paint time and an attribute-only test
    /// cannot see that.
    ///
    /// Job 359 (b24) measured both hypotheses directly (`Scripts/
    /// _job359_header_render_probe.swift`) instead of assuming either: (1)
    /// `.sectionHeader(title:)`'s own row style is a real, separate risk — Apple's header
    /// only documents it as "non-interactive," never that it defers to `attributedTitle`
    /// for colour. (2) The pre-14 fallback carried an INDEPENDENT gray risk of its own,
    /// confirmed on this runtime: a plain `isEnabled = false` item's `attributedTitle`
    /// foreground colour is measurably washed out by AppKit's standard disabled-item
    /// dimming (`NSButtonCell.h`: "the image and text ... are normally dimmed with gray")
    /// — toggling ONLY `isEnabled` on an otherwise-identical item moved the rendered ink
    /// from labelColor luminance to roughly halfway to white, with `attributedTitle`'s
    /// explicit colour making no difference. So "the pre-14 fallback renders identically"
    /// (job 342's claim) was never actually true either — nothing had run it, on any OS.
    ///
    /// Fix: a `.view`-based item, on every OS version this app supports (floor is 13.0;
    /// `view` has shipped since 10.5) — no `.sectionHeader`/`isSectionHeader` anywhere. Per
    /// `NSMenuItem.h`, a menu item with a view "does not draw its title, state, font, or
    /// other standard drawing attributes, and assigns drawing responsibility ENTIRELY to
    /// the view" — that is the one AppKit contract that hands rendering to code this app
    /// controls, immune to both risks above by construction rather than by hoping AppKit's
    /// internal styling stays out of the way. `isEnabled = false` stays alongside it: inert
    /// for a view-item's own mouse handling (the view owns hit-testing), but still what
    /// keeps the header out of `NSMenu`'s keyboard type-select matching, and it is the
    /// property `isHeaderRow` (see `BottomBarHeaderTests.swift`) still keys off.
    private static func addHeader(_ title: String, to menu: NSMenu) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.view = headerView(title: title)
        menu.addItem(header)
        menu.addItem(.separator())
    }

    /// The header row's own drawing, in full — see `addHeader`'s doc comment for why a
    /// view, not `attributedTitle`, is the only mechanism this job proved immune to both
    /// `.sectionHeader`'s styling and AppKit's disabled-item dimming. No Auto Layout: the
    /// view is never inserted into a constraint-managed hierarchy (menu tracking sizes menu
    /// items from the view's plain `frame`, per `NSMenuItem.h`), so it is measured and laid
    /// out by hand instead, the same way `fixedWidth(candidates:)` above already measures
    /// AppKit's own intrinsic sizing rather than guessing at it.
    private static let headerHorizontalInset: CGFloat = 14
    private static let headerVerticalInset: CGFloat = 3

    private static func headerView(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)
        label.textColor = itemTextColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: headerHorizontalInset, y: headerVerticalInset)

        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: label.frame.width + headerHorizontalInset * 2,
            height: label.frame.height + headerVerticalInset * 2))
        container.addSubview(label)
        return container
    }

    private func buildVariantMenu(_ state: DocumentState) {
        let current = state.variant
        let menu = NSMenu()
        Self.addHeader("Variant", to: menu)

        for variant in [Variant.ws4, .ws5plus, .printstream, .text] {
            // NO per-item target/action — see the note on `apply(menu:title:to:label:)`
            // below for why. This item's role is purely to carry a title, badge, and
            // `representedObject` for the popup's OWN action to read back.
            let item = NSMenuItem(title: Self.variantName(variant), action: nil, keyEquivalent: "")
            item.representedObject = variant
            let isCurrent = variant == current.value
            Self.applyStateBadge(to: item,
                selected: isCurrent,
                manual: isCurrent && current.provenance == .manual
            )
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // "Auto" is the way back to the detector's own answer — and it names what that
        // answer was, so choosing it is not a leap of faith.
        let auto = NSMenuItem(title: "Auto (\(Self.variantName(state.detection.variant)))",
                              action: nil, keyEquivalent: "")
        auto.representedObject = nil as Variant?
        Self.applyStateBadge(to: auto,
            selected: current.provenance == .detected,
            manual: false
        )
        menu.addItem(auto)

        apply(menu: menu, title: Self.variantName(current.value), to: variantButton,
              label: "File format: " + Self.variantName(current.value) + current.provenance.spokenSuffix)
    }

    private func buildStyleMenu(_ state: DocumentState) {
        let current = state.style
        let menu = NSMenu()
        Self.addHeader("Style", to: menu)
        for style in ViewStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: nil, keyEquivalent: "")
            item.representedObject = style
            let isCurrent = style == current.value
            Self.applyStateBadge(to: item, selected: isCurrent,
                                 manual: isCurrent && current.provenance == .manual)
            menu.addItem(item)
        }
        apply(menu: menu, title: current.value.displayName,
              to: styleButton,
              label: "Rendering style: " + current.value.displayName + current.provenance.spokenSuffix)
    }

    private func buildZoomMenu(_ state: DocumentState) {
        let current = state.zoom
        let menu = NSMenu()
        Self.addHeader("Zoom", to: menu)
        for named: (String, ZoomSetting) in [("Fit", .fit), ("Actual", .actual)] {
            let item = NSMenuItem(title: named.0, action: nil, keyEquivalent: "")
            item.representedObject = named.1
            let isCurrent = named.1 == current.value
            Self.applyStateBadge(to: item, selected: isCurrent,
                                 manual: isCurrent && current.provenance == .manual)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for percent in ZoomSetting.steps {
            let setting = ZoomSetting.percent(percent)
            let item = NSMenuItem(title: "\(percent)%", action: nil, keyEquivalent: "")
            item.representedObject = setting
            let isCurrent = setting == current.value
            Self.applyStateBadge(to: item, selected: isCurrent,
                                 manual: isCurrent && current.provenance == .manual)
            menu.addItem(item)
        }
        apply(menu: menu, title: current.value.displayName,
              to: zoomButton,
              label: "Zoom: " + current.value.displayName + current.provenance.spokenSuffix)
    }

    private func buildPageMenu(_ state: DocumentState) {
        let current = state.pageSize
        // A document whose geometry matches no named size keeps its real geometry and says
        // so, rather than being forced under a label that would be a lie.
        let valueText = current.value?.shortName ?? "Custom"
        let menu = NSMenu()
        Self.addHeader("Page Size", to: menu)
        for size in NamedPageSize.allCases {
            let item = NSMenuItem(title: size.displayName, action: nil, keyEquivalent: "")
            item.representedObject = size
            let isCurrent = size == current.value
            Self.applyStateBadge(to: item, selected: isCurrent,
                                 manual: isCurrent && current.provenance == .manual)
            menu.addItem(item)
        }
        apply(menu: menu, title: valueText, to: pageButton,
              label: "Page size: " + valueText + current.provenance.spokenSuffix)
    }

    /// Job 203: "Embedded" (job 315: was "From Document" — today's unchanged default,
    /// `nil`), then the CLI's own named `--page-settings` presets
    /// (`DocumentOperations.PageSettingsPreset.allCases` — the exact registry
    /// `ConvertCommand`'s `PageSettingsScripting.resolve` and `sr --page-settings` both
    /// resolve against). Job 315 (b19 item 10): the trailing "Use as Default for Quick
    /// Look" action item is gone — that function moved to Settings' own "Quick Look
    /// Margins" pulldown, which writes `QuickLookPageSettingsPreference` directly rather
    /// than through this popup.
    private func buildPageSettingsMenu(_ state: DocumentState) {
        let current = state.pageSettingsPreset
        let menu = NSMenu()
        Self.addHeader("Margins", to: menu)

        let embedded = NSMenuItem(title: DocumentOperations.PageSettingsPreset.embeddedChoiceName,
                                  action: nil, keyEquivalent: "")
        embedded.representedObject = nil as DocumentOperations.PageSettingsPreset?
        let isEmbedded = current.value == nil
        Self.applyStateBadge(to: embedded, selected: isEmbedded,
                             manual: isEmbedded && current.provenance == .manual)
        menu.addItem(embedded)

        for preset in DocumentOperations.PageSettingsPreset.allCases {
            let item = NSMenuItem(title: preset.displayName, action: nil, keyEquivalent: "")
            item.representedObject = preset as DocumentOperations.PageSettingsPreset?
            let isCurrent = current.value == preset
            Self.applyStateBadge(to: item, selected: isCurrent,
                                 manual: isCurrent && current.provenance == .manual)
            menu.addItem(item)
        }

        let valueText = current.value.map(\.displayName) ?? DocumentOperations.PageSettingsPreset.embeddedChoiceName
        apply(menu: menu, title: valueText, to: pageSettingsButton,
              label: "Margins: " + valueText + current.provenance.spokenSuffix)
    }

    private func apply(menu: NSMenu, title: String, to button: NSPopUpButton, label: String) {
        button.menu = menu
        // A pop-up shows its SELECTED item's title, and selecting a real item would also
        // pick up that item's badge (trailing circle) — the bar shows the bare value alone.
        // So the button carries its own plain, badge-free title item at index 0 and never
        // selects a real one.
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.insertItem(titleItem, at: 0)
        titleItem.isHidden = true
        button.select(titleItem)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    // MARK: - Item styling and the state badge (trailing the item's name)

    /// The single colour every popup-menu item's text — and, for a detected/default
    /// selection, its badge — renders in. `.labelColor` rather than AppKit's own default
    /// item-text colour so the badge can share the exact same literal source of truth
    /// (job 341, round-3-ui ruling: "same colour as the menu item text").
    private static let itemTextColor = NSColor.labelColor

    /// A filled disc, accent-coloured for a manually-set value, `itemTextColor`-coloured for
    /// a detected/default one, nothing at all for an unselected item. Job 341 (round-3-ui
    /// ruling) dropped the earlier filled-vs-hollow shape distinction — every selected item
    /// now gets the SAME filled shape, colour alone (plus the badge's own accessibility
    /// description, "Set manually" vs "Detected") carrying the distinction. Deliberately NOT
    /// a checkmark: a checkmark can only say "this one", and the bar has to say "this one,
    /// and whether a human chose it".
    private static func stateBadge(selected: Bool, manual: Bool) -> NSImage? {
        guard selected else { return nil }
        let description = manual ? "Set manually" : "Detected"
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: description)
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [manual ? .controlAccentColor : itemTextColor]))
        return image?.withSymbolConfiguration(config)
    }

    /// Style `item`'s title AND, if selected, append its badge AFTER the name (round 4a: was
    /// `item.image`, which AppKit always draws leading a menu item's title — the ruling
    /// asked for the reverse). Job 341 (round-3-ui ruling): EVERY item goes through this,
    /// selected or not — before, an unselected item kept its bare `.title` and relied on
    /// AppKit's own default item styling, which happened to render at the same nominal size
    /// as a badged item's explicit font but was never guaranteed or testable; now every item
    /// in every popup carries the exact same explicit font and colour, so none of them can
    /// ever render bigger than its neighbours.
    private static func applyStateBadge(to item: NSMenuItem, selected: Bool, manual: Bool) {
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(
            string: item.title, attributes: [.font: font, .foregroundColor: itemTextColor])
        if let image = stateBadge(selected: selected, manual: manual) {
            let attachment = NSTextAttachment()
            attachment.image = image
            // Centre the small disc on the text's cap height rather than its baseline, so it
            // sits mid-letter instead of hanging off the bottom of the line.
            attachment.bounds = CGRect(
                x: 0, y: (font.capHeight - image.size.height) / 2,
                width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            text.append(NSAttributedString(attachment: attachment))
        }
        item.attributedTitle = text
    }

    private static func makeButton(identifier: String) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.controlSize = .small
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private static func variantName(_ variant: Variant) -> String {
        switch variant {
        case .ws4:         return "WS4"
        case .ws5plus:     return "WS5+"
        case .printstream: return "Printstream"
        case .text:        return "Text"
        case .binary:      return "Binary"
        }
    }

    // MARK: - Actions

    @objc private func variantChosen(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, !item.isHidden else { return }
        delegate?.bottomBarDidChooseVariant(item.representedObject as? Variant)
    }

    @objc private func styleChosen(_ sender: NSPopUpButton) {
        guard let style = sender.selectedItem?.representedObject as? ViewStyle else { return }
        delegate?.bottomBarDidChooseStyle(style)
    }

    @objc private func zoomChosen(_ sender: NSPopUpButton) {
        guard let zoom = sender.selectedItem?.representedObject as? ZoomSetting else { return }
        delegate?.bottomBarDidChooseZoom(zoom)
    }

    @objc private func pageChosen(_ sender: NSPopUpButton) {
        guard let size = sender.selectedItem?.representedObject as? NamedPageSize else { return }
        delegate?.bottomBarDidChoosePageSize(size)
    }

    @objc private func pageSettingsChosen(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, !item.isHidden else { return }
        delegate?.bottomBarDidChoosePageSettings(item.representedObject as? DocumentOperations.PageSettingsPreset)
    }
}
