# Heavy-scene protocol

One question: did this patch change the time of a heavy frame, on the same scene, with the same
picture? `bench/heavy.ps1` answers it. Same save, same warm cache, same duration, same input,
median and p95 reported, picture checked separately.

## What is measured

- **Frame time** is `frame_us` from the built-in monitor: wall time between two consecutive
  successful DXGI flips. Source: `native/patches/0064-monitor.patch:519-528`, ring layout in
  `native/kelvaroq-render/src/stats_ring.rs`.
- **Heavy frame**: an interval with at least `-HeavyDraws` (3,000) guest draws (`draws` field).
  Intervals across an occluded or failed present are excluded and counted (`frames_failed`).
- **Percentiles** are nearest-rank (the value at rank `ceil(p/100 * n)`), so a reported p95 is a
  frame that happened. No interpolation.
- **Window**: `-Duration` seconds (300) of monitor time from the run's first row.
- **Also reported per heavy frame**: GPU busy share, submit-thread work and waits, relay wait,
  title time, present-call time, pipeline wait, `drawn/draws`, `dropped/draws`, and a table by
  draw-count bucket. Two runs are rarely at the same place in the scene (documentation.md:134-144),
  so the buckets are how a scene-mix change is told from a real one.

The monitor is read through its shared-memory ring (`Local\KelvaroqStats-<pid>`, 512 rows). The
script drains it every 200 ms; a run is **invalid** if any row was overwritten before it was read.

## What the script refuses to do

| Refusal | Exit | Why |
|---|---|---|
| Cache cold | 3 | A cold cache compiles pipelines during play: draws are dropped and frames stretch. |
| Cache copy cold when the master is warm | 3 | The receipt records the library's mtime and `shaders/` creation time; a careless copy invalidates it. |
| An engine process already running | 5 | The run needs the machine to itself. |
| No scripted input and no `-NoInput` | 2 | An unscripted run is not repeatable. |
| Output label already exists | 2 | Results are never overwritten. |
| Too few heavy frames (`-MinHeavyFrames`, 300) | 4 | The input script did not reach the heavy scene. |
| Monitor rows lost, engine exited early, wall-clock limit | 4 | Invalid measurement. Kept on disk, never usable as a baseline. |

**Cold-cache check** (`Test-WarmCache`). All of these must hold, on the master and again on the
fresh copy used for the run:

1. `pipelines/` and `shaders/` exist in the cache.
2. At least `-MinRecipes` files in `pipelines/warm-v1` (the recorded recipes, `0050-standins.patch:410`).
   Needed because the engine's own check answers 0 for a cache with no recipes at all
   (`0059-preload.patch:647-654`, `rows()` returns empty).
3. `pipelines/precompiled-v1.txt` exists (`0059-preload.patch:475`).
4. `engine precompile --cache <dir> --check` prints `precompile-check 0` (`0059-preload.patch:97-108`).

The receipt is keyed on the engine binary hash, the adapter, the driver and the translation
fingerprint (`0059-preload.patch:539-573`). **A cache warmed by another build or another card is
cold for this one**, which is the intended behaviour for an A/B across builds: warm each arm's
cache with its own engine (`-Mode Warm`) before measuring. Limitation: the library file names are
not known from this tree, so the library's presence is covered by the engine check, not by name.

## Inputs, all fixed

| Input | Rule |
|---|---|
| Save | `-DataDir` is a master copy. Each run gets a fresh copy as `VICTORY_DATA_DIR`. Its tree hash is recorded. |
| Cache | `-CacheDir` is a master copy. Each run gets a fresh copy as `VICTORY_CACHE_DIR` (robocopy, timestamps kept). The master is never written during a measurement. |
| Input | `VICTORY_KEYS` from `-Keys` or `-KeysFile`, passed through byte for byte; its SHA-256 is recorded. |
| Environment | Every inherited `VICTORY_*` and `KELVAROQ_*` variable is removed, then only `VICTORY_GAME_DIR`, `VICTORY_CACHE_DIR`, `VICTORY_DATA_DIR`, `VICTORY_STATS_SHM=1`, `VICTORY_KEYS` and `-ExtraEnv` are set. `VICTORY_GPU_TIMING` is therefore absent (documentation.md:58). |
| Engine | `-Engine`, launched directly: `run <image> --console series-x --execute`, as `src/native.rs:73-75`. Its SHA-256 is recorded. |

