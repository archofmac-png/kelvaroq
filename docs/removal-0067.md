# Lane A 0067: device-removal preservation

2026-11-26, DESKTOP-HFQAA89, Windows x64 / PowerShell. No title data used.
Source citations below refer to the backend produced by the complete numbered
series. The two 0067 subpatches each have one concern.

**Delivered: default-off detection, verified forensic preservation and the
unsafe-resume exit. Live title resume and a zero-progress-loss guarantee are
not implemented.** The title path makes zero automatic recovery attempts.
The three-attempt budget and actual device reconstruction are exercised in
an isolated WARP fixture, not wired up as a live title restart policy.

## Behavior and limits

- `VICTORY_RECOVER_REMOVAL=1` enables the path; absence or `0` preserves legacy
  handling (`removal.rs:5`, `host.rs:528`, `d3d12x.rs:35`). It remains default
  off; no successful title validation or automatic enablement is claimed.
- Removal is classified from `DXGI_ERROR_DEVICE_REMOVED` / `RESET` or a failing
  `GetDeviceRemovedReason`, including a reason such as `DEVICE_HUNG`
  (`removal.rs:11`, `host.rs:519`). Present's HRESULT is passed explicitly
  (`host.rs:8864`). Other faults keep their own structured `gpu_fault` kind
  (`d3d12x/recovery.rs:110`).
