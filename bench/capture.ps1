#requires -Version 7.0
<#
.SYNOPSIS
  Produce a reproducible capture set for the render gate. Protocol: bench/PROTOCOL.md ("Render gate").
  Compare sets with bench/render-verify.ps1.

.DESCRIPTION
  Launches the engine once, on a fresh copy of a fixed save and a fresh copy of a warm pipeline
  cache, replays VICTORY_KEYS (the scripted-input mechanism, so the camera path is identical every
  run), asks the engine for a fixed frame list through VICTORY_CAPTURE / VICTORY_CAPTURE_FRAMES and
  VICTORY_DUMP_TARGETS, waits until every requested frame has been written and has stopped growing,
  stops the engine, and stores the result as a set keyed by -Name:

    <OutDir>/<Name>/capture.json    sidecar: frames, save-tree / keys / engine hashes, env, command
                                    line, per-file SHA-256 manifest, status
    <OutDir>/<Name>/keys.txt        the replay script, verbatim
    <OutDir>/<Name>/capture/...     the engine's files, exactly as written
    <OutDir>/<Name>/engine.{out,err}.log

  A set is built in <Name>.partial-<pid> and renamed to <Name> only when every requested frame is
  present, intact and settled and the sidecar is on disk. A crashed or timed-out run is kept as
  <Name>.incomplete-<utc> with status 'incomplete': usable as a candidate (render-verify reports the
  holes, exit 3), never as a reference, and never under the name a reference would have.

  What is NOT verified from this repository (the fork's capture.rs and input module are not in the
  tree): the VICTORY_KEYS syntax, that VICTORY_DUMP_TARGETS takes a frame list, that the engine
  writes frame-<N>.png into the VICTORY_CAPTURE directory, and where dump targets land. Each is a
  parameter, recorded in the sidecar. Run -Mode SelfTest, then one real capture, then read the
  capture/ directory before trusting a set.

  Exit codes: 0 complete set | 2 usage or refusal | 3 cache cold (refused) | 4 incomplete capture
              (kept as .incomplete) | 5 environment (an engine is already running)
#>
[CmdletBinding()]
param(
    [ValidateSet('Capture', 'SelfTest')][string]$Mode = 'Capture',
    [string]$Name,                    # set name; never overwritten
    [string[]]$Frames,                # '128,256,512' (or several values); sorted, unique, >= 1
    [string]$Engine,
    [string]$Image,                   # the title's entry point; only its folder and path are used
    [string]$DataDir,                 # master copy of the fixed save; never written
    [string]$CacheDir,                # master copy of the warm cache; never written
    [string]$Keys,                    # VICTORY_KEYS verbatim
    [string]$KeysFile,                # file whose (trimmed) text is VICTORY_KEYS
    [string]$ConsoleProfile = 'series-x',
    [string]$DumpTargets,             # VICTORY_DUMP_TARGETS verbatim; default: the frame list, comma-joined
    [switch]$NoDumpTargets,           # leave VICTORY_DUMP_TARGETS unset
    [string]$FramePattern = 'frame-{0}.png',   # file the engine writes per requested frame (per docs/uma-0065.md:158)
    [string]$OutDir,                  # default bench/out/captures; must be gitignored if inside the repo
    [string]$ReplayFrom,              # an earlier set: reuse its frames, keys, profile, pattern, dump targets
    [object]$ExtraEnv,                # hashtable or 'NAME=VALUE' strings, e.g. VICTORY_UMA=0 for one arm
    [int]$TimeoutSec = 900,
    [int]$SettleSec = 5,              # all frames present and no file changing for this long
    [int]$MinRecipes = 1,
    [string]$Config                   # defaults to bench/heavy.local.psd1 (shared keys only)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ci = [System.Globalization.CultureInfo]::InvariantCulture
$BenchDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $BenchDir
$SchemaVersion = 1

function Stop-Capture([int]$Code, [string]$Message) {
    [Console]::Error.WriteLine("capture.ps1: $Message")
    exit $Code
}

# ---- machine-local defaults (the keys it shares with heavy.ps1) -------------------------------------
if (-not $Config) { $Config = Join-Path $BenchDir 'heavy.local.psd1' }
if (Test-Path -LiteralPath $Config) {
    $local = Import-PowerShellDataFile -LiteralPath $Config
    foreach ($k in 'Engine', 'Image', 'DataDir', 'CacheDir', 'Keys', 'KeysFile', 'ConsoleProfile', 'MinRecipes') {
        if ($local.ContainsKey($k) -and -not $PSBoundParameters.ContainsKey($k)) { Set-Variable -Name $k -Value $local[$k] }
    }
}
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $BenchDir 'out') 'captures' }

