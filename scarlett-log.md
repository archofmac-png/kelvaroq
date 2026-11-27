# SCARLETT — session log
Advisory record — re-verify mutable facts live. Newest first. Shared by Claude and Codex.

## NOW (as of 2026-11-26)
Private buffer reads remain default; constants and pool slabs require explicit opt-in.
Constant rebinding uses immutable flight snapshots; mutable-page CBVs were removed.
Title timing, capture comparison and hardware-vendor costs remain unverified.
Broader diagnostics depth-bounds/stack-walker issues from 0065 remain unresolved.
Current response and checks: [Lane A round 2](docs/uma-0066.md).
External-data measurement protocol remains in [0065](docs/uma-0065.md).

## Sessions

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
