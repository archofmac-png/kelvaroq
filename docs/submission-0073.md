# 0073 — blocked-time counters, then prefix settle

Implemented on DESKTOP-HFQAA89, 2026-11-26, in `work/vf`, over `0db39a7`
(patches 0001–0072). Apply these in order:

1. `native/patches/0073-01-wait-counters.patch` — measurement only.
2. `native/patches/0073-02-prefix-settle.patch` — policy, default off.

Source references below are fork-relative paths and actual source lines.

## Step 0

| Ring field | Summary field | Meaning |
|---|---|---|
| `title_fence_us` | `title_fence_ms` | Title's blocking fence poll; contended submission lock and relay landing for explicit fence settles. |
| `title_value_us` | `title_value_ms` | Other title contention on instrumented queue/submission/flight locks, and title waits for relay publication. |
| `title_releaser_us` | `title_releaser_ms` | Title contention on `RELEASING`, including callers outside Present. |
| `title_pacing_us` | `title_pacing_ms` | Actual frame-slot backpressure in Present. |
| `pipeline_wait_us` | `pipeline_wait_ms` | Record-time pipeline condition-variable waits; ready pipelines and exhausted/zero budgets add nothing. |
| `relay_wait_us` | `relay_wait_ms` | Submit worker's wait for relay publication; title/helper waits are excluded. |

The counters accumulate nanoseconds with one relaxed atomic add per completed wait,
then expose cumulative microseconds; no counter lock, allocation, reset or enablement
check is added to the wait. An uncontended lock starts no timer. Title workers and
helpers are distinguished through existing thread-local identity. This does not
remove the pre-existing locks in worker clocks or the old textual logging path.
Sources: `crates/victory-gpu/src/frame_wait.rs:172`, `:185`, `:219`, `:225`;
pipeline wait: `crates/victory-gpu/src/pipeline/make.rs:387`;
publication: `crates/victory-gpu/src/monitor.rs:302`.

The ring now uses 60 of its 64 fields. Valid consecutive successful flip intervals
with no completed waits report numeric zero. Initial/discontinuous intervals retain
the existing absent-value protocol. Existing `bench/heavy.ps1:175`, `:181` and `:187`
already map these names to summary milliseconds, and `:262` includes them in comparison
output; no harness behavior change was necessary.

## Step 1

`VICTORY_PREFIX_SETTLE=1` enables precision only with the relay. Unset or `0` retains
the existing dependency policy. The disabled submission dependency branch was compared
with step 0 and is byte-for-byte unchanged. Sources:
`crates/victory-gpu/src/host/prefix_settle.rs:6`, `crates/victory-gpu/src/host.rs:6674`.

Each flight retains shader-declared writes, bottom-of-pipe destinations, and pitched
readback destinations. The metadata remains present while the relay has taken the
flight out of its queue. The relay advances `landed_through` only after merges,
readbacks, bottom writes and ordered fence publication have finished. Selection walks
newest first, chooses the newest overlapping flight newer than the submission's
settled watermark, and waits for `landed_through >= target`. FIFO publication supplies
the older prefix. Duplicate read ranges or duplicate list indices do not add a second
wait. The relay can independently retire later flights that are already ready; this
policy never requires waiting for them. Sources:
`crates/victory-gpu/src/host/prefix_settle.rs:55`, `:172`;
`crates/victory-gpu/src/host.rs:5887`, `:6264`.

The initial flag-on check is independent of legacy `line.written`, which lacks bottom
writes and readbacks. Reads include direct views, CPU copy sources and destinations,
fills, texture sources, and whole per-shadow refresh/pool/write spans, including gaps.
This is conservative and may wait where the older fill/merge shortcuts did not.
Source: `crates/victory-gpu/src/host/prefix_settle.rs:235`.

Full settle remains for incomplete sets: arbitrary callbacks, dynamic raw stores,
computed descriptor stores, in-place writers, unknown/overflowing destinations,
unproven private producer backing, translated reader ranges, changed mapping epochs,
or an unavailable mapping guard. Producer private/untranslated proofs are cached at
publication; mapping/free/view notifications invalidate them. Raw-directory lifetime
changes, synchronous work, sweep and capacity limits keep their existing full-settle
paths. Sources: `crates/victory-gpu/src/host/prefix_settle.rs:193`;
`crates/victory-gpu/src/memory.rs:266`, `draw.rs:1603`, `shadow.rs:2910`;
`crates/victory-gpu/src/watch.rs:1330`; `crates/victory-gpu/src/host/uma.rs:12`.

## Extra work, counted

Let R be the nonempty read spans visited by the summary prepass. With complete sets,
an unchanged mapping epoch, and **disjoint combined envelopes**, selection adds:

- Exactly `2(R−1)` endpoint comparisons to form the read envelope, for R > 0.
- One epoch equality comparison and one or two envelope endpoint comparisons.
- Per-span zero/overflow checks, direct-span validity checks, step dispatch, fixed
  empty/completeness branches, one nonblocking mapping guard and one remap lookup.
- No per-flight/range scan, vector allocation, `VirtualQuery`, or settle on this path.
  An empty pending set returns before scanning reads.

