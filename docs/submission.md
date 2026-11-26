# Submission path: current graph, blocking points, target design

Lane B. Audience: Lane A (implements) and anyone reviewing a submission-path patch.

## Read this first: what was and was not verified

- The pinned fork (`f85101b`) is **not in this tree**. The submission path exists here only as
  `native/patches/*.patch`. Every `file:line` below is **a line of a patch file**
  (`NNNN` = `native/patches/NNNN-*.patch`), and names the fork-relative source file and function
  it lands in. Fork line numbers are not cited because they cannot be checked from here.
- Bodies the patches only show in part (`Host::submit`, `Host::settle`, `queue::execute`,
  `release_held`) are described from their hunks. Where a claim needs the full body it is marked
  **[verify in fork]**. Nothing here was measured; numbers come from `documentation.md` and
  `README.md` and are cited as such.
- No Lane A commit exists on `forge` at HEAD `e062a82` (README change). Patch `0063-uma` is in the
  series already; section 6 reviews it as it sits.

## 1. What already exists (so Lane A does not rebuild it)

| Piece | Where | Default |
|---|---|---|
| Dedicated submit thread `victory-submit`: title only queues lists, the thread prepares and sends | `queue.rs::behind/worker`, 0040:8-27, 0036:134-159, 0046:832-862 | on (`VICTORY_ASYNC_SUBMIT`) |
| Flights: submissions sent to the card and not waited for, landed later by the relay thread | `host.rs::Late/Flight`, 0036:40-48, 0046:288-294, 0046:360-382 | on |
| Async present: the title returns from Present at once; the show runs behind the lists, at most two frames ahead | `queue.rs::present_in_order/FrameLimit/FrameSlot`, 0046:1005-1116, 0048:20-29 | on, `VICTORY_FRAMES_AHEAD=2` |
| Copy-queue lanes with cross fences | `queue2.rs`, 0040:44-58 | on (`VICTORY_QUEUE2=3`) |
| Per-stage clocks of both workers, published to the monitor ring | `frame_wait.rs`, 0053:5-115; `monitor.rs`, 0064:395-458 | on with the monitor |

So "frame N+1 records while frame N is in flight, bounded to two" is **already true at the Present
boundary**. What is not true is that preparation of N+1 can overlap anything: see section 3.

## 2. Current call graph, title thread to queue submission

```
title thread
 ID3D12CommandQueue::ExecuteCommandLists
  queue.rs::execute                      0021:198-210 (held path only; rest [verify in fork])
   submit_cut / submit_split             0021:91-141   cut lists at waits; title evaluates list waits
    push Held::Run(lists, order)         0021:104-109, 137   under queue.held.commands (Mutex<Vec<Held>>)
    register(queue); wake()              0021:68-74, 0046:829
 ID3D12CommandQueue::Signal / Wait       queue.rs::signal 0036:207-221, wait 0046:933-941 (Call::QueueFence)
  push Held::Signal / Held::Wait         0036:128-131, 223-229 (FenceRef keeps the fence alive)
 ID3D12CommandQueue::Present(X)          queue.rs::present 0046:1122-1177
  CALLS mutex                            0046:1137-1144
  present_in_order                       0046:1084-1116
   FrameLimit::enter (slot)              0046:1020-1029
   enqueue_present -> Held::Present      0046:1041-1053

victory-submit thread                    queue.rs::worker 0046:832-862
 release_held_now(false)                 0046:868-931, serialized by RELEASING 0046:871-880
  per queue line, head of line:
   Held::Wait   fence < value  -> park   0036:168-174
   Held::Value  (title-written memory)   0036:176-192  value_met -> host::late_met, 4 ms poll 0046:845-851
   Held::Run    -> host.execute_late     0021:509-511
    Host::submit                         0046:5787-6120 hunks (patch lines 537-623)
     lock host.submitted                 0046:541-542   "One submission at a time from preparation to copy-back"
     settle(WHY_STALE) if reads overlap flights' writes   0046:557-593 (blocked_by 0063:52-73)
     stages: descriptors, watch+coherence, deferred copies+barriers, snapshots, card setup
                                         0053:5-15, 98-115  (86 ms/heavy frame, documentation.md:159)
     ExecuteCommandLists on the host queue (Stage::Execute)   0053:85-93
     card waits: WaitForSingleObject(event, INFINITE)         0046:494-496, 531-534, 609-612
    push Flight, _frame slot             0046:288-294, 499-505, 520-527
   Held::Signal -> late_signal or fence::set   0036:199-205
   Held::Present -> show(): RELEASING stays held, queue line opened   0046:912-920
    Host::present(Queued) -> execute_own(copy, slot)   0046:641-727, 511-527
     swap_chain.Present(0, 0)            0064:166-170

victory-relay thread                     host.rs::relay_worker 0046:360-382
 waits card fence (Stage::Card), fetches, lands writes, then
 Late::Write / Late::Signal -> fence::set  0036:93-99    <- the title's fences complete here
 Flight dropped -> FrameSlot returned      0046:1033-1038
```

