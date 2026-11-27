# SCARLETT — session log
Advisory record — re-verify mutable facts live. Newest first. Shared by Claude and Codex.

## NOW (as of 2026-11-26)
Private buffer reads remain default; constants and pool slabs require explicit opt-in.
Constant rebinding uses immutable flight snapshots; mutable-page CBVs were removed.
Title timing, capture comparison and hardware-vendor costs remain unverified.
Broader diagnostics depth-bounds/stack-walker issues from 0065 remain unresolved.
Blocked-time counters landed; prefix settle is default-off: [0073](docs/submission-0073.md).
External-data measurement protocol remains in [0065](docs/uma-0065.md).
Removal preservation is opt-in; live title resume remains unsupported.
Removal checks and limits: [0069](docs/removal-0069.md); suspended forensic capture only.

## Sessions

### 2026-11-26 (6) — Exposed blockers before gated prefix settlement
<!-- session: lane-a-0073-20261126-5e8a -->
- DONE: Ordered 0073 patches; 66 product, 293 GPU tests and 10 focused WARP checks passed; series matches. [Evidence](docs/submission-0073.md).
- DECIDED: Default-off prefix; retain writers through publication; incomplete sets use full settle.
- UNVERIFIED: Title timing/captures; workspace shader/policy and Clippy baseline failures remain.
- NEXT: Three matched 300-second runs per arm and separate deterministic captures before enablement.

### 2026-11-26 (5) — Repaired forensic deadline arithmetic and hashing
<!-- session: lane-a-0069-20261126-c728 -->
- DONE: Patch 0069; 66 root, 282 GPU, 113 HLE, 43 loader tests; production check and series match. [Evidence](docs/removal-0069.md).
- DECIDED: 300 ms floor; measured startup; separate read-back hash budget; work/parent/helper deadlines B-200/B-125/B-25 ms.
- UNVERIFIED: Title frame cost and arbitrary OS stalls; no live resume.
- NEXT: Measure title inventory and matched flag-off/on frame costs before enablement.

### 2026-11-26 (4) — Bounded suspended forensic capture and real removal dispatch
<!-- session: lane-a-0068-20261126-91bf -->
- DONE: 65 launcher, 282 GPU, 113 HLE, 41 loader and 8 diagnostics checks passed; series matched. See [0068](docs/removal-0068.md).
- DECIDED: Separate helper, PARTIAL-first streaming hashes, 2-second budget; breadcrumbs require subflag. Real dispatch capped at three.
- UNVERIFIED: Title-scale completion, frame costs, unsaved progress. Existing broader-suite issues remain.
- NEXT: Measure title inventory/watchdog interval and mode costs before enablement.

### 2026-11-26 (3) — Added default-off removal preservation and safe exit
<!-- session: lane-a-0067-20261126-7e43 -->
- DONE: 65 launcher, 281 GPU, 113 HLE, 39 loader and 7 removal checks passed; series verified. See [report](docs/removal-0067.md).
- DECIDED: Verified forensic generations; unsafe-resume exit. Live title resume remains unsupported.
- UNVERIFIED: Unsaved progress retention. Two broad-suite rectangle-validator failures reproduce on unchanged 0066.
- NEXT: Establish replayable CPU/GPU checkpoints before live resume.

### 2026-11-26 (2) — Repaired constant overlap and re-gated pool commitment
<!-- session: lane-a-0066-20261126-b5c4 -->
- DONE: 65 repository, 278 GPU and 112 HLE tests passed; backend defaults and legacy passed. The overwrite regression fails on 0065 and passes on 0066; commit exhaustion falls back uncharged.
- DECIDED: Immutable flight snapshots; private constants/pool opt-in. Opening private heaps prevented guard protection.
- UNVERIFIED: Title timing/pixels and hardware-vendor costs. See [response](docs/uma-0066.md).
- NEXT: External-data timing/capture comparison before enabling either policy.

### 2026-11-26 — Defaulted UMA and verified residency accounting
<!-- session: lane-a-uma-0065-20261126-8f1d -->
- DONE: Three reversible subpatches; 65 repository, 278 GPU, 111 HLE and 11 focused WARP tests passed. Legacy opt-out passed.
- DECIDED: Removed unused placed-view generations; retained all correctness copy fallbacks. See [audit](docs/uma-0065.md).
- UNVERIFIED: Title timing/pixels; broader diagnostics has a baseline depth-bounds failure and intermittent stack-walker crash.
- NEXT: Run the report’s external-data measurement protocol.

## Older
