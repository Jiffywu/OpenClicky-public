# Test fixtures

`Drawing/` contains the reviewed inputs needed by the drawing regression tests and `scripts/render-drawing-evidence.sh`:

- Small drawing programs for 2D, 3D, layout and voice-follow-up checks.
- A blank canvas and an image of the project's bridge test page, with its synthetic element frames. The page has an empty password field and no signed-in account.

These inputs were moved out of the private evidence archive so tests work in a fresh clone. They contain no provider credentials, diagnostic bundles, recorded audio or saved user conversations. Review new fixtures before committing them. Use synthetic content and keep live account data out of tests.

Generated images and logs belong in ignored `.build/evidence/` or `docs/evidence/`. `OPENCLICKY_WRITE_EVIDENCE=1` writes figure renders under `.build/evidence/figures/`.
