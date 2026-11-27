# Lane A 0068: forensic capture, bounded shutdown and removal dispatch

2026-11-26, DESKTOP-HFQAA89, Windows x64 / PowerShell. No title data used.
Four ordered subpatches, one concern per commit. This supersedes 0067's capture
and cap claims; live title restart/replay remains unsupported.

## Review objections and resulting behavior

1. **Honest tear window.** RAM begins with the 23-byte
   `SCARLRAM2FORENSIC_ONLY\n` header. Both READMEs explicitly reject loadable
   save-state interpretation. Sequential suspension can freeze interrupted
   object-graph, allocator, descriptor, command/fence and save-buffer updates;
   it does not produce an application safe point. Title writers stop before
   clone/copy, but kernel I/O, external writers and shared mappings can still
   mutate data. Non-cloneable/inaccessible mappings, OS handles and GPU-only
   state remain absent. RAM, committed saves and storage are not atomic.
   Source: loader `recovery.rs:10,99,277`;
   [format](../native/patches/0068-01-forensic-format.patch#L34),
   [generation README](../native/patches/0068-02-budgeted-suspended-capture.patch#L293).

2. **Capture leaves title threads.** The removal callback takes the save mutex
   before launching another instance of the executable. A busy save is skipped
   and prevents complete publication. The helper suspends every target thread
   except the dedicated termination watchdog, rescans for newly created threads,
   then clones/copies using its own allocator, filesystem and logging locks.
   No thread is resumed: termination follows success, error or deadline. Parent
   identity is checked by parent PID and process creation time. The executable
   handles worker entry before tracing or CLI parsing.
   Source: HLE `d3d12x/recovery.rs:33`, `xgamesave.rs:76`;
   loader `recovery/worker.rs:30,155,334`;
   [launch and suspension](../native/patches/0068-02-budgeted-suspended-capture.patch#L805).

   The shared deadline uses `GetTickCount64`: default **2,000 ms**, configurable
   by `VICTORY_RECOVERY_BUDGET_MS`, clamped to **50–10,000 ms**. Independent
   watchdogs terminate target/helper even during a blocked OS call. The parent
   watchdog stays runnable if the helper dies. Before cloning, admission checks
   readable committed RAM plus save/storage sizes against **250 ms + bytes /
   64 MiB/s** and remaining time. This is a policy estimate, not measured disk
   throughput. Oversize work returns early; deadline exit is **0xE0680002**.
   Source: loader `recovery.rs:17`, `recovery/worker.rs:30,155,404,432`;
   [budget](../native/patches/0068-02-budgeted-suspended-capture.patch#L318).

   A flushed `PARTIAL` marker and forensic README precede suspension. Hashes
   accumulate over successfully written bytes; artifact files are never reread
   at exit. `COMPLETE` is the last file written, followed by rename and removal
   of `PARTIAL`. The loader predicate rejects the marker even beside COMPLETE,
   and rejects `.partial` directories. Earlier generations are untouched.
   Complete means published streaming hashes, **not read-back verification**;
   verify artifacts offline. Hard termination can leave only partial evidence
   without a final JSON event. An external watchdog with a shorter deadline
   can still kill either process at any stage.
   Source: loader `recovery.rs:55,99,203,219`;
   [writer/publication](../native/patches/0068-02-budgeted-suspended-capture.patch#L369).

3. **DRED cost is explicit.** Recovery forces AutoBreadcrumbs off before device
   creation; page-fault tracking retains object/allocation metadata and naming
   costs at creation/destruction. Only
   `VICTORY_RECOVER_REMOVAL_BREADCRUMBS=1` enables recurring command-list
   metadata/progress tracking and the diagnostic note/marker path.
   `VICTORY_D3D12_DRED` cannot bypass that recovery policy. Pending command count
   is unavailable (`null`) without breadcrumbs. No title CPU/frame delta is
   claimed. Source: GPU `host.rs:615,1427,6394,6462,7084`;
   [policy and eight-combination regression](../native/patches/0068-03-dred-modes.patch#L22).
   Microsoft's [DRED guide](https://learn.microsoft.com/en-us/windows/win32/direct3d12/use-dred)
   describes allocation tracking and additional breadcrumb work; these are
   separate costs, not a claim that page-fault mode is free.

4. **Production dispatch is capped.** Every opted-in host submission/present/
   fence removal report crosses one process-lifetime atomic cap before callback
   code. Three owner-thread admissions are allowed; the fourth exits
   **0xE0680003**. Other threads observing the same removal park before consuming
   admissions. HLE's failure gate permits owner reentry so it cannot deadlock
   ahead of the cap. The test-only WARP reconstruction fixture has a separate
   guard: entering the live route during that probe exits **0xE0680004** before
   any callback or budget consumption. That probe is absent from production.
   Source: GPU `removal.rs:52,117`, `removal_warp_tests.rs:142`;
   HLE `d3d12x/recovery.rs:14`;
   [cap and real-route fixtures](../native/patches/0068-04-production-removal-cap.patch#L21).

   Normal title handling still exits at its first removal. The cap bounds
   callback admissions, not three invented title restarts: `attempts: 0` and
   `recovery_attempted: false` remain honest. Reports separately record
   `removal_dispatches` and `removal_dispatch_cap`. Ordinary complete/incomplete
   forensic exits remain **0xE0670001 / 0xE0670002**.
   Source: loader `recovery/worker.rs:280`;
   [event fields](../native/patches/0068-04-production-removal-cap.patch#L395).

## Measured checks

All commands use `--locked`; backend tests use `--test-threads=1`. Cached build
artifacts were reused sequentially; no task-owned server or watcher remains.

| Check | Observed result |
| --- | --- |
| Root `cargo test --locked` | **65 passed**, no title data |
| Backend `cargo test -p victory-gpu -p victory-hle -p victory-loader --lib` | **282 GPU, 113 HLE, 41 loader passed**; 15 existing GPU hardware/benchmark tests ignored |
| Backend GPU diagnostics `--features diagnostics --lib removal -- --nocapture` | **8 passed**, 0.51 s |
| Production `cargo check -p victory --bin victory` | Passed; existing unused `placed_filler_twins` warning remains |
| HLE preservation fixture after owner-reentry assertions | Passed: legacy exit, successful capture, busy-save partial, and two same-owner gate entries |
| Streaming manifest regression | Independent offline hash matches streamed digest; PARTIAL takes precedence over misleading COMPLETE; failed write preserves older bytes |
| PSS guarded-page fixture | **15,452,367 bytes in 26.2877 ms**; every RAM record parsed to EOF, guarded page bytes match, live guard remains armed |
| Out-of-process synthetic capture | **259.6572 ms** including startup, suspension, clone, files and target/helper termination; mutator counter unchanged across a 30 ms suspended interval |
| Oversize admission fixture | **239.7414 ms**, 128 MiB extra committed synthetic RAM refused under a 1 s budget; PARTIAL retained |
| Injected stalled helper | **1.0167264 s** under 1 s budget; target/helper terminated, PARTIAL retained |
| Injected helper death | **1.0193286 s** under 1 s budget; parent watchdog terminates target, no orphan helper, PARTIAL retained |
| Real WARP host removal recurrence | Asynchronous host fence notification → host failure → callbacks **1,2,3**, fourth refused with **0xE0680003** |
| WARP probe reentry | Actual standalone WARP removal; **zero callbacks**, exit **0xE0680004** |
| Eight simultaneous host observers | **One admission**, no premature cap exit during owner callback |

The RAM fixture size differs from 0067's fixture; its timing is not a controlled
before/after comparison. Mechanism delta: **three full artifact read passes
removed**, one hashing write pass retained. Frame-time and title-scale shutdown
deltas remain unmeasured. The two ~1.02 s observations show bounded synthetic
termination, not guaranteed completion of gigabytes before an external watchdog.

The complete numbered series reconstructs the exact tested indexed backend tree
from pinned `f85101b6095e8cf3cecf8f0647cc7f5428daa177`; whitespace check passes.
`cargo fmt --all --check` reports existing formatting differences throughout the
backend; no unrelated files were reformatted. New recovery modules pass targeted
rustfmt checks. The full backend workspace was not rerun: 0067's two baseline
rectangle-validator failures and broader diagnostics issues remain unresolved,
as recorded in [0067](removal-0067.md).

Remaining measurement: external title-size RAM/save/storage inventory, available
watchdog interval and actual storage throughput; configure the budget beneath
that interval and verify offline hashes in an isolated data directory. Measure
page-fault-only versus explicit breadcrumbs on the same fixed workload before
claiming a CPU/frame delta. No live resume, restoration or unsaved-progress
retention is established by these no-title tests.