# ---- helpers ------------------------------------------------------------------------------------
function Get-Prop($Obj, [string]$Name, $Default = $null) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
    return $Default
}
function Get-FileSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-TextSha([string]$Text) { [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() }

function Write-AtomicText([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Frame list: any mix of commas, semicolons and whitespace; sorted, unique, every entry >= 1.
function ConvertTo-FrameList($Raw) {
    $set = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($tok in (([string]((@($Raw) | ForEach-Object { [string]$_ }) -join ',')) -split '[,;\s]+')) {
        if ($tok -eq '') { continue }
        $n = 0
        if (-not [int]::TryParse($tok, [ref]$n) -or $n -lt 1) { throw "bad frame number '$tok' (frames are whole numbers >= 1)" }
        [void]$set.Add($n)
    }
    if ($set.Count -eq 0) { throw 'the frame list is empty' }
    return , [int[]]@($set)
}

function ConvertTo-EnvMap($Raw) {
    $m = [ordered]@{}
    if ($null -eq $Raw) { return $m }
    if ($Raw -is [System.Collections.IDictionary]) { foreach ($k in $Raw.Keys) { $m[[string]$k] = [string]$Raw[$k] }; return $m }
    foreach ($item in @($Raw)) {
        $s = [string]$item; $i = $s.IndexOf('=')
        if ($i -lt 1) { throw "-ExtraEnv entry '$s' is not NAME=VALUE" }
        $m[$s.Substring(0, $i)] = $s.Substring($i + 1)
    }
    return $m
}

# Same algorithm as heavy.ps1's Get-TreeHash, so the value is comparable with its meta.json.
function Get-TreeHash([string]$Dir) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $base = (Resolve-Path -LiteralPath $Dir).Path
    foreach ($f in Get-ChildItem -LiteralPath $Dir -File -Recurse | Sort-Object FullName) {
        $rel = $f.FullName.Substring($base.Length).ToLowerInvariant()
        $line = [Text.Encoding]::UTF8.GetBytes("$rel $((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)`n")
        [void]$sha.TransformBlock($line, 0, $line.Length, $null, 0)
    }
    [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
    return [BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant()
}

function Copy-Tree([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    # /DCOPY:DAT keeps directory timestamps: the cache receipt records shaders/ creation time.
    & robocopy $From $To /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From -> $To" }
    $global:LASTEXITCODE = 0
}

# A cold cache compiles pipelines during play: draws are dropped, so the picture itself changes.
# Same checks as heavy.ps1's Test-WarmCache (see bench/PROTOCOL.md for the reasoning).
function Test-WarmCache([string]$Engine, [string]$Cache, [int]$MinRecipes) {
    $result = { param($ok, $why, $rec = -1) [pscustomobject]@{ Ok = $ok; Reason = $why; Recipes = $rec } }
    if (-not $Cache -or -not (Test-Path -LiteralPath $Cache -PathType Container)) { return & $result $false "cache directory not found: '$Cache'" }
    foreach ($d in 'pipelines', 'shaders') {
        if (-not (Test-Path -LiteralPath (Join-Path $Cache $d) -PathType Container)) { return & $result $false "no '$d' directory in the cache" }
    }
    $recipeDir = Join-Path $Cache 'pipelines/warm-v1'
    $recipes = if (Test-Path -LiteralPath $recipeDir) { @(Get-ChildItem -LiteralPath $recipeDir -File -Recurse).Count } else { 0 }
    if ($recipes -lt $MinRecipes) { return & $result $false "only $recipes recorded pipeline recipes in pipelines/warm-v1 (need >= $MinRecipes)" $recipes }
    if (-not (Test-Path -LiteralPath (Join-Path $Cache 'pipelines/precompiled-v1.txt'))) { return & $result $false 'no pipelines/precompiled-v1.txt receipt' $recipes }
    $out = & $Engine precompile --cache $Cache --check 2>&1 | Out-String
    if ($out -notmatch 'precompile-check\s+(\d+)') { return & $result $false "engine gave no 'precompile-check N' line: $($out.Trim())" $recipes }
    if ([int]$Matches[1] -ne 0) { return & $result $false "$($Matches[1]) of $recipes recipes have no published host pipeline for this engine build" $recipes }
    return & $result $true 'warm' $recipes
}

# Writing capture sets under the repo is only allowed where git ignores them: a capture is a picture
# of the title and must never become trackable (FORGE-BRIEF non-negotiable 2).
function Assert-OutputIgnored([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Stop-Capture 2 "cannot confirm '$full' is gitignored (git not found); use an -OutDir outside the repository" }
    & git -C $RepoRoot check-ignore -q -- $full
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; Stop-Capture 2 "'$full' is inside the repository and is not gitignored; refusing to write capture data there" }
    $global:LASTEXITCODE = 0
}

# A written frame must be whole before it can be a reference: PNGs must end in IEND, nothing may be empty.
function Test-CaptureFile([string]$Path) {
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -eq 0) { return 'empty file' }
    if ($Path -notmatch '\.png$') { return $null }
    if ($len -lt 20) { return 'too short to be a PNG' }
    $head = [byte[]]::new(8); $tail = [byte[]]::new(12)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        [void]$fs.Read($head, 0, 8)
        [void]$fs.Seek(-12, [IO.SeekOrigin]::End)
        [void]$fs.Read($tail, 0, 12)
    } finally { $fs.Dispose() }
    if (($head -join ',') -ne '137,80,78,71,13,10,26,10') { return 'bad PNG signature' }
    if (($tail -join ',') -ne '0,0,0,0,73,69,78,68,174,66,96,130') { return 'PNG ends without IEND (half-written)' }
    return $null
}

function Get-HostFacts {
    $gpu = try { Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion } catch { @() }
    [ordered]@{ host = $env:COMPUTERNAME; os = [Environment]::OSVersion.VersionString; gpus = @($gpu | ForEach-Object { "$($_.Name) $($_.DriverVersion)" }); pwsh = $PSVersionTable.PSVersion.ToString() }
}

# Launch with exactly $EnvSet (every inherited VICTORY_* / KELVAROQ_* removed first), poll the capture
# directory, stop the engine. Returns what happened; never decides pass/fail itself.
function Invoke-CaptureRun([string]$EnginePath, [string]$ImagePath, [string]$ProfileName, [string]$StageDir, [string]$CapDir, $EnvSet, [string[]]$Expected) {
    $saved = @{}
    foreach ($n in @([Environment]::GetEnvironmentVariables('Process').Keys) | Where-Object { $_ -match '^(VICTORY_|KELVAROQ_)' }) {
        $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
        Remove-Item -LiteralPath "Env:$n" -ErrorAction SilentlyContinue
    }
    $proc = $null
    $res = @{ Settled = $false; Exited = $false; ExitCode = $null; TimedOut = $false; Note = '' }
    try {
        try {
            foreach ($k in $EnvSet.Keys) { [Environment]::SetEnvironmentVariable([string]$k, [string]$EnvSet[$k], 'Process') }
            $proc = Start-Process -FilePath $EnginePath -ArgumentList @('run', ('"' + $ImagePath + '"'), '--console', $ProfileName, '--execute') `
                -WorkingDirectory (Split-Path -Parent $EnginePath) -PassThru -WindowStyle Minimized `
                -RedirectStandardOutput (Join-Path $StageDir 'engine.out.log') -RedirectStandardError (Join-Path $StageDir 'engine.err.log')
        } finally {
            foreach ($k in $EnvSet.Keys) { [Environment]::SetEnvironmentVariable([string]$k, $null, 'Process') }
            foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew(); $settle = [Diagnostics.Stopwatch]::new(); $lastSig = ''
        while ($true) {
            if ($proc.HasExited) { $res.Exited = $true; $res.ExitCode = $proc.ExitCode; $res.Note = "engine exited by itself (code $($res.ExitCode))"; break }
            $files = @(Get-ChildItem -LiteralPath $CapDir -File -Recurse -ErrorAction SilentlyContinue)
            $sig = (@($files | ForEach-Object { "$($_.FullName):$($_.Length)" } | Sort-Object)) -join '|'
            $missing = @($Expected | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
            if ($missing.Count -eq 0) {
                if ($sig -ne $lastSig) { $lastSig = $sig; $settle.Restart() }
                elseif ($settle.Elapsed.TotalSeconds -ge $SettleSec) { $res.Settled = $true; break }
            } else { $lastSig = ''; $settle.Reset() }
            if ($clock.Elapsed.TotalSeconds -gt $TimeoutSec) { $res.TimedOut = $true; $res.Note = "timed out after ${TimeoutSec}s waiting for $($missing.Count) frame file(s)"; break }
            Start-Sleep -Milliseconds 250
        }
    } finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true); [void]$proc.WaitForExit(15000) } catch { } }
    }
    return $res
}

