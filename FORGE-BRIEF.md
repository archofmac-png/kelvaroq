# FORGE BRIEF — SCARLETT runtime

Read this before any task. It is the shared context for every agent on this repo.

## What this is

A reimplementation of an Xbox Series (Scarlett / GDK) platform layer, in Rust, that runs a
retail title's own x86-64 PE inside our process on Windows and presents it through D3D12.

The title is **referred to only as "the title"** with build tag `1.0.2.1`, entry point
`game_scarlett_master.exe`. Do **not** name the game, the publisher, or discuss where the files
came from, licensing, takedowns, or piracy. Outside knowledge of the game is not required and
usually misleads. Work from the code and the numbers below.

Codename for this work: **SCARLETT**. Repo: this one.

## Hard ground truth (measured, not guessed)

| Fact | Value |
|---|---|
| Title's own code with nothing drawn | **locked 30 fps**, 5,331 heavy frames, p99 33.9 ms |
| Same scene drawn through the layer | **~130 ms/frame** (~7.5 fps) |
| GPU busy time at 130 ms/frame | **~30 %** — the GPU is idle most of the frame |
| Share of the frame spent keeping two memory copies in sync | **~two thirds** |
| Work left after translate-once descriptors | **~60 ms/frame**, target **5 ms** |
| Draws dropped for missing host pipelines | **~7 %** |
| Clamped indirect calls per frame | **~1,400** |
| Shader programs / translated | 24,387 / all but <300 |
| Host pipelines in pack | ~27,000 |

**The engine is not slow. The translation between two memory models is slow.** Every public
attempt before this one iterated on the copy loop; a loop that should not exist cannot be tuned
away. Our job is to delete it and to fill the pipeline/RT holes.

## Architecture of record

- `native/patches/` — a numbered patch series on top of pinned `victory-fork`. Read before editing.
- `native/kelvaroq-render/` — our rendering crate: residency, descriptors, submission.
- `src/` — launcher/CLI, measurement, packaging.
- `research/` — reference interpreter (Unicorn). GPL-2.0. Slow; for correctness only.

## Non-negotiables

1. **Never regress correctness for speed silently.** Every perf patch must keep the same
   rendered output; capture before/after with `--capture` and diff.
2. **No game data in the tree.** Ever.
3. **Unit tests must pass without game data.** `cargo test` is the gate.
4. **One concern per patch**, numbered, with the numbers in the commit body.
5. Use `rg`, not `grep`. PowerShell on this host.

## Where the win is

In priority order:

1. **Unified memory residency** — hand the GPU the title's memory instead of copying it.
   Table constants and read-only views must resolve in place. Copy <=8 MB/frame is the target
   already proven in the first scenes; the open world is the hard case.
2. **Submission thread** — the prepare/submit thread is the measured limiter. It must not be on
   the title's critical path, and heavy frames must not serialize behind it.
3. **Descriptor translation once, at write time** — never re-sort per submission.
4. **Pipeline holes** — the ~7 % dropped draws and ~1,400 clamped indirects. Precompile from the
   shader pack at install time; nothing should be translated during play.
5. **Wave64 on 32-lane lanes** — ~21,545 programs carry wave64 ops that must be approximated.

## Reporting

- Answer with **what changed, why, and the measured delta**. No prose padding.
- If a hypothesis fails, say so in one line and move on. Failed hypotheses are useful.
- Cite file:line for every claim about current behaviour.
