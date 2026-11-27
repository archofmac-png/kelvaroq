# Lane A 0069: recovery budget arithmetic

2026-11-26, DESKTOP-HFQAA89, Windows x64 / PowerShell. No title data used.
[Patch 0069](../native/patches/0069-recovery-budget-accounting.patch) supersedes
0068's admission, streaming-hash and equal-deadline claims. No live resume.

## Changes and invariants

- Budget configuration is **300-10,000 ms**, default 2,000 ms. The admission
  constant is derived: measured process creation/worker startup plus **50 ms**
  setup. Startup is charged once, from before spawning the executable, including
  its logging initialization. The error states the admission invariant and each
  cost. Source: loader `recovery.rs:24,43,60`; `recovery/worker.rs:74,224,230`.
- Relative to that same origin, cooperative work expires at **B-200 ms**,
  parent hard termination at **B-125 ms**, helper fallback at **B-25 ms**.
  The parent watchdog uses an absolute deadline, including its own thread
  creation/rendezvous. The helper watchdog waits for parent termination or its
  later fallback; it no longer races the parent to hard-terminate the target.
  Work has **75 ms** reporting grace before the parent; hard watchdogs have
  **100 ms** separation. Source: loader `recovery/worker.rs:13,25,83,240`.
- The floor invariant is **300 > 200 reserves + 50 setup**. Zero bytes can be
  admitted if measured startup plus elapsed worker work fits the remaining
  50 ms; real startup may exhaust it. The minimum is arithmetically reachable,
  not a promise of capture on every host. All 9,701 allowed integer budgets
  are checked. Source: loader `recovery/worker.rs:585`.
- Admission separately charges **bytes / 64 MiB/s for copy** and **bytes /
  64 MiB/s for read-back hashing**, rounding each up. These are policy rates,
  not measured throughput. Each artifact is written, flushed, then reread and
  hashed under the work deadline, including README.txt. A regression modifies
  the written file before hashing and verifies the manifest reflects disk bytes.
  Source: loader `recovery.rs:60,68,145,427`; `recovery/worker.rs:293`.
- Production initializes logging before worker entry. JSON already used a
  direct append/flush to the parent's configured crash-log file, independent
  of tracing; that sink remains. Source: app `main.rs:143`; loader
  `recovery/worker.rs:364,388`.

`PARTIAL` is flushed before suspension or artifact capture, rather than created
by timeout handling (`recovery.rs:120`; worker `:278`). Hard termination may
still interrupt a blocked artifact write or flush; the marker already exists.
No fixed margin guarantees scheduling or termination under arbitrary OS stalls.
The arithmetic test models opposing 15 ms clock offsets, a 16 ms timer tick
and 25 ms termination latency. Microsoft's [GetTickCount64 reference](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64)
documents the shared boot-relative clock and typical 10-16 ms resolution.

## Observed verification

| Check | Result |
| --- | --- |
| Root `cargo test --locked` | 66 passed, no title data |
| Backend `cargo test --locked -p victory-gpu -p victory-hle -p victory-loader --lib -- --test-threads=1 --nocapture` | 282 GPU, 113 HLE, 43 loader passed; 15 existing GPU tests ignored |
| `cargo check --locked -p victory --bin victory` | Passed; existing unused `placed_filler_twins` warning |
| Recovery module rustfmt checks; staged whitespace check | Passed |
| Full ordered patch series reconstruction | Exactly matches tested tree `925bd02edb0ab724351daab1171a7042510b3e81` |
| Guarded PSS archive | 15,407,311 bytes, 34.9739 ms; parsed to EOF, live guard remains armed |
| Synthetic complete capture | 322.8300 ms, including startup and target/helper cleanup |
| Oversize admission, B=1,000 ms | 260.5473 ms; PARTIAL retained |
| Stalled helper, B=1,000 ms | 889.6946 ms; parent terminated first, PARTIAL retained |
| Dead helper, B=1,000 ms | 899.9159 ms; parent watchdog terminated target |
| Helper clock +15 / -15 ms, B=1,000 ms | 884.3837 / 897.7144 ms; parent terminated first in both cases |

The stalled/dead-helper observations are **127.0 / 119.4 ms earlier** than
0068's recorded 1,016.7264 / 1,019.3286 ms. These are individual synthetic
observations, not a worst-case latency proof. All incomplete fixtures assert
both processes stop within 1,000 ms, retain PARTIAL and publish no COMPLETE.
The new read-back pass adds one full artifact read; no capture throughput or
frame-time improvement is claimed. Logs are in `target/native/0069-*.log`.
No task-owned helper/server remains. Broader backend workspace/diagnostics
baseline failures recorded in 0067 were not rerun or resolved here.

## Guard protections and frame cost

**Yes: protections armed at suspension remain armed on live title RAM.** The
helper suspends target threads without changing their mappings; only PAGE_GUARD
on the PSS clone is cleared. Residency's separate PAGE_READONLY protections are
also untouched. Suspension is sequential, so a thread can still alter guards
before that thread stops. The no-title PSS test verifies a live guarded page
remains armed. Source: loader `recovery/worker.rs:408`; `recovery.rs:328,554`;
GPU `watch.rs:943,996`.

**After suspension there is no executing title frame path:** threads stay stopped
until termination, with no resume. Before removal, normal guarded-memory costs
remain: write access violations, guard mutex/alias bookkeeping and VirtualProtect
to reopen pages, plus submission-side journal/dirty-range scans and re-arming.
Recovery adds host/present flag checks and one blocked removal-wait thread/event;
default DRED page-fault mode retains object-lifetime tracking and naming costs,
while recurring breadcrumbs require the separate subflag. No incremental title
ms/frame was measured. Measure matched flag-off/on workloads with GuardFaults,
GuardUs/WatchUs, VirtualProtect counts and DRED object-lifetime costs before
assigning a frame delta. Source: GPU `watch.rs:593,768,1068,1355`;
`host.rs:569,606,1425,6361,8914`; loader worker `:408,477`.