function Remove-TreeQuietly([string]$Path) {
    for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $Path); $i++) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Seconds 1 }
    }
    if (Test-Path -LiteralPath $Path) { [Console]::Error.WriteLine("capture.ps1: WARNING could not remove $Path") }
}

# ---- self test ----------------------------------------------------------------------------------
function Invoke-SelfTest {
    $st = @{ fail = 0 }
    $check = { param($ok, $what) if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what" -ForegroundColor Red; $st.fail++ } }

    Write-Host 'parsing'
    & $check (((ConvertTo-FrameList '15,5, 10;5') -join ',') -eq '5,10,15') 'frame list is sorted and unique'
    & $check (((ConvertTo-FrameList @('3', '1,2')) -join ',') -eq '1,2,3') 'several values are merged'
    foreach ($bad in '0', 'x', '', '-4', '1,,a') {
        $threw = $false; try { [void](ConvertTo-FrameList $bad) } catch { $threw = $true }
        & $check $threw "frame list '$bad' is rejected"
    }
    & $check ((ConvertTo-EnvMap @('A=1', 'B=x=y')).B -eq 'x=y') 'NAME=VALUE keeps later ='
    & $check ((ConvertTo-EnvMap @{ A = 1 }).A -eq '1') 'hashtable form'

    Write-Host 'fake engine, full orchestration (no title data)'
    $pwsh = (Get-Process -Id $PID).Path
    $out = Join-Path (Join-Path $BenchDir 'out') "selftest-$PID"   # inside the repo on purpose: proves the gitignore guard accepts bench/out
    $fx = Join-Path $out 'fixture'
    $save = Join-Path $fx 'save'; $cache = Join-Path $fx 'cache'; $game = Join-Path $fx 'game'; $eng = Join-Path $fx 'engine'; $cold = Join-Path $fx 'cold'
    $sets = Join-Path $out 'sets'
    try {
        foreach ($d in $save, $game, $eng, $cold, $sets, (Join-Path $cache 'pipelines/warm-v1'), (Join-Path $cache 'shaders')) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Set-Content -LiteralPath (Join-Path $save 'slot0.sav') -Value 'save-A'
        Set-Content -LiteralPath (Join-Path $cache 'pipelines/warm-v1/r1') -Value 'x'
        Set-Content -LiteralPath (Join-Path $cache 'pipelines/precompiled-v1.txt') -Value 'receipt'
        Set-Content -LiteralPath (Join-Path $game 'game.exe') -Value 'not a real image'
        $keys = Join-Path $fx 'keys.txt'; Set-Content -LiteralPath $keys -Value "tap:A 10`n"
        @'
$a = $args
if ($a[0] -eq 'precompile') { 'precompile-check 0'; exit 0 }
$mode = if ($env:FAKE_MODE) { $env:FAKE_MODE } else { 'ok' }
'env: ' + ((Get-ChildItem Env: | Where-Object { $_.Name -like 'VICTORY_*' } | ForEach-Object { $_.Name } | Sort-Object) -join ',')
if (-not $env:VICTORY_KEYS) { exit 9 }
$cap = $env:VICTORY_CAPTURE
$sig = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
$iend = [byte[]](0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82)
$variant = if ($env:FAKE_VARIANT) { [int]$env:FAKE_VARIANT } else { 0 }
$n = 0
foreach ($f in ($env:VICTORY_CAPTURE_FRAMES -split ',')) {
    $n++
    $body = [byte[]](1..40 | ForEach-Object { ($_ + [int]$f + $variant) % 256 })
    $bytes = [byte[]]($sig + $body + $iend)
    if ($mode -eq 'half' -and $n -eq 2) { $bytes = [byte[]]($sig + $body) }
    [IO.File]::WriteAllBytes((Join-Path $cap "frame-$f.png"), $bytes)
    if ($env:VICTORY_DUMP_TARGETS -and (($env:VICTORY_DUMP_TARGETS -split ',') -contains $f)) { [IO.File]::WriteAllBytes((Join-Path $cap "dump-$f.bin"), [byte[]](1..20)) }
    if ($mode -eq 'crash' -and $n -eq 1) { exit 3 }
}
Start-Sleep -Seconds 600
'@ | Set-Content -LiteralPath (Join-Path $eng 'fake-engine.ps1') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $eng 'fake-engine.cmd') -Encoding ascii -Value "@echo off`r`npwsh -NoProfile -File `"%~dp0fake-engine.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
        $engine = Join-Path $eng 'fake-engine.cmd'; $image = Join-Path $game 'game.exe'; $noCfg = Join-Path $fx 'no-such.psd1'

        # Runs this script as a child process. $Over replaces a default; a $null value removes it.
        $common = { param([string]$N, [hashtable]$Over = @{})
            $p = [ordered]@{ Name = $N; Frames = '15,5,10,5'; Engine = $engine; Image = $image; DataDir = $save; CacheDir = $cache; OutDir = $sets; SettleSec = '1'; TimeoutSec = '90'; Config = $noCfg }
            foreach ($k in $Over.Keys) { if ($null -eq $Over[$k]) { $p.Remove($k) } else { $p[$k] = $Over[$k] } }
            $argv = @('-NoProfile', '-File', $PSCommandPath)
            foreach ($k in $p.Keys) { $argv += "-$k"; $argv += [string]$p[$k] }
            $o = & $pwsh @argv 2>&1 | Out-String
            @{ Code = $LASTEXITCODE; Out = $o } }
        $env:VICTORY_UMA = '1'   # inherited setting that the run must strip
        try {
            $r = & $common 'a' @{ KeysFile = $keys }
            & $check ($r.Code -eq 0) "complete capture exits 0 ($($r.Code))"
            if ($r.Code -ne 0) { Write-Host $r.Out }
            $a = Join-Path $sets 'a'
            & $check (Test-Path -LiteralPath (Join-Path $a 'capture.json')) 'set is promoted to its final name with a sidecar'
            & $check (@(Get-ChildItem -LiteralPath $sets -Directory | Where-Object { $_.Name -match '^a\.(partial|work)' }).Count -eq 0) 'no staging or work directory is left behind'
            $m = if (Test-Path -LiteralPath (Join-Path $a 'capture.json')) { Get-Content -LiteralPath (Join-Path $a 'capture.json') -Raw | ConvertFrom-Json } else { $null }
            if ($m) {
                & $check ($m.status -eq 'complete' -and (@($m.frames) -join ',') -eq '5,10,15' -and $m.frame_count -eq 3) 'sidecar: complete, frames 5,10,15'
                & $check (@($m.files).Count -eq 6) 'sidecar manifest: 3 frames + 3 dump targets'
                & $check ($m.keys_sha256 -eq (Get-TextSha 'tap:A 10') -and $m.save_tree_sha256 -eq (Get-TreeHash $save)) 'sidecar: keys and save-tree hashes'
                & $check ($m.dump_targets -eq '5,10,15' -and $m.frame_pattern -eq 'frame-{0}.png') 'sidecar: dump targets default to the frame list; pattern recorded'
                & $check (-not [string]::IsNullOrEmpty($m.invocation)) 'sidecar: invocation recorded'
            }
            $log = Get-Content -LiteralPath (Join-Path $a 'engine.out.log') -Raw -ErrorAction SilentlyContinue
            & $check ($log -match 'VICTORY_CAPTURE' -and $log -notmatch 'VICTORY_UMA') 'engine saw its VICTORY_* settings and not the inherited VICTORY_UMA'
            & $check ((Get-Content -LiteralPath (Join-Path $a 'keys.txt') -Raw).Trim() -eq 'tap:A 10') 'keys.txt stored verbatim'
            & $check ((Get-Content -LiteralPath (Join-Path $save 'slot0.sav') -Raw).Trim() -eq 'save-A') 'master save untouched'

            $r = & $common 'a' @{ KeysFile = $keys }; & $check ($r.Code -eq 2 -and $r.Out -match 'already exists') 'an existing name is never overwritten (exit 2)'
            $r = & $common 'b'; & $check ($r.Code -eq 2 -and $r.Out -match 'scripted input') 'no keys is refused (exit 2)'
            $r = & $common 'b' @{ KeysFile = $keys; CacheDir = $cold }; & $check ($r.Code -eq 3) 'cold cache is refused (exit 3)'
            $r = & $common '../x' @{ KeysFile = $keys }; & $check ($r.Code -eq 2) 'a name with path characters is refused'
            $r = & $common 'g' @{ KeysFile = $keys; OutDir = (Join-Path $RepoRoot 'bench/selftest-not-ignored') }
            & $check ($r.Code -eq 2 -and $r.Out -match 'not gitignored|cannot confirm' -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot 'bench/selftest-not-ignored'))) 'an un-ignored directory inside the repo is refused and not created'
            $r = & $common 'e' @{ KeysFile = $keys; ExtraEnv = 'VICTORY_CAPTURE=elsewhere' }; & $check ($r.Code -eq 2) 'ExtraEnv may not override the capture switches'

            $env:FAKE_MODE = 'crash'
            $r = & $common 'c' @{ KeysFile = $keys }
            & $check ($r.Code -eq 4) "a crashed engine exits 4 ($($r.Code))"
            & $check (-not (Test-Path -LiteralPath (Join-Path $sets 'c'))) 'a crashed run never appears under the final name'
            $inc = @(Get-ChildItem -LiteralPath $sets -Directory -Filter 'c.incomplete-*')
            & $check ($inc.Count -eq 1) 'it is kept as <name>.incomplete-<utc>'
            if ($inc.Count -eq 1) {
                $cm = Get-Content -LiteralPath (Join-Path $inc[0].FullName 'capture.json') -Raw | ConvertFrom-Json
                & $check ($cm.status -eq 'incomplete' -and (@($cm.missing) -contains 'frame-10.png')) 'incomplete sidecar lists the missing frames'
            }
            $env:FAKE_MODE = 'half'
            $r = & $common 'h' @{ KeysFile = $keys }
            & $check ($r.Code -eq 4 -and -not (Test-Path -LiteralPath (Join-Path $sets 'h'))) 'a half-written PNG makes the set incomplete, not a reference'
            $env:FAKE_MODE = $null

            $rp = & $common 'r' @{ ReplayFrom = $a; Frames = $null }
            & $check ($rp.Code -eq 0) 'replay from a sidecar needs no frames and no keys'
            if (Test-Path -LiteralPath (Join-Path $sets 'r/capture.json')) {
                $rm = Get-Content -LiteralPath (Join-Path $sets 'r/capture.json') -Raw | ConvertFrom-Json
                & $check ((@($rm.frames) -join ',') -eq '5,10,15' -and $rm.keys_sha256 -eq $m.keys_sha256 -and $rm.save_tree_sha256 -eq $m.save_tree_sha256) 'replayed set has the same frames, keys hash and save hash'
            } else { & $check $false 'replayed set exists'; Write-Host $rp.Out }
            $save2 = Join-Path $fx 'save2'; New-Item -ItemType Directory -Force -Path $save2 | Out-Null; Set-Content -LiteralPath (Join-Path $save2 'slot0.sav') -Value 'save-B'
            $rp2 = & $common 'r2' @{ ReplayFrom = $a; Frames = $null; DataDir = $save2 }
            & $check ($rp2.Code -eq 2 -and $rp2.Out -match 'not the same save') 'replay on a different save is refused'

            $rv = Join-Path $BenchDir 'render-verify.ps1'
            if (Test-Path -LiteralPath $rv) {
                Write-Host 'cross-check with render-verify.ps1'
                $verify = { param($ref, $cand) & $pwsh -NoProfile -File $rv -Reference $ref -Candidate $cand -CapturesDir $sets -ReportPath (Join-Path $out 'rep.md') 2>&1 | Out-Null; $LASTEXITCODE }
                & $check ((& $verify 'a' 'r') -eq 0) 'two captures of the same inputs verify identical (exit 0)'
                $env:FAKE_VARIANT = '1'
                $null = & $common 'v' @{ KeysFile = $keys }
                $env:FAKE_VARIANT = $null
                & $check ((& $verify 'a' 'v') -eq 2) 'a capture with different bytes verifies as blocking (exit 2)'
                & $check ((& $verify 'a' $inc[0].Name) -eq 3) 'the crashed set verifies as missing frames (exit 3)'
                & $check ((& $verify $inc[0].Name 'a') -eq 4) 'the crashed set is refused as a reference (exit 4)'
            } else { Write-Host '  skip render-verify.ps1 not found' }
        } finally { $env:VICTORY_UMA = $null; $env:FAKE_MODE = $null; $env:FAKE_VARIANT = $null }
    } finally { Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue }
    if ($st.fail) { Write-Host "$($st.fail) self-test failure(s)" -ForegroundColor Red; exit 1 }
    Write-Host 'self-test passed'
    exit 0
}

