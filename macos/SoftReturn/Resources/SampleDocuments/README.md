# Sample Documents (Help ▸ Open Sample Document)

This folder is bundled into the app (`Contents/Resources/SampleDocuments`) and read at
runtime by `SoftReturn/Support/SampleDocuments.swift`. Every `.WS`-family file placed here
(`.ws`, `.ws0`-`.ws9`, `.wsd`, `.wsm`) shows up automatically as one item in the Help ▸ Open
Sample Document ▸ submenu, titled by its own filename — no code change needed to add, remove,
or refresh a sample.

## Job 374 (b24, SAMPLES IN-APP)

The brief for this job asked for the four current files from the private vault
`pd-samples/authored/*.WS` to be copied in here. That vault was not reachable from the
worker environment job 374 ran in (same class of wall as job 266's DOSBox-X/WS7 ground truth
and job 279's ctrl-kd clone — see those jobs' memory/reports), so job 374 itself shipped this
folder EMPTY, as a disclosed gap.

Bundled since: four public-domain `.WS` files (`DARKNESS.WS`, `OCAPTAIN.WS`, `TWAINLET.WS`,
`WARPRAYR.WS`) — a different route than the private vault (public-domain literature) closing
the same gap. `SampleDocuments.items()` now returns these four, sorted by title, and
`SampleDocuments.buildMenuItem()` returns a real submenu, so the Help ▸ Open Sample Document
menu item is present. Swapping in a different set later is still a plain file replacement
here, nothing to update in code.

## Job 400 (F11, sample bundle refresh)

`DARKNESS.WS` removed from this folder per Jon's 2026-08-19 ruling (content bar); its
replacement essay is selected separately and will be authored in WS7 later. `OCAPTAIN.WS`
and `TWAINLET.WS` (WS4) and `WARPRAYR.WS` (WS7) are now Jon's own hand-authored versions,
replacing the machine-authored ones this README previously described. Three files ship
today, not four — `SampleDocuments.items()` needed no code change (still data-driven off
this folder's own contents), only the tests/docs below that had hardcoded the count of four
or DARKNESS.WS's name.

## Job 407 (F11, sample set to 4: LYING.WS)

`DARKNESS.WS`'s replacement essay lands: `LYING.WS`, Mark Twain's "On the Decay of the Art
of Lying" (1882), Jon-authored in WS7. Four files ship again (`LYING.WS`, `OCAPTAIN.WS`,
`TWAINLET.WS`, `WARPRAYR.WS`) — again no code change, `SampleDocuments.items()` picks it up
automatically. `LYING.WS` also carries a real WordStar footnote ("Did not take the prize."),
restoring the footnote-feature coverage `DARKNESS.WS` carried before job 400
(`SampleDocumentsTests.lyingWSBundledFootnoteReachesDocumentInfoAndThePrintedPage`).