## 3. The three places a heavy frame blocks

Only one of the three is measured. `documentation.md:159`: with async present the title spends
0.1 ms per frame in the Present call, and the submit thread is "le seul chemin critique" (86 ms
work + 15 ms waiting on the relay). The other two exist as counters in a log line
(`frame_wait::line`, 0046:229-245) but **not in the monitor ring** (0064:403-458), so the harness
cannot see them yet. Step 0 below fixes that.

**B1. Title thread in Present (backpressure).**
`CALLS` (0046:1137-1144) serializes presenting title threads. `FrameLimit::enter` parks the title
in `wait_while` when two slots are taken (0046:1020-1029, timed as `Call::Pacing`). A slot is
returned only when the flight that owns it is dropped (0046:292-293, 1033-1038), i.e. after the
**relay has landed it**, not when the GPU finished. A capture or a present with no source forces
the synchronous path and `wait.recv()` (0046:1090-1094, 1110-1113). Measured: 0.1 ms/frame today.

**B2. Title thread behind locks the workers hold across preparation, and in fence/value waits.**
- `settle_now` takes `host.submitted` (0046:314-321). `Host::submit` holds the same lock from
  preparation to copy-back (0046:541-542). Any title call that reaches `settle_now`
  (`late_met` 0046:306-312, `settle_for_fence` 0046:326-329) parks behind a whole preparation.
- `ID3D12Fence::SetEventOnCompletion(value, NULL)` with async present waits in a 4 ms poll loop
  (fence.rs, 0046:9-38) after `settle_for_fence`.
- `queue::execute` computes `unmet` list waits on the title thread (0021:198-210), which calls
  `late_met` -> `settle_now(WHY_VALUE)`; timed as `ValueLanding` (0046:204-206, 310).
- `release_held` from `wait`/`signal` (0021:232-234) can contend on `RELEASING`, which the worker
  holds for a whole `Held::Run` (0046:871-880; timed `Call::Releaser`).
Not measured. Likely cost is bounded by one preparation (~86 ms) per hit.

**B3. Title thread waiting for a host pipeline.**
Recording a draw or mesh dispatch calls `pipeline::host_pipeline` (0061:5-15, 0041:9) ->
`make::ready` (0050:1068-1105) -> `wait(p, frame)`. Budget is 4 ms per title frame shared by all
threads (0016:39-53), 500 ms for the decoration-bake pipelines (0016:55-67). The title starts two
or three frames per presented frame (0016:22-28), so 4 ms is paid per title frame, not per
presented frame. Measured: `pipeline_wait_us` is a ring field (0064:437, 721-727); no value
published. Cost is traded against dropped draws (~7 %, README:75).

Not on this list but on the critical path: the **submit thread's own waits** are the card fence
(0046:494, 533, 611), the relay landing (`relay_wait`, 0046:353), fetch fences (0046:442, 459) and
the unmet-value poll (0046:845). Those are the 15 ms and they are why B1 stays quiet today.

## 4. Target design

Invariants, each with the counter that proves it. A steady-state heavy run must read **0** on the
first three.