**`VICTORY_KEYS` syntax is not defined anywhere in this repository.** It is implemented by the
fork's input module, which is not in the tree (the only mention here is an upstream commit title,
`0060-victory-port.patch:2306`). The script does not parse or validate it. Whoever writes a
replay script must take the syntax from the fork at `f85101b` and keep the script file next to the
baseline. Whether replay starts at process start or at the first frame is also unverified, which is
why the window starts at the first monitor row and the heavy-frame minimum catches a script that
did not reach the scene.

## Operator checklist (not enforceable from the script)

- 3840x2160 presentation, Series X profile, frame generation off, `VICTORY_GPU_TIMING` unset.
- Same GPU and driver for both arms; the host facts are written to `meta.json` for the record.
- One title process. No capture tool, no compiler, no other GPU load during the run.
- Do **not** run with `VICTORY_CAPTURE`. A capture forces the synchronous present path and one
  frame slot (`0046-async-present-frame-waits.patch:1090-1094`), which is not the timed
  configuration. Capture in a separate, untimed pass with `bench/capture.ps1` (same save, same
  keys) and verify with `bench/render-verify.ps1`; see **Render gate** below.
- Three runs per variant and at least 600 heavy frames in total (documentation.md:60). A single
  run is a screen, not a verdict. The script warns when per-run medians differ by more than the gate.

## Commands

```powershell
# One-time per engine build and card: build every recorded pipeline in the master cache.
./bench/heavy.ps1 -Mode Warm -Engine $engine -CacheDir $cache

# A measurement, 3 runs, stored as a baseline.
./bench/heavy.ps1 -Engine $engine -Image $image -DataDir $save -CacheDir $cache `
    -KeysFile $keys -Runs 3 -Label base-0064 -SaveBaselineAs base-0064

# The candidate, compared against it. Exit 1 on a regression over 5 % of p50 or p95.
./bench/heavy.ps1 -Engine $engine2 -Image $image -DataDir $save -CacheDir $cache2 `
    -KeysFile $keys -Runs 3 -Label cand-0065 -Baseline bench/baselines/base-0064

# Compare two stored results without launching anything.
./bench/heavy.ps1 -Mode Compare -Baseline bench/baselines/base-0064 -Current bench/out/cand-0065

# Statistics, gate, ring reader and cold-cache refusal on synthetic data. No engine, no game data.
./bench/heavy.ps1 -Mode SelfTest
```

Machine-specific paths go in `bench/heavy.local.psd1` (gitignored), for example
`@{ Engine = '...'; Image = '...'; DataDir = '...'; CacheDir = '...'; KeysFile = '...' }`.

## The gate

Exit 1 when **p50 or p95** of heavy frames is more than `-Threshold` (5 %) above the baseline.
The delta table also prints p99, mean, max, submit work and waits, relay wait, title and present
time, GPU busy, and the bucket table. It prints a **WARNING**, without changing the exit code, when:

- `drawn/draws` fell by more than 1 point: the candidate drew less. A faster time on a changed
  picture is not a speedup; capture and diff before accepting (FORGE-BRIEF rule 1).
- dropped draws rose by more than 1 point of guest draws.
- either side has fewer than 600 heavy frames.
- the heavy-frame mix across draw buckets shifted by more than 15 points, so the pooled gate is
  comparing different parts of the scene.

## Render gate (FORGE-BRIEF non-negotiable 1)

**Policy.** A perf patch lands only if `render-verify.ps1` returns **0 or 1** against the stored
reference. **2 or 3 blocks the merge regardless of the frame time**, and so does 4 (no verdict:
the sets were not comparable) or 5 (the gate could not run). A faster frame on a changed picture
is not a speedup (`heavy.ps1` prints the same warning when `drawn/draws` falls). The frame-time
gate and the render gate are independent and both must pass; neither can buy back the other.

