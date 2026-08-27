# Bundled sample documents

Four public-domain WordStar files, bundled into `sr` itself (`--samples DIR` writes them
out) so anyone can try the converter without hunting down a `.WS` file first — the same
role these four play in the Soft Return app's own Help ▸ Open Sample Document menu.

| File | What it is |
| --- | --- |
| `LYING.WS` | Mark Twain, "On the Decay of the Art of Lying" (1882) — WS7, carries a real WordStar footnote |
| `OCAPTAIN.WS` | Walt Whitman, "O Captain! My Captain!" (1865) — WS4 |
| `TWAINLET.WS` | a short Twain letter — WS4 |
| `WARPRAYR.WS` | "The War Prayer," Mark Twain (written 1905, published 1916) — WS7 |

This directory is the canonical source: `soft-return-app`'s own
`SoftReturn/Resources/SampleDocuments/` is a byte-for-byte copy of these same four files
(see that repo's own README for the app-side menu wiring and job history). Update both
together if a sample ever changes; don't let them drift.

Public domain: Twain died in 1910 and Whitman in 1892, well past any copyright term: these
are texts, not scans, so no separate edition-copyright applies. All four were hand-authored
in WordStar (not machine-converted) per Jon's 2026-08-19 content-bar ruling.