| # | Invariant | Proof counter (monitor ring) |
|---|---|---|
| I1 | No title thread waits on a fence, a lock a worker holds, or a pipeline | `title_pacing_us`, `title_fence_us`, `title_value_us`, `title_releaser_us` (new, step 0) and `pipeline_wait_us` (exists) |
| I2 | Recording takes no lock; enqueue is wait-free | `title_releaser_us` = 0, and review: no `Mutex` on the record path |
| I3 | Exactly one thread calls `ExecuteCommandLists` on the host queue; it never sleeps on the title or on the card | `submit_card_us`, `submit_dependency_us` -> 0; `submit_idle_us` is the only sleep |
| I4 | Frame N+1 records and prepares while frame N is in flight; at most 2 frames prepared-but-unretired | `frames_in_flight` (new, gauge, never > 2) |

**4.1 Recording is wait-free (I2).** Replace `QueueLine.commands: Mutex<Vec<Held>>` (0021:56-60)
by per-title-thread SPSC rings, one per (queue, thread), plus a per-queue atomic `ticket` taken at
the API call. The submit thread merges rings by ticket, so list/signal/wait order is the order of
the API calls exactly as today. Title threads are few (7 usable cores, documentation.md:193), so
per-thread rings are cheaper than a general MPSC. Capacity: 4 frames of commands.
Overflow is the one permitted block and is counted (`title_block_us`); it must read 0.

**4.2 Fences are words, not waits (I1).** Every title-visible fence is an `AtomicU64` advanced by
the relay thread. `GetCompletedValue` is a load. `SetEventOnCompletion(event)` pushes onto a
lock-free waiter list that the advancing thread drains. The NULL-event blocking form, which is the
title's own wait, becomes `WaitOnAddress` on the fence word: no 4 ms poll (0046:27), no
`host.submitted`, no `settle_for_fence`. The title may still sleep on its own fence; that wait is
the title's, ends at the earliest correct moment, and is attributed (`title_fence_us`) but is not
ours to remove.
`late_met` leaves the title thread entirely: `execute` enqueues `Held::Value` unconditionally and
only the submit thread evaluates it.

**4.3 Pipelines never block recording (I1).** The list records `PipelineRef(Arc<Pending>)`. The
submit thread resolves it at prepare. If not made, the draw is dropped, exactly as past the 4 ms
budget today, and counted. The budget becomes 0. This is only acceptable once install-time
precompile covers the shader pack (FORGE-BRIEF priority 4); until then keep 4 ms, and the
harness's `dropped_ratio` is the guard. The 500 ms bake exception moves to the submit side as a
parked line, never a title wait.

**4.4 One submitter that never sleeps on the card (I3).** `victory-submit` becomes an event-driven
scheduler over per-queue lines. A line is `Ready`, `Parked(fence, v)`, `Parked(value watch)` or
`Parked(flight k)`. The thread sleeps only when every line is empty or parked.
- Card waits (0046:494, 533, 611) become fence-completion events delivered by the relay/completion
  thread (`SetEventOnCompletion` + a registered wait), which re-arms the parked line.
- A value wait on title memory parks its line and is re-armed by the existing write-watch
  (`watch::*`, 0064:746-759), with the 4 ms poll kept only as a fallback. The thread keeps
  **preparing later frames' independent steps** while the line is parked.
- A stale-read settle parks the line on flight k (section 7), it does not sleep the thread.

**4.5 Two frames overlap, bounded (I4).** Credits are counted by the submit thread at
**prepare start**, not at title Present: frame k may begin preparation only when frame k-2 has
retired (GPU fence reached, landings applied, title fences advanced, arena slot freed). The title
records ahead freely up to the ring capacity (4.1). This moves backpressure off the title:
`FrameLimit::enter` (0046:1020-1029) is deleted from Present and survives only as the counted
overflow path. Each frame owns `slot = k & 1`: upload/constants arena, dynamic descriptor range,
list allocators, and its `FrameSlot` token (already the right shape, 0046:1005-1038).

**4.6 Title-visible fences complete at "last read of title memory", not "relay landed".** With
snapshot reads that is prepare-complete, earlier than GPU-complete; with in-place reads (Lane A) it
is GPU-complete. Make the point explicit per submission (`consumed_at: Prepare | Gpu`). This is the
lever that frees the title early when memory was snapshot, and the guard that keeps it safe when
it was not (R1).

## 5. What breaks first when two frames overlap, ranked

Ranking is severity x how hard it is to see. None of this is measured; it is derived from the
code in section 2 and 6 and must be confirmed with the guards turned on.