# ---- entry --------------------------------------------------------------------------------------
if ($Mode -eq 'SelfTest') { Invoke-SelfTest }

# Replay: take the invocation's *inputs* from an earlier set. Engine, paths and ExtraEnv are not
# inherited: the point of a replay is a different build (or arm) on the same inputs.
$replayMeta = $null
if ($ReplayFrom) {
    $rdir = if (Test-Path -LiteralPath $ReplayFrom -PathType Container) { $ReplayFrom } else { Join-Path $OutDir $ReplayFrom }
    $rjson = Join-Path $rdir 'capture.json'
    if (-not (Test-Path -LiteralPath $rjson)) { Stop-Capture 2 "-ReplayFrom: no capture.json in '$rdir'" }
    $replayMeta = Get-Content -LiteralPath $rjson -Raw | ConvertFrom-Json
    foreach ($k in 'Frames', 'Keys', 'KeysFile', 'DumpTargets', 'NoDumpTargets', 'FramePattern', 'ConsoleProfile') {
        if ($PSBoundParameters.ContainsKey($k)) { Stop-Capture 2 "-$k conflicts with -ReplayFrom (the replay reuses the original's value)" }
    }
    $Frames = @(@(Get-Prop $replayMeta 'frames' @()) | ForEach-Object { [string]$_ })
    $keysTxt = Join-Path $rdir 'keys.txt'
    if (-not (Test-Path -LiteralPath $keysTxt)) { Stop-Capture 2 "-ReplayFrom: no keys.txt in '$rdir'" }
    $Keys = (Get-Content -LiteralPath $keysTxt -Raw).Trim()
    $FramePattern = [string](Get-Prop $replayMeta 'frame_pattern' $FramePattern)
    $ConsoleProfile = [string](Get-Prop $replayMeta 'console_profile' $ConsoleProfile)
    $rdump = Get-Prop $replayMeta 'dump_targets'
    if ($null -eq $rdump) { $NoDumpTargets = [switch]$true } else { $DumpTargets = [string]$rdump }
}

