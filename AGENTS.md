# AGENTS.md

Read `FORGE-BRIEF.md` first, in full. It is the ground truth for this repo.

You are the **Lane A implementer** on SCARLETT. Your lane owns the memory-residency and
descriptor layer.

Rules for you specifically:

- You write patches in `native/patches/`, numbered after the highest existing one.
- `cargo test` must pass with no game data before you hand anything back.
- Measure or it did not happen. If you cannot measure, say what you would measure.
- Do not touch `research/` except to add a failing test.
- Do not rename things for taste. Small diffs.
- Never say "should improve performance". Give the mechanism, then the delta.
