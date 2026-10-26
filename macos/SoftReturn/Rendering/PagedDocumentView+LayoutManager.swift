import AppKit
import CtrlKD
import SoftReturnRendering
import SoftReturnShared

/// Job 412 (Jon's ruling on job 408's decision brief, option (a) — "pin it"): overrides
/// AppKit's own proposed line-fragment position with the engine's own grid, for every
/// fragment `RenderedDocument.pinnedBaselines` covers — see that field's own doc comment
/// for the full job 411 root-cause mechanism this replaces (a per-content-class baseline
/// offset AppKit itself computes correctly WITHIN a fragment, but never corrects for
/// ACROSS a content-class transition, since it stacks fragment tops from the fragment
/// before rather than from any shared external grid).
///
/// Workaround, kept (reviewed 2026-10-26, macOS 26.7): TextKit 1 has no public baseline grid; the engine's page positions
/// are the truth the parity tests hold Native to. Kept while the pages are laid out by TextKit 1.
extension PagedDocumentView: NSLayoutManagerDelegate {
    /// Fires once per real line fragment as the typesetter lays it out — possibly more than
    /// once for the SAME fragment within one `setContent` call (`buildExplicitPages`'s own
    /// probe-container pass, then again once laid into the real per-page containers), and
    /// in whatever order AppKit chooses to (re)lay text out. A CHARACTER-OFFSET lookup
    /// (`pinnedBaselines`'s own key, not fragment call order) is what stays correct
    /// regardless — document position is the one thing that never changes.
    ///
    /// Moves the fragment's POSITION (`lineFragmentRect`/`lineFragmentUsedRect`'s own
    /// `origin.y`, shifted together by the same delta so they stay aligned) AND overwrites
    /// `baselineOffset` itself — job 412's original design left `baselineOffset` untouched,
    /// trusting AppKit's own LIVE per-fragment report to place the baseline correctly within
    /// the repositioned fragment; job 413 replaces that live report with
    /// `RenderedDocument.pinnedBaselines`'s own `PinnedBaseline.k`, a value computed once,
    /// off-screen, in `DocumentRenderer` (see that field's own doc comment for the two job
    /// 412/413 defects a live per-pass report caused: a superscript run inside the line
    /// perturbing it, and windowed-vs-windowless AppKit disagreeing on it by a hair) — so the
    /// out-param has to be overwritten to match, or the glyphs AppKit actually draws would
    /// land somewhere `delta` below never assumed. Both rects' HEIGHT stays completely
    /// untouched: `buildExplicitPages`'s container-height measurement reads these same rects
    /// and stays correct (a page's own content still costs exactly the sum of its own
    /// fragments' pinned-height paragraph styles, unrelated to where the group as a whole
    /// sits) — only WHERE the fragment sits, and where its own baseline sits within it,
    /// change; how TALL it is does not.
    ///
    /// Returns `false` (AppKit's own proposal stands, unmodified) for any fragment this
    /// document's own `pinnedBaselines` doesn't cover at all — Modern style and the Show
    /// Invisibles screen path both hand back an EMPTY dictionary (see
    /// `RenderedDocument.pinnedBaselines`'s own doc comment), so this delegate is a
    /// complete no-op for both BY CONSTRUCTION (the empty-dictionary guard below), not by
    /// any style check in this method.
    /// `nonisolated`, bridged back to the main actor via `MainActor.assumeIsolated` — the
    /// SAME "known safe, Swift can't prove it across an old un-annotated ObjC delegate
    /// protocol" shape `DocumentRenderer.invisibleMarkColour`'s own `nonisolated(unsafe)`
    /// doc comment already establishes for this codebase (there is no real data race: this
    /// app is single-window/single-document per `layoutManager`, and `NSLayoutManager` only
    /// ever calls its delegate synchronously from whatever thread owns it, always the main
    /// thread here — `allowsNonContiguousLayout` is off and nothing in this app touches a
    /// `layoutManager`/`storage` off-main). `NSLayoutManagerDelegate` itself carries no
    /// actor annotation (a pre-concurrency ObjC protocol), so a plain (non-`nonisolated`)
    /// implementation on an otherwise MainActor-inferred `NSView` subclass compiles fine
    /// under this target's own default actor isolation but not under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (`SoftReturnQuickLook`/
    /// `SoftReturnThumbnail`, which also compile this same file — job 247/`Quick
    /// LookNativeRenderer`'s own "every viewing surface, same pipeline" doc comment) —
    /// `nonisolated` here is what makes the ONE implementation correct for every target
    /// that links it, rather than diverging behavior (or a build failure) by target.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                    shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                                    baselineOffset: UnsafeMutablePointer<CGFloat>,
                                    in textContainer: NSTextContainer,
                                    forGlyphRange glyphRange: NSRange) -> Bool {
        // Only PLAIN, `Sendable` data (a `Dictionary`/`CGFloat`/`Bool`, all value types)
        // crosses back OUT of the actor-isolated closure below — the non-`Sendable` AppKit
        // pointer parameters this method itself owns (`lineFragmentRect` et al.) are
        // read/written entirely out here, in this `nonisolated` scope, never captured INTO
        // the closure. Capturing them there is what produced the "sending risks causing
        // data races" diagnostic this shape avoids: `MainActor.assumeIsolated`'s own
        // closure crossing an isolation boundary is fine for VALUES: it is not fine for
        // pointers the region checker cannot prove stay only on one side of that boundary.
        // `ObjectIdentifier` (a `Sendable` value type wrapping a pointer), not `textContainer`
        // itself, is what crosses into the closure below — the same "only plain values, never
        // the AppKit object itself" discipline this method's own top doc comment already
        // establishes for the pointer parameters; capturing `textContainer` (a class instance,
        // not provably confined) directly produced the identical "sending risks causing data
        // races" diagnostic those pointers did.
        let textContainerID = ObjectIdentifier(textContainer)
        let pinned: (baselines: [Int: PinnedBaseline], perPageTextTop: [Double],
                     fallbackTextTop: Double, containerPageIndex: Int?,
                     containerColumnIndex: Int?)? = MainActor.assumeIsolated {
            // Job 412: the probe is ONE container spanning the WHOLE document — `entry.y`
            // resets to `firstBaseline` at the start of EVERY page (see `RenderedDocument
            // .pinnedBaselines`'s own doc comment), so pinning it here would make page 2's
            // own first fragment jump BACKWARD and overlap page 1's real content in this
            // one shared coordinate space, corrupting the typesetter's own incremental
            // layout for everything after (confirmed empirically — a spurious/misassigned
            // fragment crossed a page boundary when this guard was absent; a later attempt
            // to pin the probe too, using a monotonic per-page Y band instead, ALSO
            // regressed several previously-clean fixtures by consistently one line per
            // page boundary, root cause not fully isolated before the simpler unpinned
            // probe + `RenderedDocument.pinnedPageBottoms` combination — below — proved
            // reliable across the full fixture set). This is why the probe stays UNPINNED:
            // its own measurement is only a FALLBACK/floor now, not authoritative — a
            // pinned page's real height comes from `pinnedPageBottoms` instead.
            guard !isMeasuringProbeContainer,
                  let rendered, !rendered.pinnedBaselines.isEmpty else { return nil }
            // Item 19: which PAGE and which of its COLUMNS this container is, not just an
            // index into a per-page list — the two together name the container a fragment
            // belongs in, now that a page can have more than one.
            let index = containers.firstIndex(where: { ObjectIdentifier($0) == textContainerID })
            return (rendered.pinnedBaselines, rendered.perPageTextTop,
                    Double(rendered.textFrame.origin.y),
                    index.flatMap { containerPage.indices.contains($0) ? containerPage[$0] : nil },
                    index.flatMap { containerColumn.indices.contains($0) ? containerColumn[$0] : nil })
        }
        guard let pinned, let containerPageIndex = pinned.containerPageIndex,
              let containerColumnIndex = pinned.containerColumnIndex else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // A fragment whose OWN intended page (`entry.page`, from `DocumentRenderer`'s own
        // per-line page assignment) doesn't match the REAL container it's being asked to
        // lay into is AppKit trying to OVERFLOW this page's excess content into the next
        // container — exactly the signal a pinned Y would otherwise HIDE: pinning always
        // proposes a small, in-bounds-looking position (a new page's own first line pins
        // near `firstBaseline`, i.e. near container-local Y 0), so AppKit never sees the
        // "this doesn't fit" natural overflow it needs to actually break to a new
        // container — confirmed empirically (job 412): without this guard, one real
        // container on `LJ6DTP.WS` silently swallowed two entire pages' worth of fragments
        // (88 instead of the expected 44), each new page's content pinning right back to
        // the container's own top instead of overflowing out of it. Returning `false` here
        // lets AppKit's own UNPINNED proposal stand for this one fragment, restoring the
        // natural "doesn't fit, break here" signal — the pin resumes on the NEXT container,
        // where this same fragment's `entry.page` finally matches.
        guard let entry = pinned.baselines[charRange.location],
              entry.page == containerPageIndex, entry.column == containerColumnIndex
        else { return false }
        // `k`: this fragment's own DETERMINISTIC baseline-from-fragment-TOP offset —
        // `PinnedBaseline.k` (job 413; see its own doc comment), not the delegate's own
        // `baselineOffset` out-param job 412 originally read here. Same "distance down from
        // the fragment's own top" quantity every OTHER geometry computation in this file
        // calls `K` (`DocumentRenderer.firstBaselineOffset`'s own `location(forGlyphAt: 0)
        // .y`) — using it directly, with no inversion, is what makes this fragment's own
        // real `location(forGlyphAt:)` (read by every caller downstream, including
        // `Oracle.structuralBodyLines`) land the baseline exactly at `targetY` below, once
        // `baselineOffset.pointee` is overwritten to match (below) so AppKit's own real
        // drawing baseline is THIS `k`, not whatever it would have proposed live.
        let k = CGFloat(entry.k)
        // Job 427: THIS page's own container-to-paper anchor
        // (`pinned.perPageTextTop[containerPageIndex]`, `DocumentRenderer.renderNative`'s
        // per-page `pageFirstBaseline - normalBaselineOffset`), not a single shared one —
        // converting `entry.y` (absolute, measured from THIS PAGE's own paper top, reset
        // every page, and itself now built from this SAME page's own `.mt`/`.mb` when it
        // declares one) into this container's own LOCAL coordinate system, where `layout()`
        // above places container-local Y = 0 at exactly that same page's own text top
        // (`view.frame.origin.y` is `textTop(atPage:)` plus a page-level constant, never a
        // function of fragment content). Falls back to `pinned.fallbackTextTop` for a page
        // index the array somehow doesn't cover — defensive only, `renderNative` always
        // sizes `perPageTextTop` to `pages.count`, the same count `containers` has here.
        let pageTextTop = pinned.perPageTextTop.indices.contains(containerPageIndex)
            ? pinned.perPageTextTop[containerPageIndex] : pinned.fallbackTextTop
        let targetY = entry.y - pageTextTop
        let delta = CGFloat(targetY) - k - lineFragmentRect.pointee.origin.y
        lineFragmentRect.pointee.origin.y += delta
        lineFragmentUsedRect.pointee.origin.y += delta
        // AND THE HEIGHT, for the same reason as the origin: this delegate already decides
        // where a fragment sits, and its height is the other half of that. `paragraphStyle`
        // pins `minimumLineHeight == maximumLineHeight == lead` and AppKit does not always
        // honour it — a run set in a face whose natural line height exceeds the lead comes
        // back taller. Measured: WINGDING.CHT reads clamp[14.00, 14.00] and gets a 14.34pt
        // fragment; PRINTER.PS gets 17.00. See `PinnedBaseline.height` for why no font fix
        // applies (the faces are the app's own correct choices, one homogeneous run each)
        // and how 0.34pt a line accumulates into a page losing its last line.
        //
        // The GLYPHS are untouched: this shrinks the fragment box, not the type. A run that
        // genuinely wants 14.34pt in a 14.00pt line overlaps its neighbour by a third of a
        // point, which a facsimile can carry; the container does not clip to fragment rects,
        // so no ink is cut (asserted by `theScreenMatchesWhatThePDFWouldPrint` and the pixel
        // oracle, which compare drawn output rather than geometry).
        if entry.height > 0 {
            lineFragmentRect.pointee.size.height = CGFloat(entry.height)
            lineFragmentUsedRect.pointee.size.height = min(
                lineFragmentUsedRect.pointee.size.height, CGFloat(entry.height))
        }
        // Overwritten unconditionally, even when `delta == 0`: AppKit's own LIVE proposal
        // for this out-param can still differ from `k` (that live/deterministic gap is
        // exactly what job 413 exists to remove) independent of whether the rect itself
        // needed to move.
        baselineOffset.pointee = k
        return true
    }
}