- DRED is enabled before creation when opted in (`host.rs:1414`). A fence event
  at `UINT64_MAX` detects removal even if no more title calls arrive
  (`host.rs:6321`). Submission/present checks remain if event setup fails,
  and the exact setup failure is logged. This notification mechanism follows
  [Microsoft's removal notification guidance](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-getdeviceremovedreason).
- The callback owns copied DRED text before any teardown (`host.rs:530`). It
  includes operation names and list names where provided (`:6374`, `:9363`).
  History walks are cycle-bounded and the history ring is capped and rotated;
  wrapped history does not borrow `BreadcrumbCount` elements (`:6450`, `:9331`).
  This corrects an existing overread on lists exceeding 65,536 operations,
  matching [DRED's documented ring behavior](https://learn.microsoft.com/en-us/windows/win32/direct3d12/use-dred).
  The reported count is pending breadcrumb operations, **not** a precise count
  of simultaneously executing commands. Missing DRED/count is represented by
  empty diagnostic text / `null`, not invented zero activity.
- Each generation is a fresh `<title data>/recovery/snapshot-*` directory.
  Files are created exclusively, flushed, closed, reopened and fully hashed.
  A verified inventory and `COMPLETE` marker precede the publication rename
  (`victory-loader/src/recovery.rs:30`, `:105`). A failed generation remains
  `.partial`; earlier generations are never opened for writing or removed.
- RAM is streamed from a PSS VA clone in 1 MiB chunks with address, length,
  protection and memory-type records (`victory-loader/src/recovery.rs:164`).
  Guard protection is removed in the clone only. Uncommitted, inaccessible
  and execute-only regions are excluded; short/failed reads abort completion.
  PSS covers private RAM and shareable image/section mappings according to
  [the capture flag contract](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/ne-processsnapshot-pss_capture_flags).
  Shared pages can still change during capture. No thread/OS-handle rollback
  or GPU-only-state capture is claimed.
- Saves are copied under XGameSave's actual operation mutex (`xgamesave.rs:76`);
  lock contention is reported instead of waiting on a possibly faulting thread.
  RAM, DRED, saves and storage are attempted independently. If one fails,
  verified artifacts remain in `.partial`, their names appear in the event,
  and the generation is not published (`d3d12x/recovery.rs:21`). Storage and
  RAM are forensic copies, not a mutually quiesced checkpoint. Unsubmitted
  save updates and unsaved progress are not guaranteed recoverable.
- Exit `0xE0670001` means verified preservation with unsafe resume;
  `0xE0670002` means incomplete preservation. The one-line stderr instruction
  names the actual complete or partial recovery folder. One JSON line in
  `crashes.log` records timestamp, kind/reason, pending command count,
  preserved artifacts, attempted=false, attempts=0, cap=3, outcome, folder,
  error, DRED and fault (`d3d12x/recovery.rs:72`, `crash.rs:75`). Reporting
  failures are explicit on stderr. Concurrent GPU failures share one gate
  so another observer cannot kill the process during preservation (`:10`).

## Why live title resume is unsafe

`host.rs:558` exposes the device from a process-lifetime `OnceLock` as a static
reference. The pipeline library (`pipeline/library.rs:455`), title descriptor
heaps (`descriptor.rs:59`) and pipelines (`pipeline/make.rs:41`,
`pipeline/host.rs:538`) retain device-owned objects. A replacement device alone
would leave stale children. [D3D12CreateDevice's contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-d3d12createdevice)
also prevents recreation on the same adapter while the removed device is retained.

Removal is checked before GPU writes are handed back to CPU/title memory
(`host.rs:6259`, `:6279`). Intact CPU RAM therefore does not prove intact title
state. The current engine has no executable checkpoint/replay contract. The
safe exit is used rather than marking lost work complete or replaying unknown
side effects. A future live-resume implementation needs replaceable generations
for **all** device children, a quiescence protocol for title/I/O/save producers,
and a demonstrated safe CPU/GPU checkpoint with replay and fence semantics.
Only that path may consume the lifetime attempt budget (`removal.rs:40`).

## Every touched backend file

Patch references are clickable locations in this repository; source line numbers
refer to the reconstructed backend. New-file citations include its implementation
and tests. The companion report is this file; the shared record is
[`scarlett-log.md`](../scarlett-log.md).

| File / source locations | Purpose / patch location |
| --- | --- |
| `victory-gpu/src/watch.rs:1410` | Isolate the existing fresh-journal test; [0067-01](../native/patches/0067-01-write-watch-test-isolation.patch#L5). |
| `README.md:235` | Flag, artifacts, exit codes and limits; [0067-02:5](../native/patches/0067-02-removal-recovery.patch#L5). |
| `victory-gpu/src/host.rs:519,558,1414,6321,6351,6374,8864,9331,9363,9483` | Typed detection, notification, DRED copy/ring and regression; [0067-02:37](../native/patches/0067-02-removal-recovery.patch#L37). |
| `victory-gpu/src/lib.rs:26` | Module wiring; [0067-02:303](../native/patches/0067-02-removal-recovery.patch#L303). |
| `victory-gpu/src/removal.rs:5,11,16,25,40,56` | Opt-in, classifier, owned report, atomic attempt budget and tests; [0067-02:318](../native/patches/0067-02-removal-recovery.patch#L318). |
| `victory-gpu/src/removal_warp_tests.rs:27,61,139` | Isolated real removals, reconstruction, cap and flag routes; [0067-02:406](../native/patches/0067-02-removal-recovery.patch#L406). |
| `victory-hle/src/modules/d3d12x.rs:7,24,35,45` | Callback wiring and termination; [0067-02:679](../native/patches/0067-02-removal-recovery.patch#L679). |
| `victory-hle/src/modules/d3d12x/recovery.rs:10,21,72,110,139` | Failure gate, independent preservation, outcomes and child tests; [0067-02:731](../native/patches/0067-02-removal-recovery.patch#L731). |
| `victory-hle/src/modules/xgamesave.rs:76,82` | Save-copy locking and busy-save fixture; [0067-02:1004](../native/patches/0067-02-removal-recovery.patch#L1004). |
| `victory-loader/Cargo.toml:24` | Existing windows-sys PSS feature; no new dependency; [0067-02:1028](../native/patches/0067-02-removal-recovery.patch#L1028). |
| `victory-loader/src/crash.rs:75` | Serialized, flushed JSON event append; [0067-02:1040](../native/patches/0067-02-removal-recovery.patch#L1040). |
| `victory-loader/src/lib.rs:28,46` | Recovery and event exports; [0067-02:1065](../native/patches/0067-02-removal-recovery.patch#L1065). |
| `victory-loader/src/recovery.rs:30,67,105,164,290,311,344,356` | Verified files/copies, immutable publication, PSS RAM, JSON escaping and regressions; [0067-02:1088](../native/patches/0067-02-removal-recovery.patch#L1088). |

All source paths in the table start with backend `crates/` except its README.

## Acceptance evidence

- Launcher workspace `cargo test --locked`: **65 passed**, no title data.
- Default backend focused checks: **281 GPU, 113 HLE, 39 loader passed**;
  15 GPU tests ignored for their existing hardware/benchmark requirements.
- Diagnostics `cargo test --locked -p victory-gpu --features diagnostics --lib
  removal_warp_tests -- --test-threads=1 --nocapture`: **2 passed**. Real WARP
  `ID3D12Device5::RemoveDevice` events reached the opted-in asynchronous fence
  callback with no subsequent submission/present. Flag off reached the legacy
  callback. Three cycles released old COM objects, recreated the device,
  pipeline library and descriptor heap, then executed a queue/list/fence;
  the fourth and fifth budget requests were refused. Fixture cycle test: 0.03 s.
- A failed snapshot write leaves the previous RAM and `COMPLETE` bytes identical
  (`victory-loader/src/recovery.rs:311`). Busy-save child exits distinctly,
  preserves verified RAM/DRED/storage in `.partial`, retains the old generation
  and writes one escaped event line (`d3d12x/recovery.rs:139`).
- PSS fixture: **15,034,561 bytes**, captured/flushed/fully read back in
  **23.4026 ms**. The archive parser consumed every record to EOF, verified a
  guarded 4 KiB page's bytes and confirmed the live guard remained armed
  (`victory-loader/src/recovery.rs:356`). This is one synthetic measurement,
  not a title memory/disk-pressure timing. No frame-time delta is claimed.
- Initial full GPU/workspace attempts exposed the pre-existing fresh-journal
  test's address-reuse assumption (`watch.rs:1427` before 0067-01). Exact test
  and unchanged 0066 full GPU suite passed in fresh runs. 0067-01 preserves
  all original assertions in an isolated child with a 30-second timeout;
  production journaling is unchanged. No production lifetime-journal fix is
  implied by this test isolation.
- Complete series applies from pinned
  `f85101b6095e8cf3cecf8f0647cc7f5428daa177`; all **13 changed backend files**
  match the tested tree after CRLF normalization. Backend diff whitespace passes.
- The broader backend `cargo test --locked --workspace -- --test-threads=1`
  is **not green**: 227 shader tests passed, two rectangle tests failed and
  three were ignored. The failures are DXIL `Pipeline State Validation`
  mismatches at untouched `victory-shader/src/emit/rect.rs:339,442`.
  Running that rectangle group on unchanged 0066 reproduced both failures
  (one passed, two failed). They are recorded without expanding this removal
  change into shader translation work.

Hardware TDR, title-scale snapshot duration/space, readable archive contents on
real title memory, save restoration and retained unsaved progress remain
unverified. To validate preservation, run the title with the flag only after
backing up its data outside the repository, record the complete/partial folder
and event, verify every `COMPLETE` checksum, and restore committed saves only
into an isolated test data directory. Do not infer live resume from a WARP pass.