| Rank | Hazard | Why it breaks first | Guard |
|---|---|---|---|
| R1 | **Constant / upload memory reused by the title while frame N still reads it** | Today table constants are read at *prepare* (snapshot) or via the pool (0063:318-330). With in-place reads the GPU reads title memory *while it executes*, up to two frames after recording. The title reuses its upload ring when **its** fence completes (0048:12-14). If any fence completes before the last GPU read, the pixels are wrong and nothing crashes. | (a) Fence-complete = last read of title memory (4.6); assert in debug that no `Late::Signal` is applied before its flight's fence. (b) Per list, record a write-watch epoch at Close; at prepare, if watched pages under a recorded constant range were written since and the frame's fence has not completed, count `reuse_hazard` and fall back to snapshot-at-Close for that range. (c) `detached.whole_recording` ownership rule stays (0063:278-280). |
| R2 | **Page remap / placed-heap free while a flight reads it** | Lane A's resident views make the remap path (`CopyPageMappings`, 0062, 0004, 0037) a GPU-lifetime event. Two frames in flight double the window. Failure is device removal or stale texels, intermittent. | Epoch retire list: a remap/unmap/free of a region is deferred until every frame whose `Detached` lists reference it has retired. `Deferred.kept` already holds heaps per list (0021:11-13, 0063:25-32); extend with the slot token. |
| R3 | **Dynamic descriptor heap capacity** | Two frames live at once need twice the slots. Already seen once: "no free dynamic descriptor slots" for ~30 s, cause unknown (documentation.md:121). It is the first *loud* failure. | Per-slot descriptor ranges (4.5). Gauge `descriptor_slots_used` in the ring. Fail the harness run if the heap fills (log scan). |
| R4 | **Tracked resource state (aliased render targets)** | Host state is resolved in the submit-time prelude under the submission lock (0046:676-680), which is correct. It breaks if any record-time reader remains: `Present` calls `host_transition(resource, COPY_SOURCE)` on the title thread (0046:1160-1167). With N+1 recording while N prepares, that read races the prelude. Aliased placed RTs share one physical range across passes and frames; order on the single direct queue keeps them correct, copy-queue lanes do not. | Single writer: only the submit thread mutates tracked state. Recording captures *intent* (first-use state) only. Delete the record-time `host_transition` read. Copy-lane sends must wait on the previous frame's last writer fence (exists: `QUEUE_ORDER`, 0046:4390-4416). |
| R5 | **Frame-ordered side channels**: capture, `--capture`, `blinks`, write-watch `ahead` tickets | Capture forces `synchronous` -> 1 slot (0046:1090-1094): **a captured run is not the timed configuration.** `ahead_ticket` is "consumed once under the submit lock" (0053:136-137) and assumes one preparation at a time. | Captures are a separate untimed pass (PROTOCOL.md). Keep one preparation at a time until 4.4's prepare-ahead is proven; tickets get the frame id. |
| R6 | Fence poll latency and DXGI `Present(0)` inside the submit thread | Unmet-value waits are re-checked every 4 ms (0046:845); a chain of them adds up to 4 ms each. `Present` runs on the submit thread (0064:166); if the swap chain's latency queue is full the thread blocks. **[verify in fork: frame latency setting]** | Write-watch re-arm (4.4); move `Present` to the relay/completion thread. |

## 6. Standing review of patch 0063-uma as it sits in the tree

Authorship is unverified (no `git log` available in this session); verdict is on the code.
**Accept with changes.** It removes copies, and it adds submit-thread cost that the stage clocks
will mis-attribute.

1. `uma::prepare_directory` calls `host.settle(submitted, WHY_READ)` before every submission that
   has `pool_bound` (0063:84-94, 263). A full settle on the submit thread serializes prepare N+1
   behind flight N, which is the thing this restructure removes. The wait lands in
   `relay_wait_us`, not in a stage that looks like "UMA cost". Change: settle only the flights
   whose written ranges intersect `bound` (same predicate as `blocked_by`, 0063:56-60).
2. `uma::bind_constants` returns early when `flying()` (0063:288). With overlap there is always a
   flight, so the direct-constant path never fires and the run silently falls back to copies. The
   A/B would show no change and look like "UMA does nothing". Change: replace `flying()` by a
   check on the specific constants' ranges, and export a counter of fallbacks.
