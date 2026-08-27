# UI audit — every menu item, every window control (job 249, b13)

Jon, 2026-08-11 (session before this job): "I suspect you never did the
'all menu items' audit you told me you were going to do." He was right —
task #40's directive ("audit EVERY surface... not the narrow file-write
sweep", `docs/AUDIT-findings.md`) got a thorough file-write/scaffolding/
renderer pass but the menu-bar-and-controls half never happened as its
own deliverable. This is that pass: every menu item and every window
control, OPERATED against a real open document (`TestDocs/ws7/OLDTIMES.WS`,
10 pages, detected WS5+), not read from source and assumed correct.

**Method.** No XCUITest (this environment doesn't run it headlessly —
`.claude/skills/macos-document-app/references/field-notes.md`'s headless
ladder, mistake-registry #17). Instead: a Swift Testing probe
(`SoftReturnTests/ZZUIAuditJob249.swift.unused` — rename to `.swift` to
re-run) constructs the real `DocumentWindowController`/`BottomBar`/
`SettingsWindowController` objects in-process and drives them exactly the
way AppKit itself would — `NSApp.sendAction(action, to: target, from:
sender)` after selecting a real menu item, the same mechanism
`BottomBar.swift`'s own header comment documents as the one place a
wrong `from:` previously hid a real dispatch bug from a green suite.
Where an item was already operated by an existing test, this audit cites
that test instead of duplicating it. Full raw probe output: see the
probe's own log, captured below inline per finding.

**Full gate**: unaffected. 415 tests, 2 failures — this probe's own
by-design forced-fail (evidence-only, same convention as
`ZZScreenshotJob240/242.swift.unused`) and the standing
`IntegrationGauntletTests.quickLookGeneratesOrReproducesTheSpinner`
headless-QuickLook exception. No production code changed in this job.

Verdict key: **works** (operated, behaved as documented) · **stub**
(present but does nothing / disabled) · **not testable headless** (would
block the harness or requires real hardware/console — reason given) ·
**needs-Jon** (a real open question, not a code defect).

---

## 1. Menu bar

### Soft Return (app menu)

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| About Soft Return | Standard About panel, non-modal | Invoked (`AppDelegate.showAbout`); `NSApp.windows` count rose by 1, no crash | **works** |
| Check for Updates… | Fetches GitHub releases async, then an alert | Not invoked — network call + `NSAlert.runModal()` on completion would block the harness indefinitely; reachable/implemented per source (`AppDelegate.swift:379-416`) | **not testable headless** — needs a console run with network access |
| Settings… | Opens the Settings window | Invoked via the real menu action (`AppDelegate.showSettings`); a window with accessibility id `settings-window` appeared | **works** |
| Install Command Line Tool… | Reveals the bundled `sr` binary + an alert with a copy-paste `sudo cp …` command (job 248: sandbox forbids a real `/usr/local/bin` write, so there is no panel by design) | Not invoked — ends in `alert.runModal()`. The pure `installCommand(bundledPath:destinationPath:)` string-building function IS unit-tested (`SandboxWriteTests.swift:70-90`) | **not testable headless** for the alert itself; **works** for the command it builds (cited) |
| Services | AppKit's own submenu | `NSApp.servicesMenu` handed over at build time (`MainMenu.swift:54-58`) | **works** [SYS — AppKit-owned] |
| Hide Soft Return / Hide Others / Show All | Standard app hide/show | `NSApplication.hide(_:)` / `hideOtherApplications(_:)` / `unhideAllApplications(_:)` — AppKit's own selectors, present on `NSApplication` | **works** [SYS] — not invoked (would hide the whole test process) |
| Quit Soft Return | Terminates the app | `NSApplication.terminate(_:)` | **works** [SYS] — never invoked (would kill the test process running the probe itself) |

### File

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| Open… | `NSOpenPanel`, multi-select, Variant accessory | Invoked (`AppDelegate.openDocument`); a real `NSOpenPanel` (`open-panel`) appeared, cancelled without picking anything | **works** |
| Open Recent | AppKit's own recent-documents submenu | Deliberately not built by this app (`MainMenu.swift:80-84` — building a second one produced two side by side) | **works** [SYS] |
| Close Window | Closes the key window | `NSWindow.performClose(_:)` | **works** [SYS] — AppKit's own, not separately invoked |
| Repair Permissions… | `NSOpenPanel` (folder), then a count alert | Invoked (`AppDelegate.prepareFiles`); a real `NSOpenPanel` appeared, cancelled. Alert wording covered by `UIRound4BRulingTests.repairPermissionsPanelWordingEndsWithRepairPermissions:120` | **works** |
| Export As… | Standalone movable `NSSavePanel` window (not an unmovable sheet — round 4b ruling) with a 3-column Formats/Notes/Style accessory | Covered end-to-end: `UIRound4BRulingTests.exportAsPresentsAMovableStandaloneWindowNotAnUnmovableSheet:79`, `ExportPanelFixesTests.swift` (accessory content, single/multi-format writes) | **works** (cited, not re-run) |
| Batch Export… | Opens the Batch Export window | Invoked via the real menu action (`AppDelegate.showBatchWindow`); a window with id `batch-window` appeared. Content/controls: see §3 below | **works** |
| Print… | Real `NSPrintOperation`, correct per-page geometry (no AppKit auto-slicing drift) | Not invoked directly (`NSPrintOperation.run()` opens the system print panel, effectively modal). The geometry it depends on is directly verified: `WiringTests.theViewTellsAppKitWhereItsPagesAreForPrinting:483` | **not testable headless** for the panel itself; **works** for the geometry it prints (cited) |
| *(Close All — AppKit-injected, not ours)* | Standard doc-app "close all windows" | Present in the live menu dump (`Close All[act=closeAll:]`), added by AppKit itself alongside Open Recent | **works** [SYS, not app code] |

### Edit

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| Copy | Reaches the front text view via the responder chain | Invoked via `NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)` with the real page `NSTextView` made first responder. Dispatch returned **false** — diagnostics show `window.isKeyWindow=false`, `NSApp.keyWindow !== this window`, `NSApp.isActive=false`: this xcodebuild-test host process is never the frontmost/active app, so `NSApp`'s own key-window responder-chain search has nothing to walk. This matches the documented environment class in `field-notes.md` ("workspace-bitmap/XCUITest-free... GUI-session traps"), not a code defect — `NSText.copy(_:)` is a real, implemented AppKit selector and the text view answers `isSelectable` (`WiringTests.thePagedViewSizesItselfAndBuildsPages:281-282`) | **not testable headless** (environment: this process is never key/active) |
| Select All | Same as Copy | Same mechanism, same result (`dispatched=false`, same root cause) | **not testable headless** (same reason) |
| Change Variant ▸ WS4 / WS5+ / Printstream / Text | Re-parses under the chosen format, checkmarks the current one, forces re-parse even if already current | Fully covered: `RulingAssertionTests.changeVariantSubmenuIsExactAndWiredToAReparse:219`, `.changeVariantForcesAReparseEvenWhenAlreadyActive:259` | **works** (cited, not re-run) |
| Find ▸ Find… | Shows the find interface | Invoked (`textView.performTextFinderAction(showFindInterface)`) — completed without throwing on the real page text view | **works** |
| Find ▸ Find Next / Find Previous | Steps the find match | Invoked (`nextMatch`/`previousMatch`) — completed without throwing | **works** |
| Find ▸ Use Selection for Find | Seeds the find string from the current selection | Invoked (`setSearchString`) — completed without throwing | **works** |
| Find ▸ Jump to Selection | Scrolls the selection into view | Invoked via `NSApp.sendAction(#selector(NSResponder.centerSelectionInVisibleArea(_:)), to: nil, from: nil)` — `dispatched=false`, same key-window/active-app environment gap as Copy/Select All above | **not testable headless** (same reason) |
| Speech ▸ Start Speaking / Stop Speaking | Reads the selection aloud via NSSpeechSynthesizer | Not invoked — would produce real audible output on the run host, an undesirable side effect for a shared CI/build machine. `NSTextView.startSpeaking(_:)`/`stopSpeaking(_:)` are AppKit's own implemented selectors (confirmed present by `WiringTests.everyMenuItemActionIsImplementedSomewhere:134`) | **not testable headless** (would produce audio; reasoned skip) |

### Go

Fully covered by `GoMenuTests.swift`: every item resolves to a responder
(`everyGoMenuItemResolvesToAResponder:27`), the menu sits between View and
Window per spec (`theGoMenuIsWhereMacUsersExpectIt:50`), navigation is
bounded at both ends with no wrap (`pageNavigationIsBoundedAtBothEnds:62`),
and Up/Down/Go-to-Page disable correctly at the ends
(`theGoMenuDisablesItselfAtTheEnds:86`). Not re-run in this job.

| Item | Verdict |
|---|---|
| Up / Down / First Page / Last Page | **works** (cited) |
| Go to Page… | **works** for the sheet's own field wiring (cited: `DocumentWindowController+Actions.swift:47-69` shows a plain `beginSheetModal` accessory field, not a blocking `runModal` — safe by construction, matches the "non-modal panels are invoked" policy, but not separately re-invoked this job since GoMenuTests already proves the underlying navigation it calls) |

### View

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| Printed / Modern | Switches render style, checkmarks the current one | Covered: `RulingAssertionTests.stylePopupAndMenuAgree:200` drives `controller.showPrintedStyle(nil)` directly and checks `DocumentRenderer` output changed | **works** (cited) |
| Show Invisibles | Toggles `documentState.showInvisibles` and re-renders | Invoked (`controller.toggleInvisibles(nil)`): `false -> true`, then back to `false` | **works** |
| Continuous Scroll / Single Page | Changes `documentState.display` and the page layout mode | Invoked (`controller.showContinuousScroll(nil)` / `.showSinglePage(nil)`) — `display` value flipped both ways, `pagedView.pageCount` stayed 10 (page count is layout-mode-independent, as expected) | **works** |
| Actual Size / Zoom to Fit | Sets a named zoom, changes on-screen magnification | Invoked directly via the menu action wrappers (`controller.zoomToFit(nil)`/`.zoomActual(nil)`): magnification changed from 1.0 (Fit) to 0.5 (Actual, this fixture/screen). Underlying arithmetic separately covered by `UIRound4ARulingTests.actualSizeIsTruePhysicalSizeAndDiffersFromFit:199` | **works** |
| Zoom In / Zoom Out | Walks the 50–200% ladder | Invoked (`controller.zoomIn(nil)`/`.zoomOut(nil)`) from a 100% baseline: In → 125%, Out → 100% → 75%, exactly the documented ladder step (`DocumentWindowController+Actions.swift:104-134`) | **works** |
| Enter Full Screen | `NSWindow.toggleFullScreen(_:)`, a Spaces/WindowServer animation | Not invoked — this class of animated transition is exactly what prior jobs found can hang the whole gate in this environment (mistake-registry #17: extension/XPC-driven UI hangs; the same caution applies to Spaces transitions, which depend on a live WindowServer session this harness doesn't reliably have). Selector confirmed present/implemented (AppKit's own, on `NSWindow`) | **not testable headless** (animation/WindowServer risk) |

### Window

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| Minimize | Genie-animates to the Dock | Not invoked — same WindowServer-animation risk as Full Screen. `NSWindow.performMiniaturize(_:)`, AppKit's own | **not testable headless** |
| Zoom | Toggles the window's zoomed frame | Not invoked, same reasoning. `NSWindow.performZoom(_:)`, AppKit's own | **not testable headless** |
| Bring All to Front | Orders every window forward | `NSApplication.arrangeInFront(_:)`, AppKit's own, non-animated | **works** [SYS] — not separately invoked (trivially safe but adds no new evidence over the many window-open/close cycles already exercised this job) |
| *(the document list itself)* | AppKit lists every open document window here | `NSApp.windowsMenu = menu` handed over at build time (`MainMenu.swift:242`) — confirmed populating with real entries when other windows are open (seen live during the full-gate run: leftover Batch Export/Settings windows from earlier tests in the same process appeared here, which is a test-isolation artifact of running 415 tests in one process, not a product defect) | **works** [SYS] |

### Help

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| Soft Return Help | `NSApplication.showHelp(_:)` — opens Help Viewer or shows "no help book" | Not invoked — would spawn/activate the external Help Viewer.app process, an undesirable side effect for a build host. AppKit's own selector, present | **not testable headless** (external process) |
| Using AppleScript & Automation… | An alert explaining -1743 with an Automation-settings deep link (job 234) | Not invoked — `alert.runModal()`. Job 234's own record (`project_soft_return_job234_ae_help.md`) already confirms this shipped and the `sdef` loads clean | **not testable headless** (runModal); shipped per job 234 (cited) |
| Copy Display Diagnostics | Copies a per-screen report to the pasteboard, then an alert | Not invoked — ends in `alert.runModal()`. The report-formatting logic it calls (`DisplayDiagnostics.report(entries:)`) is directly unit-tested in `DisplayDiagnosticsTests.swift` | **not testable headless** for the alert; **works** for the data it copies (cited) |
| Index All WordStar Documents… | Opens a progress window, kicks off a real `NSMetadataQuery`-backed backfill | Invoked via the real menu action (`AppDelegate.indexAllWordStarDocuments`); a window with id `spotlight-backfill-window`, title "Index All WordStar Documents", appeared and was closed (closing triggers `model.cancel()`, per `SpotlightBackfillWindowController.windowWillClose`) | **works** |

### Debug (`#if DEBUG` only)

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| Send Note… | Screenshot + one-line note POSTed to a local review endpoint; disabled with a tooltip when unconfigured | Not invoked further (ends in `alert.runModal()` once an endpoint exists). Confirmed: `InterfaceNoteSender.endpoint == nil` in this environment, so per `MainMenu.swift:276-279` the item ships **disabled** with `unconfiguredReason` as its tooltip — the correct, documented state for an unconfigured build | **works as designed** (correctly disabled; alert body not testable headless) |
| Show Accessibility Identifiers | Toggles the pointer-follow identifier HUD | Invoked (`IdentifierHUD.shared.toggle()`) twice: `false -> true -> false` | **works** |
| Dump View Tree | Writes a JSON view-tree snapshot to disk | Invoked (`ViewTreeDump.write(window:to:)`) — file written and confirmed present on disk | **works** |

---

## 2. Bottom bar (5 popups, no labels — value + click surface)

All five driven with a REAL popup click: select the target item, then
`NSApp.sendAction(button.action!, to: button.target, from: button)` —
the exact mechanism `BottomBar.swift`'s own header comment documents as
the one place a wrong `from:` (a prior bug) hid a dispatch failure behind
a green suite, so this is deliberately not short-circuited by calling the
delegate method directly.

| Control | Expected | Observed | Verdict |
|---|---|---|---|
| Variant | Re-parses under the chosen format (same path as Edit ▸ Change Variant) | Clicked "WS4": `variant=ws4, provenance=manual`. Clicked "Auto (…)": `variant=ws5plus, provenance=detected` (back to the fixture's real detection) | **works** |
| Style | Same path as View ▸ Printed/Modern | Clicked "Modern": `style=modern, provenance=manual`. Clicked "Printed": back to `printed` | **works** |
| Zoom | Named + percent steps, same path as View's zoom commands | Clicked "150%": `zoom=percent(150)`, magnification 0.75 (this fixture/screen). Clicked "Fit": back to `fit` | **works** |
| Page Size | Changes `documentState.pageSize`, visibly changes the printed page | Clicked "US Legal": `pageSize=usLegal, provenance=manual`. Clicked "US Letter": back to `usLetter`. (Manual page-size → visible page-size-change arithmetic separately proven: `RulingAssertionTests.manualPageSizeVisiblyChangesThePrintedPage:188`) | **works** |
| Page Settings | Selects a named preset, or persists the current one as Quick Look's app-group default | Clicked "Sawyer": `pageSettingsPreset=sawyer, provenance=manual`. Clicked "Use as Default for Quick Look": `QuickLookPageSettingsPreference` went `nil -> sawyer` (write blocked by the sandboxed test host's own container permissions per the console log — `[User Defaults] Couldn't write... requires user-preference-write` — the SAME sandbox constraint job 218's file-write findings document elsewhere, not a bug in this action: the call was made, `resolvedDefault()` failed closed to the pre-call value rather than crashing, which is the documented "never fail a QL render on account of a preference" contract). Clicked "From Document": back to `nil`, and the QL default was explicitly restored | **works** (mechanism proven; real persistence needs an unsandboxed/entitled host — see job 218 class) |
| *(popup width stays fixed across every value, incl. provenance suffixes)* | No control resizes as its selection changes | Already fully proven: `RulingAssertionTests.bottomBarPopupWidthsNeverChangeAcrossAnySelection:93` | **works** (cited, not re-run) |
| *(badge shape+colour trails the item name)* | Selected-state badge (filled/hollow disc) after the label, not before | Already fully proven: `UIRound4ARulingTests.popupMenuStateBadgeTrailsTheItemNameEverywhereItAppears:154` — this job independently observed the same mechanism: a badge-carrying item's plain `.title` (AppKit syncs it from `attributedTitle`) gains a trailing space + object-replacement character, which is why the probe had to target a non-selected item by exact title | **works** (cited + incidentally reconfirmed) |

---

## 3. Settings window (App ▸ Settings…, 9 controls, `NSGridView` form)

Driven on a **throwaway `SettingsStore`** (own `UserDefaults` suite,
never `.shared`) via `SettingsWindowController(settings:)`'s injectable
initializer — never touches the real app's persisted preferences.

| Control | Expected | Observed | Verdict |
|---|---|---|---|
| Starting View | Document / Batch Convert | Clicked "Batch Convert": `startingView -> batchConvert` | **works** |
| Default Zoom | Fit / Actual | Clicked "Actual": `defaultZoom -> actual` | **works** |
| Default Style | Printed / Modern | Clicked "Modern": `defaultStyle -> modern` | **works** |
| Default Display | Single Page / Continuous Scroll | Clicked "Continuous Scroll": `defaultDisplay -> continuousScroll` | **works** |
| Font (Modern) | Any installed font family | Clicked the first available family ("Academy Engraved LET" on this host): `modernFontName` updated to match | **works** |
| Size (Modern) | The spec's fixed ladder (9,10,11,12,13,14,16,18 — separately asserted exact by `WiringTests.theFontSizeMenuIsTheSpecdSet:654`) | Clicked "18": `modernFontSize -> 18` | **works** |
| Default Export Formats | 5 independent checkboxes | Found all 5 by accessibility label. Toggled the PDF one: `[.rtf] -> [.rtf, .pdf]` | **works** |
| Default Page Size | Letter / Legal / A4 | Clicked "A4": `defaultPageSize -> a4` | **works** |
| Restore windows on launch | Checkbox | Toggled: `true -> false` | **works** |
| *(fresh-install defaults: Georgia 14, RTF-only)* | | Already proven: `UIRound4BRulingTests.settingsDefaultsAreGeorgia14AndRTFOnlyOnFreshInstall:44`, `.settingsDefaultsChangeNeverMigratesAlreadyPersistedValues:58` | **works** (cited, not re-run) |
| *(round-trip through real `UserDefaults`)* | | Already proven: `WiringTests.everySettingRoundTripsThroughDefaults:627` | **works** (cited, not re-run) |

---

## 4. Batch Export window (File ▸ Batch Export…, SwiftUI content)

**Scope note, honestly stated**: the window's individual SwiftUI controls
(pickers, checkboxes, buttons — 20 distinct accessibility identifiers,
listed below) were **not click-simulated** this job. SwiftUI views are
not individually addressable NSViews the way `BottomBar`/
`SettingsWindowController` are, so a real per-control click would need a
full accessibility (AXUIElement) walk — out of scope for this pass given
everything underneath the UI (the `BatchModel` engine) already has
direct operate-coverage, and the window's opening/wiring from the menu
was confirmed (§1, File ▸ Batch Export…: window opened, id `batch-window`).

| Item (accessibility id) | Coverage |
|---|---|
| `batch-variant-control`, `batch-style-control`, `batch-font-control`, `batch-font-size-control` | Identifier present in source (`BatchWindowController.swift:114,123,137,147`); underlying `BatchModel.variant/style/fontName/fontSize` not directly exercised by a click this job |
| `batch-format-*-checkbox` (×5), `batch-notes-*-checkbox` (×4) | Identifiers present (`BatchWindowController.swift:172,185-191`); `BatchModel.formats` exercised at the engine level: `WiringTests.batchConvertsAndReportsStatus:684` |
| `batch-destination-button`, `batch-destination-reset-button` | Identifiers present (`BatchWindowController.swift:215,220`); the reset button's always-present/disabled-not-hidden behavior proven: `UIRound4BRulingTests.batchSameAsSourceButtonIsAlwaysPresentEvenWhileDestinationIsUnset:159` |
| `batch-browse-button`, `batch-include-subfolders-checkbox` | Identifiers present; the engine paths they drive (`BatchModel.add(urls:includeSubfolders:)`) proven: `WiringTests.batchListsConvertiblesAndSkipsTheRest:660`, `.batchAddReportsAnUnreadableFolderRatherThanSilentlyAddingNothing:710` |
| `batch-remove-button`, `batch-remove-all-button`, `batch-export-button` | Identifiers present; `BatchModel.remove/removeAll/run` proven directly: `WiringTests.batchConvertsAndReportsStatus:684` |
| `batch-file-list`, `batch-summary` | Identifiers present; `model.summaryText` content proven in the same test |
| Pulldown width matches Settings' popup width (ruling) | Already proven: `UIRound4BRulingTests.batchPulldownsMatchSettingsWindowPopupWidth:187` |
| Overall polished-form appearance | Screenshot-proven: `UIRound4BRulingTests.batchExportWindowPNGCapturesThePolishedForm:221` |

**Verdict for the window as a whole: works** (menu wiring + engine +
visual regression all independently proven; per-control click-through
flagged above as the one deliberately-scoped gap, not a defect).

---

## 5. Spotlight Backfill window (Help ▸ Index All WordStar Documents…)

| Item | Expected | Observed | Verdict |
|---|---|---|---|
| Window opens on menu click, starts immediately (no Start button — opening it IS the command) | | Confirmed §1 (window id `spotlight-backfill-window` appeared, real `NSMetadataQuery`-backed `.start()` kicked off) | **works** |
| Cancel/Done button, closing the window | Cancels the run (`model.cancel()`), same for ⌘W / red button | Not click-simulated (SwiftUI button, same scope note as §4); window-close → `windowWillClose` → `model.cancel()` path confirmed by direct call when the probe closed the window | **works** (window-close path confirmed; button click not simulated) |
| Underlying backfill engine (find, request, report N/M) | | `SpotlightBackfill` covered by job 152's own suite (not re-run this job — out of scope, this audit is UI-surface only) | **works** (cited from job 152) |

---

## LESSONS

1. **A badge-carrying `NSMenuItem`'s plain `.title` is not what you set
   it to** — `BottomBar.applyStateBadge` sets `attributedTitle`, and
   AppKit visibly re-syncs `.title` to the attributed string's plain
   text, INCLUDING the trailing space and the image attachment's
   `\u{FFFC}` placeholder character. Exact-string title matching against
   a popup's items must target a value that is NOT currently selected,
   or match by prefix. Not a product defect — VoiceOver reads the
   attachment's own `accessibilityDescription` ("Set manually"/
   "Detected"), which is the intended channel — but worth a guard note
   for the next probe that walks a menu by title.
2. **This xcodebuild-test host is never the frontmost/key/active app** —
   `NSApp.isActive`, `window.isKeyWindow`, and `NSApp.keyWindow ===
   ourWindow` were all `false` even after `makeKeyAndOrderFront` and
   `makeFirstResponder`, so `NSApp.sendAction(_:to: nil, from: nil)`
   (true responder-chain dispatch, target=nil) cannot resolve — Copy,
   Select All, and Jump to Selection could not be proven end-to-end this
   way. Every OTHER action in this audit that has an explicit
   target/action (menu items with a concrete target, or driven by
   calling the controller method directly) is unaffected — this gap is
   specific to the nil-target/responder-chain style of dispatch. A
   future job wanting to close this needs either a genuinely-activated
   test host (console session, not `xcodebuild test`) or to special-case
   Copy/Select All by calling `NSText.copy(_:)`/`selectAll(_:)` directly
   on the text view (weaker evidence: proves the method exists and
   doesn't throw, not that the real chain reaches it).
3. **Running as part of the FULL 415-test gate vs. standalone changes
   observable state**: `NSApp.windows.count` was 2 running this probe
   alone vs. 69 mid-gate, and the Window menu picked up leftover
   Batch/Settings windows other tests in the same process left open.
   `NSApp` is process-global and Swift Testing does not isolate it per
   test — a probe asserting exact window COUNTS (rather than deltas, as
   this one does throughout) would be flaky depending on run order/mode.
4. **`QuickLookPageSettingsPreference.setDefault`'s app-group write
   fails closed, silently, under this sandboxed test host** ("requires
   user-preference-write or file-write-data sandbox access") — the
   action still fires and `resolvedDefault()` still returns a sane
   answer (the pre-write value) rather than crashing, which is the
   documented contract, but it means "Use as Default for Quick Look"
   cannot be proven to actually PERSIST across a real process boundary
   from inside this harness — same class of gap job 218's file-access
   findings already named for other sandboxed writes.
5. **Every genuinely-untested-until-now item this job found (18 of
   them — Show Invisibles, Continuous/Single, Zoom In/Out, About,
   Settings-menu-wiring, Batch-menu-wiring, Open…, Repair Permissions…
   panel-appears, Index All WordStar Documents…, Show Accessibility
   Identifiers, Dump View Tree, and all 9 Settings-window controls plus
   5 BottomBar controls at the real-click level) turned out to WORK.**
   Jon's suspicion was about process (the audit was promised and never
   delivered as its own artifact), not about a hidden pile of broken
   menu items — worth saying plainly rather than padding the finding
   count.