If envelopes overlap but individual spans do not, precision needs its detailed pass.
For F remaining flights, W total written spans and D detailed read spans, its search
uses at most `2WD` interval endpoint comparisons plus two ID/watermark comparisons
per flight, and up to four envelope endpoint comparisons across the two passes.
Detailed per-shadow grouping also compares owner IDs; its worst case is quadratic
in the number of refresh steps. It still settles nothing when there is no overlap.
Sources: `crates/victory-gpu/src/host/prefix_settle.rs:20`, `:172`, `:193`, `:235`.

Separately, publishing a new flight copies its W producer spans into retained metadata,
updates the combined envelope (up to two endpoint min/max comparisons per span), and
performs up to W private-memory queries/remap lookups once. It can allocate. These
are real flag-on per-submission costs; the feature as a whole is not allocation-free.
The counter implementation allocates nothing; the envelope-disjoint collector adds
no vectors. The optional scoped mapping gate retains its existing mutex/vector
bookkeeping (`crates/victory-gpu/src/watch/scoped.rs:43`); the default global gate
uses `RwLock::try_read`.

## Verification and limits

Focused checks passed: counter accumulation, uncontended zero, pipeline ready/pending
waits, ring schema/zero deltas, no overlap, overlap at N, duplicate target suppression,
in-hand retention, overflow and mapping invalidation. Controlled diagnostics WARP runs
passed the 10-test prefix suite with relay enabled, including actual `Host::submit`
with duplicate detached-list indices and a dependency represented only by a bottom
write: A published once while disjoint B stayed behind an unsignalled gate. The
32-word full-settle fixture produced identical 256 bytes with the flag off and on.
`bench/heavy.ps1 -Mode SelfTest` passed. A task-local copy of that self-test,
using the unchanged production reader/summary functions, additionally passed all six
microsecond-to-millisecond mappings and all six numeric-zero cases. The product's
`cargo test --locked` passed 66 tests. Changed-file policy and formatting checks passed;
applying both patches to a fresh index over 0072 reproduced the committed fork tree.

The complete fork workspace run passed 293 GPU, 113 HLE and 52 loader tests, but was
not green: two unchanged shader rectangle tests failed DXIL PSV validation, and xtask's
repository policy rejected the unchanged oversized lowerer and parser seed fixtures
(85 violations). The first loader deadline run failed once; the full rerun passed it.
The failing shader, xtask, fuzz and manifest trees match 0072. Full CI Clippy is also
blocked by the unchanged `stats_ring.rs:141` constant `chunks_exact` lint. Targeted
GPU Clippy also reports existing sort/enum/borrow/MSRV/test-style failures; none
point at the new prefix or counter implementation.

No title files were used. Heavy-frame milliseconds, drop ratios and title captures
are **unmeasured**. No speedup or rendered-title equivalence is claimed.

## A/B on a title-equipped machine

Run from the product root. Set `$engine`, `$image`, `$save`, `$cache`, and `$keys` to
the patched diagnostics-capable executable and external fixed inputs. Use the same
binary and warmed master cache in both arms. `-ExtraEnv` is required because the
harness clears inherited `VICTORY_*` variables (`bench/heavy.ps1:408`, `:642`).

```powershell
./bench/heavy.ps1 -Mode Warm -Engine $engine -CacheDir $cache
./bench/heavy.ps1 -Engine $engine -Image $image -DataDir $save -CacheDir $cache `
  -KeysFile $keys -Duration 300 -Runs 3 -Label prefix-off-0073 `
  -ExtraEnv @{VICTORY_PREFIX_SETTLE='0'} -SaveBaselineAs prefix-off-0073
./bench/heavy.ps1 -Engine $engine -Image $image -DataDir $save -CacheDir $cache `
  -KeysFile $keys -Duration 300 -Runs 3 -Label prefix-on-0073 `
  -ExtraEnv @{VICTORY_PREFIX_SETTLE='1'} -Baseline bench/baselines/prefix-off-0073
```

Inspect relay, card, dependency, submit work/watch/deferred, all title blocker and
pipeline waits, p50/p95, drawn/dropped ratios and draw-count buckets. Carry only with
at least 5 ms less relay wait or 5% lower p50, unchanged drawing ratios, and the render
gate below. Reject a timing win caused by dropped work.

Captures are separate untimed runs. First establish off/off determinism, then compare
off/on, as required by `bench/PROTOCOL.md:196`:

```powershell
./bench/capture.ps1 -Name prefix-off-0073 -Frames 128,256,512 `
  -Engine $engine -Image $image -DataDir $save -CacheDir $cache -KeysFile $keys `
  -ExtraEnv @{VICTORY_PREFIX_SETTLE='0'}
./bench/capture.ps1 -Name prefix-control-0073 -ReplayFrom prefix-off-0073 `
  -Engine $engine -Image $image -DataDir $save -CacheDir $cache `
  -ExtraEnv @{VICTORY_PREFIX_SETTLE='0'}
./bench/render-verify.ps1 -Reference prefix-off-0073 -Candidate prefix-control-0073
./bench/capture.ps1 -Name prefix-on-0073 -ReplayFrom prefix-off-0073 `
  -Engine $engine -Image $image -DataDir $save -CacheDir $cache `
  -ExtraEnv @{VICTORY_PREFIX_SETTLE='1'}
./bench/render-verify.ps1 -Reference prefix-off-0073 -Candidate prefix-on-0073
```