3. `Deferred::direct_read` inserts into a `HashMap<u64, ...>` per buffer read, **on the title
   thread at record time** (0063:27, 40-47, 151-154). Small, but it is title CPU the monitor
   attributes to `title_us`, and it breaks I2. Change: a small fixed array keyed by shadow id.
4. `pool_ranges`/`pool_reads.fallback` allocate a `Vec` per submission (0063:112, 115-117). Reuse.
5. `crate::watch::title_memory_reading_now()` (0063:298): cost unknown. Needs a stage clock.

## 7. Smallest first step: prefix settle

**Change.** `Host::settle` waits for **every** flight in the air (0036:90-92). `blocked_by` already
decides whether a submission reads memory a flight writes (0063:52-73), and `Line` already keeps
per-flight written ranges (a test reads `line().written`, 0046:735-737) **[verify shape in
fork]**. The relay lands flights FIFO (`Line.line`, 0046:365-374). So settle only up to the
**newest flight whose written ranges intersect this submission's reads** (a prefix of the line),
not the whole line. `relay_wait(why, done)` already takes a predicate (0046:348-355); `done` becomes
`line.landed_through >= k`. Flag: `VICTORY_SETTLE_PREFIX=1`, default off for the A/B, then default on.

**Why this one.** It needs no Lane A work, shrinks the measured critical path (submit awaiting
relay is 15.2 ms of ~108, documentation.md:159), is read-only with respect to ordering (a prefix
lands in order), and introduces a flight id that sections 4.4 and 4.5 need anyway. It is also
the fallback path once residency lands, for memory that is not resident.

**Measure.** Harness, same save, warm cache, 300 s, 3 runs per arm: `relay_wait_ms`,
`submit_card_ms`, `p50_ms`, `p95_ms`, and `drawn_ratio` unchanged.
**Carry it only if** `relay_wait_ms` falls by >= 5 ms or p50 by >= 5 %. The upper bound is ~15 ms,
so a smaller win is a micro-tune and CLAUDE.md says to drop it.
**Correctness.** Capture before/after and diff; a unit test where flight B (disjoint ranges) is
still in the air after a settle for flight A, and one where B overlaps and is landed.

**Step 0 (parallel, no behaviour change, ship first).** Publish `title_pacing_us`,
`title_fence_us`, `title_value_us`, `title_releaser_us`, `frames_in_flight`, `reuse_hazard` into
the ring through `monitor.rs::EXTRA` (0064:462-465; names must be `[a-z0-9_]`, <= 31 chars, 64
fields max; 0064:403-458 plus the two extras use 56, so six more fit). The harness picks them up
by name and reports them as `title_*_ms` when present. Until they exist
B1 and B2 are unmeasured and should not be prioritised over each other.

## 8. Order of work after step 1

1. Step 0 counters. 2. Prefix settle (section 7). 3. Title takes no worker-held lock: `late_met`
off the title thread, `RELEASING` not taken by `wait`/`signal` (B2). 4. Fences as words, no 4 ms
poll (4.2). 5. Per-thread recording rings (4.1). 6. Prepare credits and per-slot arenas, delete
`FrameLimit` from Present (4.5, R3). 7. Event-driven submit scheduler (4.4). 8. Pipeline budget to
0 after precompile lands (4.3).
Each is one patch, with the harness numbers in its commit body.

## 9. Review lens for every Lane A commit

Verdict `accept`, `accept with changes` or `reject`, with file:line. For each patch ask:

- Did it add a `settle(`, `relay_wait`, `frame_wait::lock` or `flying()` guard on the submit path?
  That is serialization the author does not see because it lands in another stage's clock.
- Did it add work on the **title thread at record time** (hash insert, `Vec` push, `Arc` clone per
  draw)? Multiply by ~1,400 clamped calls and ~5,000 draws per frame.
- Did a new fallback path hide a feature (`if flying() { return }`)? Demand the fallback counter.
- Did `drawn_ratio` fall while time improved? That is a picture change, not a speedup.
- Harness delta: `submit_work_ms` and `watch_ms`/`deferred_ms` before and after, not only p50.