# ---- validate arguments -------------------------------------------------------------------------
if (-not $Name -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Name -match '\.\.' ) { Stop-Capture 2 "-Name is required and may contain only letters, digits, '.', '_' and '-' (got '$Name')" }
foreach ($p in 'Engine', 'Image', 'DataDir', 'CacheDir') { if (-not (Get-Variable $p -ValueOnly)) { Stop-Capture 2 "-$p is required (or set it in bench/heavy.local.psd1)" } }
if (-not (Test-Path -LiteralPath $Engine)) { Stop-Capture 2 "engine not found: $Engine" }
if (-not (Test-Path -LiteralPath $Image)) { Stop-Capture 2 "image not found: $Image" }
if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) { Stop-Capture 2 "save directory not found: $DataDir" }
try { $frameList = ConvertTo-FrameList $Frames } catch { Stop-Capture 2 "-Frames: $($_.Exception.Message)" }
if ($FramePattern -notmatch '\{0\}' -or $FramePattern -match '[\\/]|\.\.') { Stop-Capture 2 "-FramePattern must contain {0} and no path separators (got '$FramePattern')" }
try { $extraEnv = ConvertTo-EnvMap $ExtraEnv } catch { Stop-Capture 2 "-ExtraEnv: $($_.Exception.Message)" }
$reserved = 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR', 'VICTORY_CAPTURE', 'VICTORY_CAPTURE_FRAMES', 'VICTORY_DUMP_TARGETS', 'VICTORY_KEYS'
foreach ($k in $extraEnv.Keys) { if ($k -in $reserved) { Stop-Capture 2 "-ExtraEnv may not set ${k}: the script owns it" } }
if ($Keys) { $keysValue = $Keys.Trim() }
elseif ($KeysFile) {
    if (-not (Test-Path -LiteralPath $KeysFile)) { Stop-Capture 2 "keys file not found: $KeysFile" }
    $keysValue = (Get-Content -LiteralPath $KeysFile -Raw).Trim()
} else { $keysValue = $null }
if (-not $keysValue) { Stop-Capture 2 'no scripted input: give -Keys or -KeysFile (VICTORY_KEYS). A capture without a fixed camera path cannot be compared.' }
$dumpValue = if ($NoDumpTargets) { $null } elseif ($PSBoundParameters.ContainsKey('DumpTargets') -or $DumpTargets) { $DumpTargets } else { ($frameList -join ',') }

