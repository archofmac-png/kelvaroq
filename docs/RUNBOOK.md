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
3. Run `kelvaroq-desktop.exe --first-run <game folder or exe>` (section 2c). It does the precompile
   for you, in the right order, and refuses to launch on a cold cache. This is minutes to hours and
   is the difference between playing and watching dropped draws.
4. First run only: expect a long shader warm. Leave it. Ctrl+C is safe; run the same command again.

## 2b. Preflight and doctor

The launcher refuses to start when a blocking check fails, with a one-line fix. Blocking: commit
limit < 80 GiB, VRAM < 12 GiB, no FL 12_0 / SM 6.6 / mesh shaders, game directory or `appdata0.rpf`
missing, cold pipeline cache (file checks as in `bench/heavy.ps1`), another engine running.
Advisory (warn only): RAM < 32 GiB, driver older than 6 months, no XInput pad, non-ASCII path.
12-16 GiB VRAM warns.

`VICTORY_SKIP_PREFLIGHT=1` overrides the blocking set (only the exact value `1`); the launcher
prints which checks it overrode.

`kelvaroq-desktop.exe --doctor [exe-or-folder]` runs every check, prints a table, never launches,
and exits 0 (nothing blocks) or 2 (something blocks). The launcher is a windows-subsystem exe, so
a shell does not wait for it: use `Start-Process -Wait -PassThru` or `cmd /c start /wait`.

## 2c. First run

`kelvaroq-desktop.exe --first-run [folder-or-exe]` (no argument: the executable saved in settings).
The launcher is a windows-subsystem exe: use `Start-Process -Wait -PassThru` to get the exit code.

1. Resolve: a folder resolves to the one executable `MicrosoftGame.Config` declares for Scarlett.
   Zero or several declared is a refusal that names them; pass the executable you mean.
2. Preflight, the same checks as `--doctor`, before the cache is touched. A cold cache is shown but
   is not what stops it; every other blocking check is. `VICTORY_SKIP_PREFLIGHT=1` works as usual.
3. Precompile: translate every shader, then queue and build the pipelines. Progress and an ETA from
   the rate this run measured. Finished steps are recorded in `<cache>\first-run-v1.json`.
4. Verify with the check `bench/heavy.ps1` uses (file checks, then `precompile --check` must say 0).
   A cold result refuses to launch.
5. Launch, once.

A second run on a warm cache does 1, 2 and 4 and launches; it compiles nothing and writes nothing.
Nothing in the cache is ever deleted. Exit codes: 0 launched, game exited clean | 1 unexpected |
2 refused before any work | 3 cache still cold (not launched) | 4 an engine step failed |
5 game exited non-zero | 130 interrupted. 3, 4 and 130 resume on the next run.

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