| Exit | Meaning | Merge |
|---|---|---|
| 0 | every file byte-identical to the reference | allowed |
| 1 | differences exist, all **sub-visible** (below the thresholds) | allowed, report pasted in the review |
| 2 | at least one **visible** or **structural** difference, or a file with no reference counterpart | blocked |
| 3 | at least one **missing** file; takes precedence over 2 | blocked |
| 4 | **refused**: sets not comparable or invalid (see below). No verdict | blocked |
| 5 | usage or environment error | blocked |

### Capture

```powershell
# Reference: the build before the patch, the fixed save, the fixed keys, the fixed frames.
./bench/capture.ps1 -Name ref-0066 -Frames 128,256,512 -Engine $engine -Image $image `
    -DataDir $save -CacheDir $cache -KeysFile $keys

# Candidate: the patched build on the same inputs. -ReplayFrom reuses the reference's frames,
# keys, profile, file pattern and dump targets, and refuses a save whose tree hash differs.
./bench/capture.ps1 -Name cand-0067 -ReplayFrom ref-0066 -Engine $engine2 -Image $image `
    -DataDir $save -CacheDir $cache2

./bench/render-verify.ps1 -Reference ref-0066 -Candidate cand-0067    # exit code per the table
```

Sets live in `bench/out/captures/<name>/` (gitignored). `capture.ps1` refuses an `-OutDir` inside
the repository unless `git check-ignore` says it is ignored: a capture is a picture of the title.
`docs/uma-0065.md:123` asks for capture paths outside the repository; an `-OutDir` outside it is
always accepted and is the safer choice on a shared machine.

A set holds `capture.json` (the sidecar), `keys.txt`, `engine.{out,err}.log` and `capture/`, the
engine's files exactly as written. The sidecar records the frame list, the save-tree SHA-256
(same algorithm as `heavy.ps1`'s `data_tree_sha256`), the keys SHA-256, the engine SHA-256, the
console profile, the frame-file pattern, the dump-target setting, the full environment, the
command line, a SHA-256 manifest of every file, and `status`.

**What fixes the frames.** `VICTORY_KEYS` replays the same input, so the camera path is the same
(its syntax is the fork's, not this tree's; the script passes it through and records its hash).
`VICTORY_CAPTURE_FRAMES` names the frames and `VICTORY_DUMP_TARGETS` defaults to the same list
(`-DumpTargets` overrides, `-NoDumpTargets` leaves it unset). Capture is synchronous, which removes
the async-present reordering, but `docs/uma-0065.md:154` warns that scene timing can still move
content between frame numbers. That is what the determinism control is for.

**Crash safety.** A set is built in `<name>.partial-<pid>` and renamed to `<name>` only when every
requested frame exists, every PNG ends in `IEND`, nothing changed for `-SettleSec`, and the
sidecar is on disk (it is written last). Anything else is kept as
`<name>.incomplete-<utc>` with `status: incomplete`, the missing and corrupt files listed, and
exit 4. An incomplete set is a valid **candidate** (it verifies to exit 3) and is **never a
reference**. A name is never overwritten. A reference that is later edited, truncated or
added to is detected by its manifest and refused.

### Verify

1. **Exact.** SHA-256 per file. Equal bytes are `unchanged`.
2. **Perceptual**, on files whose bytes differ and that are PNG (8 or 16 bit, not interlaced):
   mean absolute difference per channel (R, G, B, A), share of pixels changed and visibly changed,
   bounding box of the visible change, a tile grid of per-tile MAD (`-GridX`/`-GridY`, default 8x8),
   and an edge-map comparison on luma. 16-bit input is compared on its high byte.
3. **Class** per file:

| Class | Rule (defaults) |
|---|---|
| `unchanged` | bytes equal |
| `sub-visible` | pixels identical but bytes differ (encoder or metadata), or RGB MAD <= 0.5 and at most 0.05 % of pixels changed by >= 8 |
| `visible` | RGB MAD > 0.5, or more than 0.05 % of pixels changed by >= 8 in some channel; **also any differing file that cannot be decoded**, so an unknown format never passes silently |
| `structural` | the edge map moved: edge XOR >= 0.02 % of all pixels and >= 5 % of the edge union (luma gradient >= 24); or the dimensions differ |
| `missing` | in the reference, not in the candidate |
| `extra` | in the candidate, not in the reference (counts as exit 2) |

**The thresholds are guesses, not calibrated against the title.** Before trusting the
sub-visible / visible line: capture the *same* build twice under two names and verify one against
the other. It must be exit 0. Anything else means the scene is not deterministic at those frames
and the gate is measuring noise; pick different frames or fix the input script first. Then verify
one deliberately changed build to see which class it lands in, and adjust the parameters
(`-SubVisibleMad`, `-VisibleDelta`, `-VisiblePixelFraction`, `-EdgeThreshold`,
`-StructuralEdgeRatio`, `-StructuralMinEdgeFraction`) once, in this file, with the numbers.

**Refusals (exit 4).** The two sets must agree on: the declared frame list (count first, then the
list), the save-tree hash, the keys hash, the console profile, the frame-file pattern and the
dump-target setting. The reference must be `complete`. Every file in either set must match its
manifest and nothing unrecorded may sit in `capture/`. A directory with no `capture.json`
(a run that died before finishing) is not a set.

**Report.** `bench/out/reports/verify-<candidate>-vs-<reference>.md` (and a `.json` twin) holds the
exit and what it means, a class count, both sets' hashes, a per-file table (MAD per channel, max
delta, changed and visible share, edge change) and, for every differing PNG, the bounding box,
the worst tiles and the full tile grid. Paste the `.md` into the review.

