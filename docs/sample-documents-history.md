# Bundled sample documents — development history

Moved here in batch 43 (v4.3.0 post-publish audit, planning #276). This history used to live in
`macos/SoftReturn/Resources/SampleDocuments/README.md`, which **ships inside the .app** at
`Contents/Resources/SampleDocuments` — so a job-by-job changelog naming private vault folders and
ruling dates was going out to users on every release. That file is now a short user-facing README
describing the four samples; everything below is the development record it carried.

## How the mechanism works

The folder is bundled into the app and read at runtime by `SoftReturn/Support/SampleDocuments.swift`.
Every `.WS`-family file placed there (`.ws`, `.ws0`-`.ws9`, `.wsd`, `.wsm`) shows up automatically as
one item in the Help ▸ Open Sample Document submenu, titled by its own filename — no code change is
needed to add, remove, or refresh a sample. `SampleDocuments.items()` is data-driven off the folder's
own contents, and `SampleDocuments.buildMenuItem()` returns a real submenu.

## Job 374 (b24, SAMPLES IN-APP)

The brief asked for the four files from the private vault `pd-samples/authored/*.WS` to be copied in.
That vault was not reachable from the worker environment job 374 ran in — the same class of wall as
job 266's DOSBox-X/WS7 ground truth and job 279's ctrl-kd clone — so job 374 shipped the folder EMPTY,
as a disclosed gap.

Closed afterwards by a different route: four public-domain `.WS` files (`DARKNESS.WS`, `OCAPTAIN.WS`,
`TWAINLET.WS`, `WARPRAYR.WS`) drawn from public-domain literature rather than the private vault.

## Job 400 (F11, sample bundle refresh)

`DARKNESS.WS` removed per Jon's 2026-08-19 ruling (content bar); its replacement essay was to be
selected separately and authored in WS7 later. `OCAPTAIN.WS` and `TWAINLET.WS` (WS4) and `WARPRAYR.WS`
(WS7) became Jon's own hand-authored versions, replacing the machine-authored ones. Three files shipped
at that point, not four — `SampleDocuments.items()` needed no code change, only the tests and docs that
had hardcoded the count of four or `DARKNESS.WS`'s name.

## Job 407 (F11, sample set to 4: LYING.WS)

`DARKNESS.WS`'s replacement lands: `LYING.WS`, Mark Twain's "On the Decay of the Art of Lying" (1882),
Jon-authored in WS7. Four files ship again (`LYING.WS`, `OCAPTAIN.WS`, `TWAINLET.WS`, `WARPRAYR.WS`),
again with no code change. `LYING.WS` also carries a real WordStar footnote ("Did not take the prize."),
restoring the footnote-feature coverage `DARKNESS.WS` had carried before job 400
(`SampleDocumentsTests.lyingWSBundledFootnoteReachesDocumentInfoAndTheNativePage`).