if (@(Get-Process -Name 'kelvaroq-engine', 'victory' -ErrorAction SilentlyContinue).Count) { Stop-Capture 5 'an engine process is already running; a capture needs the machine to itself' }

# The script owns VICTORY_* / KELVAROQ_*: strip whatever the calling shell inherited so a stray
# setting cannot silently change a run. -ExtraEnv is applied afterwards, on purpose.
foreach ($n in @([Environment]::GetEnvironmentVariables('Process').Keys) | Where-Object { $_ -match '^(VICTORY_|KELVAROQ_)' }) {
    Remove-Item -LiteralPath "Env:$n" -ErrorAction SilentlyContinue
}

Assert-OutputIgnored $OutDir
$final = Join-Path $OutDir $Name
if (Test-Path -LiteralPath $final) { Stop-Capture 2 "capture set '$Name' already exists at $final (sets are never overwritten)" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$gate = Test-WarmCache $Engine $CacheDir $MinRecipes
if (-not $gate.Ok) { Stop-Capture 3 "REFUSING TO RUN: cache is cold. $($gate.Reason). A cold cache drops draws, which changes the picture. Run: heavy.ps1 -Mode Warm -Engine ... -CacheDir ..." }

$saveHash = Get-TreeHash $DataDir
if ($replayMeta -and (Get-Prop $replayMeta 'save_tree_sha256') -ne $saveHash) {
    Stop-Capture 2 "-ReplayFrom: this save's tree hash ($($saveHash.Substring(0, 12))) is not the original's ($(([string](Get-Prop $replayMeta 'save_tree_sha256' '')).PadRight(12).Substring(0, 12))); not the same save"
}
$engineSha = Get-FileSha $Engine
$stage = Join-Path $OutDir "$Name.partial-$PID"
$work = Join-Path $OutDir "$Name.work-$PID"
$capDir = Join-Path $stage 'capture'
$started = (Get-Date).ToUniversalTime()
$committed = $false

try {
    New-Item -ItemType Directory -Force -Path $capDir | Out-Null
    Write-Host "capture ${Name}: copying the save and the warm cache"
    $runData = Join-Path $work 'data'; $runCache = Join-Path $work 'cache'
    Copy-Tree $DataDir $runData; Copy-Tree $CacheDir $runCache
    $copyGate = Test-WarmCache $Engine $runCache $MinRecipes
    if (-not $copyGate.Ok) { Stop-Capture 3 "REFUSING TO RUN: the fresh copy of the cache is cold ($($copyGate.Reason)); the copy lost the receipt's timestamps." }

    $envSet = [ordered]@{
        VICTORY_GAME_DIR       = (Split-Path -Parent (Resolve-Path -LiteralPath $Image).Path)
        VICTORY_CACHE_DIR      = $runCache
        VICTORY_DATA_DIR       = $runData
        VICTORY_CAPTURE        = $capDir
        VICTORY_CAPTURE_FRAMES = ($frameList -join ',')
        VICTORY_KEYS           = $keysValue
    }
    if ($null -ne $dumpValue) { $envSet['VICTORY_DUMP_TARGETS'] = $dumpValue }
    foreach ($k in $extraEnv.Keys) { $envSet[$k] = $extraEnv[$k] }
    $expectedNames = @($frameList | ForEach-Object { $FramePattern -f $_ })
    $expected = @($expectedNames | ForEach-Object { Join-Path $capDir $_ })

    Write-Host "capture ${Name}: frames $($frameList -join ',') (timeout ${TimeoutSec}s)"
    $run = Invoke-CaptureRun $Engine (Resolve-Path -LiteralPath $Image).Path $ConsoleProfile $stage $capDir $envSet $expected
    Remove-TreeQuietly $work

    # ---- judge the run ----------------------------------------------------------------------
    $missing = @($expectedNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $capDir $_) -PathType Leaf) })
    $corrupt = [System.Collections.Generic.List[string]]::new()
    $base = (Resolve-Path -LiteralPath $capDir).Path.TrimEnd('\', '/')
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $capDir -File -Recurse | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
        $bad = Test-CaptureFile $f.FullName
        if ($bad) { $corrupt.Add("${rel}: $bad") }
        $entries.Add([ordered]@{ path = $rel; bytes = $f.Length; sha256 = (Get-FileSha $f.FullName) })
    }
    $ranOk = $run.Settled -or ($run.Exited -and $run.ExitCode -eq 0)
    $complete = ($missing.Count -eq 0 -and $corrupt.Count -eq 0 -and $ranOk)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($run.Note) { $reasons.Add($run.Note) }
    if ($missing.Count) { $reasons.Add("missing: $($missing -join ', ')") }
    foreach ($c in $corrupt) { $reasons.Add("corrupt: $c") }
    if (-not $ranOk -and -not $run.Note) { $reasons.Add('engine did not finish the capture') }

    Set-Content -LiteralPath (Join-Path $stage 'keys.txt') -Value $keysValue -Encoding utf8
    $meta = [ordered]@{
        schema           = $SchemaVersion
        name             = $Name
        status           = if ($complete) { 'complete' } else { 'incomplete' }
        reasons          = @($reasons)
        utc              = $started.ToString('o')
        tool             = 'bench/capture.ps1'
        frames           = [int[]]$frameList
        frame_count      = $frameList.Count
        frame_pattern    = $FramePattern
        dump_targets     = $dumpValue
        console_profile  = $ConsoleProfile
        save_tree_sha256 = $saveHash
        keys_sha256      = (Get-TextSha $keysValue)
        keys_file        = 'keys.txt'
        engine           = $Engine
        engine_sha256    = $engineSha
        cache_recipes    = $gate.Recipes
        env              = $envSet
        extra_env        = $extraEnv
        replay_of        = if ($ReplayFrom) { [string]$ReplayFrom } else { $null }
        invocation       = [Environment]::CommandLine
        settle_sec       = $SettleSec
        missing          = @($missing)
        corrupt          = @($corrupt)
        files            = @($entries)
        facts            = Get-HostFacts
    }
    # The sidecar is written last: a directory without capture.json is a run that died before it finished.
    Write-AtomicText (Join-Path $stage 'capture.json') ((ConvertTo-Json -InputObject $meta -Depth 8) + "`n")

    if ($complete) {
        if (Test-Path -LiteralPath $final) { Stop-Capture 2 "'$final' appeared while capturing; left as $stage" }
        Move-Item -LiteralPath $stage -Destination $final
        $committed = $true
        Write-Host "capture ${Name}: complete, $($entries.Count) file(s) -> $final"
        exit 0
    }
    $kept = "$final.incomplete-$($started.ToString('yyyyMMddTHHmmssZ'))"
    Move-Item -LiteralPath $stage -Destination $kept
    $committed = $true
    [Console]::Error.WriteLine("capture.ps1: INCOMPLETE: $($reasons -join '; ')")
    [Console]::Error.WriteLine("capture.ps1: kept as $kept (valid only as a candidate; never a reference)")
    exit 4
} catch {
    [Console]::Error.WriteLine("capture.ps1: unexpected failure: $($_.Exception.Message)")
    [Console]::Error.WriteLine("capture.ps1: partial output left at $stage (it never took the name '$Name')")
    exit 4
} finally {
    # The multi-GB save/cache copies always go. A run that failed before committing keeps its
    # <name>.partial-<pid> directory for diagnosis; it never held the final name.
    if (Test-Path -LiteralPath $work) { Remove-TreeQuietly $work }
}