## Output (`bench/out/<label>/`, gitignored)

| File | Content |
|---|---|
| `summary.csv` | One row: heavy-frame count, p50/p95/p99/mean/max, GPU busy, per-stage means, ratios. |
| `buckets.csv` | n, p50, p95 per draw-count bucket. |
| `run<N>/frames.csv` | Every ring row of the run, all monitor fields by name, plus `heavy`. Empty cell = value absent. |
| `meta.json` | Engine, save-tree and keys hashes, extra env, recipe count, run spread, host facts, invalid reasons. |
| `run<N>/engine.{out,err}.log` | Engine output. |

`bench/baselines/<name>/` holds `summary.csv`, `buckets.csv`, `meta.json` only: numbers and the
hardware they came from, no game data. A baseline is only valid on the machine, GPU and driver in
its `meta.json`.

## Status of this harness

Written and reviewed by reading. **None of `heavy.ps1`, `capture.ps1` or `render-verify.ps1` has
been executed**: the sessions that wrote them could not run PowerShell. First use on the test
machine must start with `-Mode SelfTest` on each. `heavy.ps1`: then a `-Duration 60` smoke run
with a cold-cache refusal check (`-CacheDir` pointing at an empty folder must exit 3). Unverified
until then: that .NET opens `Local\KelvaroqStats-<pid>` verbatim, that robocopy `/DCOPY:DAT`
keeps the receipt valid, and the VICTORY_KEYS replay timing above.

Render gate, unverified until a real capture exists, because the fork's `capture.rs` is not in
this tree: that `VICTORY_CAPTURE` is a directory the engine fills; that it writes `frame-<N>.png`
for each number in `VICTORY_CAPTURE_FRAMES` (`docs/uma-0065.md:158`, the only statement of the
name; `-FramePattern` if it is wrong); that `VICTORY_DUMP_TARGETS` takes the same frame list
(inferred only from `0046-async-present-frame-waits.patch:1074,1090`) and that its files land in
the capture directory; the file format of the dumps (anything that is not PNG is compared by
bytes only and any difference is `visible`). Also unverified: that `Add-Type` compiles the C#
decoder as written, and that `Start-Process` runs the self-test's `.cmd` fake engine. After the
self-tests pass, the first real step is one capture, then reading its `capture/` directory.
