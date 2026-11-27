# RUNBOOK

Operating notes for the SCARLETT layer. Read `FORGE-BRIEF.md` for the technical ground truth.
The title is build `1.0.2.1`, entry `game_scarlett_master.exe`.

Nothing here is authorised by the vendor of the title. Never ship game data in the tree.

## 0. Before the first run

| Need | Why |
|---|---|
| Windows 10/11 x64, AVX2 CPU | the title's own x86-64 code runs in-process |
| D3D12 GPU, shader model 6.6, mesh shaders | the world path uses mesh pipelines |
| 32 GB RAM, **80 GB commit limit** | a world run commits ~33 GB and ~10 GB VRAM |
| 16 GB+ VRAM recommended | 12 GB is the floor; 8 GB drops head and skin meshes |
| ~215 GB free for the files | the dump preallocates |

Check **Committed** under Task Manager → Performance → Memory. If the machine cannot commit
80 GB, raise the paging file before starting, or the run dies with Windows error 1455.

## 1. Getting the files

The only trustworthy path: the torrent announcement page, then a torrent client. Public mirrors
of the *runtime* are safe to use; a single small `.exe` claiming to install the title is not.

- Keep the `.torrent`/magnet and the client's resume control file. Do not delete the control file
  to "restart cleanly" — it is what resumes.
- Verify the executable archive against the SHA-256 the announcer published before trusting it.
  A matching hash proves integrity, not authorship.
- Expect the repositories to be taken down and re-uploaded. Keep a local copy of any runtime you
  validated; do not rely on the fork still existing tomorrow.

## 2. First launch

1. Extract the runtime somewhere short, e.g. `C:\vt`. Long paths break `blake3`'s build script
   with `A1009: line too long` even with long paths enabled.
2. Point the config at the game directory. Nothing about the title belongs in the repo.
3. Precompile before playing: `translate --cache --pipelines`. This is minutes to hours and is
   the difference between playing and watching dropped draws.
4. First run only: expect a long shader warm. Leave it.

## 3. Failure modes

### Cold pipeline cache
Symptom: low fps, visibly missing geometry and materials, `dropped` counters high.
Cause: pipelines built during play, draws dropped until they exist.
Fix: run the precompile again. `bench/heavy.ps1` and `bench/capture.ps1` both refuse a cold cache
for this reason (exit 3) — a number measured cold is not comparable.

### Windows error 1455 (commit exhaustion)
Symptom: dies on world load, `crashes.log` names 1455.
Cause: not enough RAM + pagefile commit.
Fix: close everything, raise the paging file, retry. Do not "fix" it by lowering budgets until
it stops crashing — that only hides it.

### GPU device removal (TDR)
Symptom: every monitor goes black for a moment, run ends.
This is the known bad case. With `VICTORY_RECOVER_REMOVAL=1` the layer should detect it, preserve
a snapshot and exit distinctly rather than dying silently. Read the snapshot folder it names.
Snapshots are **forensic, not save states** — they are for diagnosis, not for resuming play.
Three removals in a row means a real fault, not bad luck; capture `crashes.log` and stop.

### Missing ray-traced structures
Symptom: no ray-traced shadows or indirect light; indoor scenes flat or wrongly lit.
Cause: the title's ray-tracing structures are not built unless the RT path is on.
This is a correctness gap, not a bug in the run. Do not tune around it.

### Plateau at 1-10 fps
Check in this order: is the cache warm (3), is anything else holding the GPU, is
`VICTORY_UMA` actually on, are `drop_*` counters near zero. A low fps with clean counters is the
submission path, and belongs in `docs/submission.md`, not in the settings.

## 4. Verifying a build before trusting it

```powershell
pwsh -File bench\heavy.ps1   -Mode SelfTest      # harness itself is sane
pwsh -File bench\capture.ps1 -Mode SelfTest
pwsh -File bench\render-verify.ps1 -Mode SelfTest
```

Then, for a candidate runtime: `Get-FileHash` the archive against the published digest, scan it,
and confirm the only outbound call is the update check to `api.github.com`.

A perf patch lands only if `render-verify` returns 0 or 1 against the reference. 2 or 3 blocks the
merge no matter what the frame time did.

## 5. Legal posture, briefly

The runtime contains no title code or assets and does not unlock anything; it runs a copy the
operator supplies. The repositories are GPL-3.0. The title's own terms are the operator's problem,
not the layer's.

## 6. When to stop and ask

- A removal repeats at the same place three times.
- `render-verify` says structural on a patch that was supposed to be a pure speedup.
- The save does not survive a clean exit.
- Anything needs a human at the keyboard: driving the prologue, judging whether a scene looks
  right, confirming a mission is completable.
