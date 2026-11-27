#requires -Version 7.0
<#
.SYNOPSIS
  Heavy-scene benchmark for SCARLETT. Protocol: bench/PROTOCOL.md.

.DESCRIPTION
  Run      Launch the engine once per run on a fresh copy of a fixed save and a fresh copy of a
           warm pipeline cache, replay VICTORY_KEYS, read the built-in frame monitor (the
           KelvaroqStats shared-memory ring) for -Duration seconds, write CSV, print median and p95
           of heavy frames. With -Baseline, print the delta and exit 1 on regression > -Threshold %.
  Compare  No launch. Compare -Current against -Baseline.
  Warm     Build the pipelines recorded in -CacheDir (engine `precompile`), then verify it is warm.
  SelfTest Synthetic checks of the statistics, the comparison gate, the ring reader and the
           cold-cache refusal. Needs no engine and no game data.

  Exit codes: 0 ok | 1 regression | 2 usage | 3 cache cold (refused) | 4 invalid run | 5 environment
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Compare', 'Warm', 'SelfTest')][string]$Mode = 'Run',
    [string]$Engine,          # kelvaroq-engine.exe (or victory.exe)
    [string]$Image,           # the title's entry point; only its folder and path are used
    [string]$DataDir,         # master copy of the fixed save (VICTORY_DATA_DIR); never written
    [string]$CacheDir,        # master copy of the warm cache (VICTORY_CACHE_DIR); never written
    [string]$Keys,            # VICTORY_KEYS value, passed through verbatim
    [string]$KeysFile,        # file whose text is VICTORY_KEYS, passed through verbatim
    [switch]$NoInput,         # explicitly run with no scripted input (not comparable across runs)
    [int]$Duration = 300,     # seconds of monitor time per run
    [int]$Runs = 1,
    [string]$Label,
    [string]$OutDir,
    [string]$ConsoleProfile = 'series-x',
    [int]$HeavyDraws = 3000,  # a heavy frame is an interval with at least this many guest draws
    [int]$MinHeavyFrames = 300,
    [int]$MinRecipes = 1,
    [int]$StartTimeout = 300, # seconds to wait for the first monitor row
    [string]$Baseline,        # baseline directory or summary.csv
    [string]$Current,         # Compare mode: run directory or summary.csv
    [double]$Threshold = 5.0, # percent
    [string]$SaveBaselineAs,  # copy this run's summary into bench/baselines/<name>
    [hashtable]$ExtraEnv = @{},
    [string]$Config           # defaults to bench/heavy.local.psd1 (gitignored)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ci = [System.Globalization.CultureInfo]::InvariantCulture
$BenchDir = $PSScriptRoot

# ---- machine-local defaults -------------------------------------------------------------------
if (-not $Config) { $Config = Join-Path $BenchDir 'heavy.local.psd1' }
if (Test-Path -LiteralPath $Config) {
    $allowed = 'Engine', 'Image', 'DataDir', 'CacheDir', 'Keys', 'KeysFile', 'Duration', 'Runs',
    'OutDir', 'ConsoleProfile', 'HeavyDraws', 'MinHeavyFrames', 'MinRecipes', 'StartTimeout',
    'Threshold', 'ExtraEnv'
    $local = Import-PowerShellDataFile -LiteralPath $Config
    foreach ($k in $local.Keys) {
        if ($k -notin $allowed) { throw "heavy.local.psd1: unknown key '$k'" }
        if (-not $PSBoundParameters.ContainsKey($k)) { Set-Variable -Name $k -Value $local[$k] }
    }
}
if (-not $OutDir) { $OutDir = Join-Path $BenchDir 'out' }

function Stop-Bench([int]$Code, [string]$Message) {
    [Console]::Error.WriteLine("heavy.ps1: $Message")
    exit $Code
}

# ---- statistics -------------------------------------------------------------------------------
# Nearest-rank percentile on a sorted array: the value at rank ceil(p/100 * n). No interpolation,
# so a reported p95 is always a frame that happened.
function Get-Percentile([double[]]$Sorted, [double]$P) {
    if ($Sorted.Count -eq 0) { return [double]::NaN }
    $rank = [math]::Ceiling($P / 100.0 * $Sorted.Count)
    $i = [math]::Min([math]::Max([int]$rank - 1, 0), $Sorted.Count - 1)
    return $Sorted[$i]
}

function Get-FrameStats([double[]]$Ms) {
    $s = [double[]]@($Ms | Sort-Object)
    $sum = 0.0; foreach ($v in $s) { $sum += $v }
    [ordered]@{
        n    = $s.Count
        p50  = Get-Percentile $s 50
        p95  = Get-Percentile $s 95
        p99  = Get-Percentile $s 99
        mean = if ($s.Count) { $sum / $s.Count } else { [double]::NaN }
        max  = if ($s.Count) { $s[-1] } else { [double]::NaN }
    }
}

$ABSENT = [uint64]::MaxValue
$BucketEdges = 3000, 4000, 5000, 6000, 8000

function Get-FieldIndex($Names) {
    $ix = @{}; for ($i = 0; $i -lt $Names.Count; $i++) { $ix[$Names[$i]] = $i }
    foreach ($need in 'timestamp_us', 'frame_us', 'present_status', 'draws') {
        if (-not $ix.ContainsKey($need)) { throw "monitor ring lacks the field '$need'" }
    }
    return $ix
}

# Rows are @{Seq; Row} with Row a uint64[] indexed by monitor field. The window is Duration seconds
# of monitor time from the run's first row. Failed presents are excluded and counted: the monitor
# publishes no interval for them (frame_us is ABSENT across an occluded or failed flip).
function Select-HeavyRows($Names, $Rows, [int]$HeavyDraws, [int]$DurationSeconds) {
    $ix = Get-FieldIndex $Names
    $t0 = $null
    foreach ($x in $Rows) { $t = $x.Row[$ix.timestamp_us]; if ($t -ne $ABSENT) { $t0 = [double]$t; break } }
    $heavy = [System.Collections.Generic.List[uint64[]]]::new()
    $all = 0; $failed = 0
    if ($null -ne $t0) {
        $limit = $t0 + $DurationSeconds * 1e6
        foreach ($x in $Rows) {
            $r = $x.Row; $t = $r[$ix.timestamp_us]
            if ($t -eq $ABSENT -or [double]$t -gt $limit) { continue }
            if ($r[$ix.present_status] -ne 0) { $failed++; continue }
            if ($r[$ix.frame_us] -eq $ABSENT) { continue }
            $all++
            if ($r[$ix.draws] -ne $ABSENT -and $r[$ix.draws] -ge $HeavyDraws) { $heavy.Add($r) }
        }
    }
    return @{ Heavy = $heavy; All = $all; Failed = $failed; Ix = $ix }
}

function Get-RunSummary($Names, $Rows, [int]$HeavyDraws, [int]$DurationSeconds) {
    $sel = Select-HeavyRows $Names $Rows $HeavyDraws $DurationSeconds
    $res = Get-SummaryFromHeavy $sel.Ix $sel.Heavy $sel.All $sel.Failed $HeavyDraws
    $res.Heavy = $sel.Heavy
    return $res
}

function Get-SummaryFromHeavy($ix, $heavy, [int]$all, [int]$failed, [int]$HeavyDraws) {
    $ms = [double[]]@($heavy | ForEach-Object { [double]$_[$ix.frame_us] / 1000.0 })
    $st = Get-FrameStats $ms
    $mean = {
        param([string[]]$Fields)
        if ($heavy.Count -eq 0) { return [double]::NaN }
        $sum = 0.0; $n = 0
        foreach ($r in $heavy) {
            $row = 0.0; $ok = $true
            foreach ($f in $Fields) {
                if (-not $ix.ContainsKey($f) -or $r[$ix[$f]] -eq $ABSENT) { $ok = $false; break }
                $row += [double]$r[$ix[$f]]
            }
            if ($ok) { $sum += $row; $n++ }
        }
        if ($n) { $sum / $n / 1000.0 } else { [double]::NaN }   # microseconds -> ms
    }
    $ratio = {
        param([string]$Num, [string]$Den)
        $a = 0.0; $b = 0.0
        foreach ($r in $heavy) {
            if (-not $ix.ContainsKey($Num) -or $r[$ix[$Num]] -eq $ABSENT -or $r[$ix[$Den]] -eq $ABSENT) { continue }
            $a += [double]$r[$ix[$Num]]; $b += [double]$r[$ix[$Den]]
        }
        if ($b -gt 0) { $a / $b } else { [double]::NaN }
    }
    $busy = & $ratio 'gpu_busy_us' 'frame_us'
    $summary = [ordered]@{
        frames_total      = $all
        frames_failed     = $failed
        heavy_frames      = $st.n
        p50_ms            = $st.p50
        p95_ms            = $st.p95
        p99_ms            = $st.p99
        mean_ms           = $st.mean
        max_ms            = $st.max
        gpu_busy_pct      = if ([double]::IsNaN($busy)) { [double]::NaN } else { $busy * 100 }
        # Where the interval goes, per heavy frame (ms). Submit "work" is every stage the worker
        # spends computing; "wait" is everything it spends asleep on a lock, the card or the relay.
        submit_work_ms    = & $mean 'submit_other_us', 'descriptors_us', 'watch_us', 'deferred_us', 'snapshots_us', 'card_setup_us', 'execute_us'
        submit_wait_ms    = & $mean 'submit_lock_us', 'submit_card_us', 'relay_wait_us', 'submit_fetch_us', 'submit_dependency_us'
        submit_idle_ms    = & $mean 'submit_idle_us'
        relay_wait_ms     = & $mean 'relay_wait_us'
        submit_card_ms    = & $mean 'submit_card_us'
        descriptors_ms    = & $mean 'descriptors_us'
        watch_ms          = & $mean 'watch_us'
        deferred_ms       = & $mean 'deferred_us'
        # Title-side blocking. Not in the ring until submission.md step 0 lands: empty until then.
        title_pacing_ms   = & $mean 'title_pacing_us'
        title_fence_ms    = & $mean 'title_fence_us'
        title_value_ms    = & $mean 'title_value_us'
        title_releaser_ms = & $mean 'title_releaser_us'
        title_ms          = & $mean 'title_us'
        present_call_ms   = & $mean 'present_us'
        pipeline_wait_ms  = & $mean 'pipeline_wait_us'
        # The picture check. A speedup that also lowers drawn/draws drew less, not faster.
        drawn_ratio       = & $ratio 'drawn' 'draws'
        dropped_ratio     = & $ratio 'drop_pipeline' 'draws'
    }
    # Per-bucket view: two runs are rarely at the same place in the scene.
    $buckets = @()
    for ($b = 0; $b -le $BucketEdges.Count; $b++) {
        $lo = if ($b -eq 0) { $HeavyDraws } else { $BucketEdges[$b - 1] }
        $hi = if ($b -lt $BucketEdges.Count) { $BucketEdges[$b] } else { [int]::MaxValue }
        if ($b -eq 0 -and $lo -ge $hi) { continue }   # HeavyDraws at or above the first edge
        $sel = [double[]]@($heavy | Where-Object { $d = $_[$ix.draws]; $d -ge $lo -and $d -lt $hi } |
                ForEach-Object { [double]$_[$ix.frame_us] / 1000.0 })
        $bs = Get-FrameStats $sel
        $buckets += [ordered]@{ draws_from = $lo; draws_to = if ($hi -eq [int]::MaxValue) { '' } else { $hi }; n = $bs.n; p50_ms = $bs.p50; p95_ms = $bs.p95 }
    }
    return @{ Summary = $summary; Buckets = $buckets }
}

function Format-Cell($v) {
    if ($v -is [double] -or $v -is [single]) { if ([double]::IsNaN([double]$v)) { return '' } else { return ([double]$v).ToString('R', $ci) } }
    return [string]$v
}
function Write-KeyedCsv([string]$Path, $Ordered) {
    $h = ($Ordered.Keys -join ',')
    $v = ($Ordered.Keys | ForEach-Object { Format-Cell $Ordered[$_] }) -join ','
    Set-Content -LiteralPath $Path -Value @($h, $v) -Encoding utf8
}
function Write-TableCsv([string]$Path, $Rows) {
    if ($Rows.Count -eq 0) { Set-Content -LiteralPath $Path -Value '' -Encoding utf8; return }
    $lines = @(($Rows[0].Keys -join ','))
    foreach ($r in $Rows) { $lines += (($r.Keys | ForEach-Object { Format-Cell $r[$_] }) -join ',') }
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}
function Read-SummaryCsv([string]$PathOrDir) {
    $p = if (Test-Path -LiteralPath $PathOrDir -PathType Container) { Join-Path $PathOrDir 'summary.csv' } else { $PathOrDir }
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $row = Import-Csv -LiteralPath $p | Select-Object -First 1
    $o = @{}
    foreach ($prop in $row.PSObject.Properties) {
        $d = 0.0
        $o[$prop.Name] = if ([double]::TryParse($prop.Value, [System.Globalization.NumberStyles]::Float, $ci, [ref]$d)) { $d } else { [double]::NaN }
    }
    return $o
}
function Read-BucketsCsv([string]$PathOrDir) {
    $dir = if (Test-Path -LiteralPath $PathOrDir -PathType Container) { $PathOrDir } else { Split-Path -Parent $PathOrDir }
    $p = Join-Path $dir 'buckets.csv'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Import-Csv -LiteralPath $p)
}

# ---- comparison gate --------------------------------------------------------------------------
# Returns @{ Exit = 0|1; Lines = string[] }. Gate: p50 and p95 of heavy frames, higher is worse.
function Compare-Summaries($Base, $Cur, [double]$ThresholdPct, $BaseBuckets, $CurBuckets) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $regressed = $false
    $lines.Add(('{0,-18} {1,12} {2,12} {3,9}  {4}' -f 'metric', 'baseline', 'current', 'delta', 'verdict'))
    $row = {
        param($Name, $Gate, [string]$Fmt = 'F1')
        $b = $Base[$Name]; $c = $Cur[$Name]
        if ($null -eq $b -or $null -eq $c -or [double]::IsNaN($b) -or [double]::IsNaN($c) -or $b -eq 0) {
            $lines.Add(('{0,-18} {1,12} {2,12} {3,9}  {4}' -f $Name, 'n/a', 'n/a', '', 'not comparable')); return $false
        }
        $d = ($c - $b) / $b * 100.0
        $verdict = ''
        $bad = $false
        if ($Gate) {
            if ($d -gt $ThresholdPct) { $verdict = "REGRESSION (> +$ThresholdPct%)"; $bad = $true }
            elseif ($d -lt -$ThresholdPct) { $verdict = 'improved' } else { $verdict = 'within threshold' }
        }
        $lines.Add(('{0,-18} {1,12} {2,12} {3,8}%  {4}' -f $Name, $b.ToString($Fmt, $ci), $c.ToString($Fmt, $ci), $d.ToString('+0.0;-0.0;0.0', $ci), $verdict))
        return $bad
    }
    foreach ($m in 'p50_ms', 'p95_ms') { if (& $row $m $true) { $regressed = $true } }
    foreach ($m in 'p99_ms', 'mean_ms', 'max_ms', 'submit_work_ms', 'submit_wait_ms', 'relay_wait_ms', 'submit_card_ms', 'descriptors_ms', 'watch_ms', 'deferred_ms', 'title_ms', 'present_call_ms', 'pipeline_wait_ms', 'title_pacing_ms', 'title_fence_ms', 'title_value_ms', 'title_releaser_ms') { [void](& $row $m $false) }
    foreach ($m in 'heavy_frames', 'gpu_busy_pct') { [void](& $row $m $false 'F0') }
    $warn = [System.Collections.Generic.List[string]]::new()
    $dr = $Cur['drawn_ratio'] - $Base['drawn_ratio']
    if (-not [double]::IsNaN($dr) -and $dr -lt -0.01) {
        $warn.Add(("drawn/draws fell {0:F1} points: the current run drew less. A faster time on a changed picture is not a speedup; capture and diff before accepting." -f (-$dr * 100)))
    }
    $dd = $Cur['dropped_ratio'] - $Base['dropped_ratio']
    if (-not [double]::IsNaN($dd) -and $dd -gt 0.01) {
        $warn.Add(("dropped draws rose {0:F1} points of guest draws." -f ($dd * 100)))
    }
    if ($Cur['heavy_frames'] -lt 600 -or $Base['heavy_frames'] -lt 600) {
        $warn.Add('fewer than 600 heavy frames on one side; the protocol asks for 600 across three runs per variant.')
    }
    if ($BaseBuckets.Count -and $CurBuckets.Count -and $BaseBuckets.Count -eq $CurBuckets.Count) {
        $bn = ($BaseBuckets | ForEach-Object { [double]$_.n } | Measure-Object -Sum).Sum
        $cn = ($CurBuckets | ForEach-Object { [double]$_.n } | Measure-Object -Sum).Sum
        for ($i = 0; $i -lt $BaseBuckets.Count -and $bn -gt 0 -and $cn -gt 0; $i++) {
            $shift = [math]::Abs([double]$CurBuckets[$i].n / $cn - [double]$BaseBuckets[$i].n / $bn)
            if ($shift -gt 0.15) {
                $warn.Add(("scene mix differs: draws bucket {0}+ holds {1:P0} of baseline heavy frames and {2:P0} of current. Read the bucket table, not the pooled gate." -f $BaseBuckets[$i].draws_from, ([double]$BaseBuckets[$i].n / $bn), ([double]$CurBuckets[$i].n / $cn)))
                break
            }
        }
        $lines.Add('')
        $lines.Add(('{0,-14} {1,6} {2,6} {3,10} {4,10} {5,10} {6,10}' -f 'draws', 'n(b)', 'n(c)', 'p50 b', 'p50 c', 'p95 b', 'p95 c'))
        for ($i = 0; $i -lt $BaseBuckets.Count; $i++) {
            $b = $BaseBuckets[$i]; $c = $CurBuckets[$i]
            $range = if ($b.draws_to -eq '') { "$($b.draws_from)+" } else { "$($b.draws_from)-$($b.draws_to)" }
            $lines.Add(('{0,-14} {1,6} {2,6} {3,10} {4,10} {5,10} {6,10}' -f $range, $b.n, $c.n, $b.p50_ms, $c.p50_ms, $b.p95_ms, $c.p95_ms))
        }
    }
    foreach ($w in $warn) { $lines.Add("WARNING: $w") }
    $lines.Add('')
    $lines.Add($(if ($regressed) { "RESULT: REGRESSION over $ThresholdPct% on p50 or p95 of heavy frames" } else { "RESULT: no regression over $ThresholdPct%" }))
    return @{ Exit = [int]$regressed; Lines = $lines.ToArray() }
}

# ---- monitor ring reader (layout: native/kelvaroq-render/src/stats_ring.rs) --------------------
$RING_CAP = 512; $RING_FIELDS = 64; $RING_STRIDE = 65; $RING_HEADER = 8 + 4 * 64
$RING_BYTES = ($RING_HEADER + $RING_CAP * $RING_STRIDE) * 8
$RING_MAGIC = [BitConverter]::ToUInt64([Text.Encoding]::ASCII.GetBytes('KELVSTAT'), 0)

function Open-Ring([int]$RingPid, [string]$NameOverride) {
    $name = if ($NameOverride) { $NameOverride } else { "Local\KelvaroqStats-$RingPid" }
    try {
        $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($name, [System.IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
    } catch { return $null }
    $view = $mmf.CreateViewAccessor(0, 0, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    $w = { param($i) $view.ReadUInt64([long]$i * 8) }
    $count = [int](& $w 5)
    $ok = (& $w 0) -eq $RING_MAGIC -and (& $w 1) -eq 1 -and (& $w 2) -eq ($RING_HEADER * 8) -and
    (& $w 3) -eq ($RING_STRIDE * 8) -and (& $w 4) -eq $RING_CAP -and $count -ge 1 -and $count -le $RING_FIELDS -and
    (& $w 6) -eq [uint64]$RingPid
    if (-not $ok) { $view.Dispose(); $mmf.Dispose(); return $null }
    $names = for ($i = 0; $i -lt $count; $i++) {
        $bytes = for ($j = 0; $j -lt 4; $j++) { [BitConverter]::GetBytes([uint64](& $w (8 + 4 * $i + $j))) }
        [Text.Encoding]::ASCII.GetString(($bytes | Where-Object { $_ -ne 0 } | ForEach-Object { [byte]$_ }))
    }
    return @{ Mmf = $mmf; View = $view; Names = @($names); Count = $count; Last = [uint64]0; Lost = [uint64]0 }
}
function Close-Ring($Ring) { if ($Ring) { $Ring.View.Dispose(); $Ring.Mmf.Dispose() } }
function Read-RingRow($Ring, [uint64]$Seq) {
    $start = $RING_HEADER + [int](($Seq - 1) % $RING_CAP) * $RING_STRIDE
    $v = $Ring.View
    if ($v.ReadUInt64([long]$start * 8) -ne $Seq) { return $null }
    $vals = [uint64[]]::new($Ring.Count)
    for ($i = 0; $i -lt $Ring.Count; $i++) { $vals[$i] = $v.ReadUInt64([long]($start + 1 + $i) * 8) }
    if ($v.ReadUInt64([long]$start * 8) -ne $Seq) { return $null }   # torn lap
    return , $vals
}
# Appends new rows to $Into as @{Seq; Row}. Counts rows the ring overwrote before we read them.
function Receive-RingRows($Ring, $Into) {
    $newest = $Ring.View.ReadUInt64(7 * 8)
    if ($newest -eq 0) { return 0 }
    $first = if ($newest -gt ($RING_CAP - 1)) { $newest - ($RING_CAP - 1) } else { [uint64]1 }
    $next = if ($Ring.Last -eq 0) { $first } else { $Ring.Last + 1 }
    if ($next -lt $first) { $Ring.Lost += ($first - $next); $next = $first }
    $got = 0
    for ($s = $next; $s -le $newest; $s++) {
        $row = Read-RingRow $Ring $s
        if ($null -eq $row) { break }
        $Into.Add(@{ Seq = $s; Row = $row }); $Ring.Last = $s; $got++
    }
    return $got
}
function Write-FramesCsv([string]$Path, $Names, $Rows, [int]$HeavyDraws) {
    $di = [array]::IndexOf($Names, 'draws')
    $sw = [System.IO.StreamWriter]::new($Path, $false, [Text.UTF8Encoding]::new($false))
    try {
        $sw.WriteLine('sequence,' + ($Names -join ',') + ',heavy')
        foreach ($r in $Rows) {
            $cells = foreach ($v in $r.Row) { if ($v -eq $ABSENT) { '' } else { $v.ToString($ci) } }
            $heavy = if ($di -ge 0 -and $r.Row[$di] -ne $ABSENT -and $r.Row[$di] -ge $HeavyDraws) { 1 } else { 0 }
            $sw.WriteLine("$($r.Seq),$($cells -join ','),$heavy")
        }
    } finally { $sw.Dispose() }
}

# ---- cache gate -------------------------------------------------------------------------------
# A cold cache makes every pipeline compile during play: draws drop and frames stretch. Refuse.
# The engine's own check counts recipes without a published host pipeline, but it answers 0 for a
# cache with NO recipes, so the file checks run first. The receipt is keyed on the engine binary,
# the adapter and the driver: a cache warmed by another build or card is cold for this one.
function Test-WarmCache([string]$Engine, [string]$Cache, [int]$MinRecipes, [switch]$SkipEngine) {
    $result = { param($ok, $why, $n = -1, $rec = -1) [pscustomobject]@{ Ok = $ok; Reason = $why; Outstanding = $n; Recipes = $rec } }
    if (-not $Cache -or -not (Test-Path -LiteralPath $Cache -PathType Container)) { return & $result $false "cache directory not found: '$Cache'" }
    foreach ($d in 'pipelines', 'shaders') {
        if (-not (Test-Path -LiteralPath (Join-Path $Cache $d) -PathType Container)) { return & $result $false "no '$d' directory in the cache" }
    }
    $recipeDir = Join-Path $Cache 'pipelines/warm-v1'
    $recipes = if (Test-Path -LiteralPath $recipeDir) { @(Get-ChildItem -LiteralPath $recipeDir -File -Recurse).Count } else { 0 }
    if ($recipes -lt $MinRecipes) { return & $result $false "only $recipes recorded pipeline recipes in pipelines/warm-v1 (need >= $MinRecipes); the cache was never played" $(-1) $recipes }
    if (-not (Test-Path -LiteralPath (Join-Path $Cache 'pipelines/precompiled-v1.txt'))) {
        return & $result $false 'no pipelines/precompiled-v1.txt receipt: nothing was precompiled for this build' $(-1) $recipes
    }
    if ($SkipEngine) { return & $result $true 'file checks only' $(-1) $recipes }
    if (-not (Test-Path -LiteralPath $Engine)) { return & $result $false "engine not found: '$Engine'" $(-1) $recipes }
    $out = & $Engine precompile --cache $Cache --check 2>&1 | Out-String
    if ($out -notmatch 'precompile-check\s+(\d+)') { return & $result $false "engine gave no 'precompile-check N' line: $($out.Trim())" $(-1) $recipes }
    $n = [int]$Matches[1]
    if ($n -ne 0) { return & $result $false "$n of $recipes recipes have no published host pipeline for this engine build and adapter" $n $recipes }
    return & $result $true 'warm' 0 $recipes
}

# ---- run orchestration ------------------------------------------------------------------------
function Copy-Tree([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    # /DCOPY:DAT keeps directory timestamps: the cache receipt records shaders/ creation time.
    & robocopy $From $To /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From -> $To" }
    $global:LASTEXITCODE = 0
}
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

function Invoke-TitleRun([string]$RunDir, [hashtable]$EnvSet, [int]$DurationSeconds) {
    # Every inherited VICTORY_* and KELVAROQ_* setting is removed first (the protocol calls for no
    # inherited settings and no VICTORY_GPU_TIMING), then exactly $EnvSet is applied. Restored after.
    $saved = @{}
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys) | Where-Object { $_ -match '^(VICTORY_|KELVAROQ_)' }) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $proc = $null
    try {
        foreach ($k in $EnvSet.Keys) { [Environment]::SetEnvironmentVariable([string]$k, [string]$EnvSet[$k], 'Process') }
        $proc = Start-Process -FilePath $Engine -ArgumentList @('run', ('"' + $Image + '"'), '--console', $ConsoleProfile, '--execute') `
            -WorkingDirectory (Split-Path -Parent $Engine) -PassThru -WindowStyle Minimized `
            -RedirectStandardOutput (Join-Path $RunDir 'engine.out.log') -RedirectStandardError (Join-Path $RunDir 'engine.err.log')
    } finally {
        foreach ($k in $EnvSet.Keys) { [Environment]::SetEnvironmentVariable([string]$k, $null, 'Process') }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    $ring = $null; $names = @(); $lost = [uint64]0; $note = ''
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $ring) {
            if ($proc.HasExited) { $note = "engine exited ($($proc.ExitCode)) before the monitor appeared"; break }
            if ($clock.Elapsed.TotalSeconds -gt $StartTimeout) { $note = "no monitor ring after ${StartTimeout}s"; break }
            $ring = Open-Ring $proc.Id
            if (-not $ring) { Start-Sleep -Milliseconds 500 }
        }
        if ($ring) {
            $names = $ring.Names
            $ti = [array]::IndexOf($names, 'timestamp_us')
            $firstTs = $null; $hard = [Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                [void](Receive-RingRows $ring $rows)
                if ($rows.Count -gt 0) {
                    if ($null -eq $firstTs) { $firstTs = $rows[0].Row[$ti] }
                    $lastTs = $rows[$rows.Count - 1].Row[$ti]
                    if ($lastTs -ne $ABSENT -and $firstTs -ne $ABSENT -and ($lastTs - $firstTs) -ge ([uint64]$DurationSeconds * 1000000)) { break }
                }
                if ($proc.HasExited) { $note = "engine exited ($($proc.ExitCode)) during the run"; break }
                if ($hard.Elapsed.TotalSeconds -gt ($StartTimeout + $DurationSeconds + 120)) { $note = 'run exceeded its wall-clock limit'; break }
                Start-Sleep -Milliseconds 200
            }
            [void](Receive-RingRows $ring $rows)
            $lost = $ring.Lost
        }
    } finally {
        Close-Ring $ring
        if ($proc -and -not $proc.HasExited) { $proc.Kill($true); [void]$proc.WaitForExit(15000) }
    }
    return @{ Names = $names; Rows = $rows; Lost = $lost; Note = $note }
}

function Get-HostFacts {
    $gpu = try { Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion } catch { @() }
    [ordered]@{
        host   = $env:COMPUTERNAME
        os     = [Environment]::OSVersion.VersionString
        gpus   = @($gpu | ForEach-Object { "$($_.Name) $($_.DriverVersion)" })
        pwsh   = $PSVersionTable.PSVersion.ToString()
    }
}

function Get-Invalid($Summary, $Lost, $Note, [int]$MinHeavy) {
    $why = @()
    if ($Note) { $why += $Note }
    if ($Lost -gt 0) { $why += "$Lost monitor rows were overwritten before they were read" }
    if ($Summary.heavy_frames -lt $MinHeavy) { $why += "only $($Summary.heavy_frames) heavy frames (need >= $MinHeavy): the scripted input did not reach the heavy scene" }
    return $why
}

# ---- self test --------------------------------------------------------------------------------
function Invoke-SelfTest {
    # One mutable state object: scriptblocks below mutate it, not a copy in another scope.
    $st = @{ fail = 0; next = [uint64]1; ts = [uint64]0 }
    $check = { param($ok, $what) if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what" -ForegroundColor Red; $st.fail++ } }
    Write-Host 'percentiles'
    $s = [double[]](1..100)
    & $check ((Get-Percentile $s 50) -eq 50) 'p50 of 1..100 is 50'
    & $check ((Get-Percentile $s 95) -eq 95) 'p95 of 1..100 is 95'
    & $check ((Get-Percentile ([double[]]@(7)) 95) -eq 7) 'single sample'
    & $check ([double]::IsNaN((Get-Percentile ([double[]]@()) 50))) 'empty is NaN'

    Write-Host 'ring reader against a synthetic writer (same layout as stats_ring.rs)'
    $fake = 2000000000 + $PID   # a pid no real process has; stays inside [int] and the ring's pid word
    $mmName = "Local\KelvaroqStats-$fake"
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($mmName, $RING_BYTES)
    $wv = $mmf.CreateViewAccessor()
    $names = 'frame', 'timestamp_us', 'frame_us', 'present_status', 'draws', 'drawn', 'drop_pipeline', 'gpu_busy_us', 'submit_other_us', 'title_us'
    $put = { param($i, $v) $wv.Write([long]$i * 8, [uint64]$v) }
    $hdr = 1, ($RING_HEADER * 8), ($RING_STRIDE * 8), $RING_CAP, $names.Count, $fake
    for ($i = 0; $i -lt 6; $i++) { & $put (1 + $i) $hdr[$i] }
    for ($i = 0; $i -lt $names.Count; $i++) {
        $b = [byte[]]::new(32); [Text.Encoding]::ASCII.GetBytes($names[$i]).CopyTo($b, 0)
        for ($j = 0; $j -lt 4; $j++) { & $put (8 + 4 * $i + $j) ([BitConverter]::ToUInt64($b, 8 * $j)) }
    }
    & $put 0 $RING_MAGIC
    $publish = {   # the writer protocol of stats_ring.rs: invalidate the slot, fill it, then publish the sequence
        param([uint64[]]$vals)
        $seq = $st.next
        $start = $RING_HEADER + [int](($seq - 1) % $RING_CAP) * $RING_STRIDE
        & $put $start 0
        for ($i = 0; $i -lt $vals.Count; $i++) { & $put ($start + 1 + $i) $vals[$i] }
        & $put $start $seq; & $put 7 $seq
        $st.next = $seq + 1
    }
    $emit = {
        param([uint64]$frameUs, [uint64]$draws, [uint64]$status = 0)
        $st.ts = $st.ts + $frameUs
        & $publish ([uint64[]]@($st.next, $st.ts, $frameUs, $status, $draws, $draws, 0, ($frameUs / 2), 3000, 1000))
    }
    $ring = Open-Ring $fake
    & $check ($null -ne $ring -and $ring.Names.Count -eq $names.Count -and $ring.Names[2] -eq 'frame_us') 'opens by name, reads the field dictionary'
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt 100; $i++) { & $emit ([uint64](100000 + $i * 1000)) ([uint64]4000) }   # 100.0 .. 199.0 ms, heavy
    for ($i = 0; $i -lt 50; $i++) { & $emit ([uint64]33000) ([uint64]500) }                    # light, excluded
    & $emit ([uint64]999000) ([uint64]4000) ([uint64]1)                                          # failed present, excluded
    [void](Receive-RingRows $ring $rows)
    & $check ($rows.Count -eq 151) 'drains 151 rows'
    $sum = Get-RunSummary $ring.Names $rows 3000 300
    & $check ($sum.Summary.heavy_frames -eq 100) 'heavy filter keeps draws >= 3000 and drops light and failed presents'
    & $check ($sum.Summary.frames_failed -eq 1) 'failed present counted separately'
    & $check ([math]::Abs($sum.Summary.p50_ms - 149.0) -lt 1e-9) 'p50 of 100..199 ms is 149'
    & $check ([math]::Abs($sum.Summary.p95_ms - 194.0) -lt 1e-9) 'p95 of 100..199 ms is 194'
    & $check ([math]::Abs($sum.Summary.gpu_busy_pct - 50.0) -lt 1e-9) 'gpu busy share'
    $short = Get-RunSummary $ring.Names $rows 3000 0
    & $check ($short.Summary.heavy_frames -le 1) 'duration window cuts the run'
    for ($i = 0; $i -lt 600; $i++) { & $emit ([uint64]50000) ([uint64]4000) }
    [void](Receive-RingRows $ring $rows)
    # 151 read, 600 more published: newest 751, oldest still held 240, next wanted 152 -> 88 lost.
    & $check ($ring.Lost -eq 88) 'a lapped ring reports exactly the rows it overwrote'
    & $check ((Get-Invalid $sum.Summary $ring.Lost '' 300).Count -ge 1) 'lost rows or too few heavy frames make a run invalid'
    Close-Ring $ring; $wv.Dispose(); $mmf.Dispose()

    Write-Host 'comparison gate'
    $base = @{ p50_ms = 100.0; p95_ms = 200.0; p99_ms = 250.0; mean_ms = 110.0; max_ms = 400.0; submit_work_ms = 80.0; submit_wait_ms = 10.0; title_ms = 5.0; present_call_ms = 0.1; pipeline_wait_ms = 1.0; heavy_frames = 900.0; gpu_busy_pct = 30.0; drawn_ratio = 0.93; dropped_ratio = 0.07 }
    $mk = { param($p50f, $p95f, $drawn = 0.93) $c = $base.Clone(); $c.p50_ms = 100.0 * $p50f; $c.p95_ms = 200.0 * $p95f; $c.drawn_ratio = $drawn; $c }
    & $check ((Compare-Summaries $base (& $mk 1.04 1.04) 5 @() @()).Exit -eq 0) '+4% on both passes'
    & $check ((Compare-Summaries $base (& $mk 1.06 1.00) 5 @() @()).Exit -eq 1) '+6% on p50 fails'
    & $check ((Compare-Summaries $base (& $mk 1.00 1.06) 5 @() @()).Exit -eq 1) '+6% on p95 fails'
    & $check ((Compare-Summaries $base (& $mk 0.80 0.80) 5 @() @()).Exit -eq 0) 'a speedup passes'
    & $check ((Compare-Summaries $base (& $mk 1.049 1.049) 5 @() @()).Exit -eq 0) '+4.9% passes'
    $faster = Compare-Summaries $base (& $mk 0.70 0.70 0.80) 5 @() @()
    & $check (($faster.Lines -join "`n") -match 'drew less') 'a speedup that drew less is flagged'

    Write-Host 'cold-cache refusal'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "heavy-selftest-$PID"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        & $check (-not (Test-WarmCache 'none' $tmp 1 -SkipEngine).Ok) 'empty directory is cold'
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'pipelines'), (Join-Path $tmp 'shaders') | Out-Null
        & $check (-not (Test-WarmCache 'none' $tmp 1 -SkipEngine).Ok) 'no recipes is cold (the engine check alone would say 0 outstanding)'
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'pipelines/warm-v1') | Out-Null
        Set-Content -LiteralPath (Join-Path $tmp 'pipelines/warm-v1/a') -Value 'x'
        & $check (-not (Test-WarmCache 'none' $tmp 1 -SkipEngine).Ok) 'recipes without a receipt is cold'
        Set-Content -LiteralPath (Join-Path $tmp 'pipelines/precompiled-v1.txt') -Value 'h'
        & $check ((Test-WarmCache 'none' $tmp 1 -SkipEngine).Ok) 'file checks pass with recipes and a receipt'
        & $check (-not (Test-WarmCache (Join-Path $tmp 'missing.exe') $tmp 1).Ok) 'a missing engine cannot vouch for the cache'
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
    if ($st.fail) { Write-Host "$($st.fail) self-test failure(s)" -ForegroundColor Red; exit 1 }
    Write-Host 'self-test passed'
    exit 0
}

# ---- entry points -----------------------------------------------------------------------------
if ($Mode -eq 'SelfTest') { Invoke-SelfTest }

if ($Mode -eq 'Compare') {
    if (-not $Baseline -or -not $Current) { Stop-Bench 2 'Compare needs -Baseline and -Current' }
    $b = Read-SummaryCsv $Baseline; $c = Read-SummaryCsv $Current
    if (-not $b) { Stop-Bench 2 "no baseline summary at '$Baseline'" }
    if (-not $c) { Stop-Bench 2 "no current summary at '$Current'" }
    $r = Compare-Summaries $b $c $Threshold (Read-BucketsCsv $Baseline) (Read-BucketsCsv $Current)
    $r.Lines | ForEach-Object { Write-Host $_ }
    exit $r.Exit
}

foreach ($p in 'Engine', 'CacheDir') { if (-not (Get-Variable $p -ValueOnly)) { Stop-Bench 2 "-$p is required (or set it in bench/heavy.local.psd1)" } }
if (-not (Test-Path -LiteralPath $Engine)) { Stop-Bench 2 "engine not found: $Engine" }
if (@(Get-Process -Name 'kelvaroq-engine', 'victory' -ErrorAction SilentlyContinue).Count) { Stop-Bench 5 'an engine process is already running; a measured run needs the machine to itself' }

if ($Mode -eq 'Warm') {
    Write-Host "precompiling the recorded pipelines in $CacheDir (the cache is modified in place)"
    & $Engine precompile --cache $CacheDir
    if ($LASTEXITCODE -ne 0) { Stop-Bench 5 "precompile exited $LASTEXITCODE" }
    $w = Test-WarmCache $Engine $CacheDir $MinRecipes
    if (-not $w.Ok) { Stop-Bench 3 "still cold after precompile: $($w.Reason)" }
    Write-Host "warm: $($w.Recipes) recipes, 0 outstanding"; exit 0
}

foreach ($p in 'Image', 'DataDir', 'Label') { if (-not (Get-Variable $p -ValueOnly)) { Stop-Bench 2 "-$p is required" } }
if (-not (Test-Path -LiteralPath $Image)) { Stop-Bench 2 "image not found: $Image" }
if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) { Stop-Bench 2 "save directory not found: $DataDir" }
$keysValue = $null
if ($Keys) { $keysValue = $Keys } elseif ($KeysFile) {
    if (-not (Test-Path -LiteralPath $KeysFile)) { Stop-Bench 2 "keys file not found: $KeysFile" }
    $keysValue = (Get-Content -LiteralPath $KeysFile -Raw).Trim()
}
if (-not $keysValue -and -not $NoInput) { Stop-Bench 2 'no scripted input: give -Keys or -KeysFile (VICTORY_KEYS), or -NoInput to accept a non-reproducible run' }
if ($Runs -lt 1) { Stop-Bench 2 '-Runs must be >= 1' }

# Cold-cache gate on the master, before anything is copied or launched.
$gate = Test-WarmCache $Engine $CacheDir $MinRecipes
if (-not $gate.Ok) {
    Stop-Bench 3 "REFUSING TO RUN: cache is cold. $($gate.Reason). Run: heavy.ps1 -Mode Warm -Engine ... -CacheDir ..."
}
Write-Host "cache warm: $($gate.Recipes) recipes, 0 outstanding"

$labelDir = Join-Path $OutDir $Label
if (Test-Path -LiteralPath $labelDir) { Stop-Bench 2 "output directory already exists: $labelDir (labels are not overwritten)" }
New-Item -ItemType Directory -Force -Path $labelDir | Out-Null

$engineSha = (Get-FileHash -LiteralPath $Engine -Algorithm SHA256).Hash.ToLowerInvariant()
$dataHash = Get-TreeHash $DataDir
$keysSha = if ($keysValue) { [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keysValue))).Replace('-', '').ToLowerInvariant() } else { '' }

$pooledHeavy = [System.Collections.Generic.List[uint64[]]]::new(); $pooledNames = @(); $pooledAll = 0; $pooledFailed = 0
$perRun = @(); $invalid = @()
for ($n = 1; $n -le $Runs; $n++) {
    $runDir = Join-Path $labelDir "run$n"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $runCache = Join-Path $runDir 'cache'; $runData = Join-Path $runDir 'data'
    Write-Host "run $n/${Runs}: copying the save and the warm cache"
    Copy-Tree $CacheDir $runCache; Copy-Tree $DataDir $runData
    $copyGate = Test-WarmCache $Engine $runCache $MinRecipes
    if (-not $copyGate.Ok) {
        Stop-Bench 3 "REFUSING TO RUN: the fresh copy of the cache is cold ($($copyGate.Reason)). The master was warm, so the copy lost the receipt's timestamps; the receipt records the library's mtime and shaders/ creation time."
    }
    $envSet = [ordered]@{
        VICTORY_GAME_DIR = (Split-Path -Parent (Resolve-Path -LiteralPath $Image).Path)
        VICTORY_CACHE_DIR = $runCache
        VICTORY_DATA_DIR = $runData
        VICTORY_STATS_SHM = '1'
    }
    if ($keysValue) { $envSet['VICTORY_KEYS'] = $keysValue }
    foreach ($k in $ExtraEnv.Keys) { $envSet[[string]$k] = [string]$ExtraEnv[$k] }
    Write-Host "run $n/${Runs}: playing ${Duration}s of monitor time"
    $r = Invoke-TitleRun $runDir $envSet $Duration
    if ($r.Names.Count -eq 0 -or $r.Rows.Count -eq 0) { $invalid += "run ${n}: $($r.Note)"; continue }
    Write-FramesCsv (Join-Path $runDir 'frames.csv') $r.Names $r.Rows $HeavyDraws
    $res = Get-RunSummary $r.Names $r.Rows $HeavyDraws $Duration
    Write-KeyedCsv (Join-Path $runDir 'summary.csv') $res.Summary
    Write-TableCsv (Join-Path $runDir 'buckets.csv') $res.Buckets
    $why = Get-Invalid $res.Summary $r.Lost $r.Note $MinHeavyFrames
    foreach ($w in $why) { $invalid += "run ${n}: $w" }
    $perRun += $res.Summary
    $pooledNames = $r.Names
    $pooledAll += $res.Summary.frames_total; $pooledFailed += $res.Summary.frames_failed
    foreach ($x in $res.Heavy) { $pooledHeavy.Add($x) }
    Remove-Item -LiteralPath $runCache, $runData -Recurse -Force   # keep the CSVs, drop multi-GB copies
    Write-Host ("run {0}: {1} heavy frames, p50 {2:F1} ms, p95 {3:F1} ms" -f $n, $res.Summary.heavy_frames, $res.Summary.p50_ms, $res.Summary.p95_ms)
}

if ($perRun.Count -eq 0) { Stop-Bench 4 "no usable run: $($invalid -join '; ')" }

# Pool heavy frames of all runs (rows keep per-run timestamps, so window each run on its own first).
$sumAll = Get-SummaryFromHeavy (Get-FieldIndex $pooledNames) $pooledHeavy $pooledAll $pooledFailed $HeavyDraws
Write-KeyedCsv (Join-Path $labelDir 'summary.csv') $sumAll.Summary
Write-TableCsv (Join-Path $labelDir 'buckets.csv') $sumAll.Buckets
$spread = if ($perRun.Count -gt 1) { $p = $perRun | ForEach-Object { $_.p50_ms }; (($p | Measure-Object -Maximum).Maximum - ($p | Measure-Object -Minimum).Minimum) / (($p | Measure-Object -Minimum).Minimum) * 100 } else { 0.0 }
[ordered]@{
    label = $Label; utc = (Get-Date).ToUniversalTime().ToString('o'); runs = $perRun.Count; duration_s = $Duration
    heavy_draws = $HeavyDraws; engine = $Engine; engine_sha256 = $engineSha; data_tree_sha256 = $dataHash
    keys_sha256 = $keysSha; extra_env = $ExtraEnv; recipes = $gate.Recipes; run_p50_spread_pct = $spread
    invalid = $invalid; facts = Get-HostFacts
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $labelDir 'meta.json') -Encoding utf8

$s = $sumAll.Summary
Write-Host ''
Write-Host ("{0}: {1} heavy frames over {2} run(s)" -f $Label, $s.heavy_frames, $perRun.Count)
Write-Host ("  median {0:F1} ms   p95 {1:F1} ms   p99 {2:F1} ms   mean {3:F1} ms   gpu busy {4:F0} %" -f $s.p50_ms, $s.p95_ms, $s.p99_ms, $s.mean_ms, $s.gpu_busy_pct)
Write-Host ("  submit thread per heavy frame: work {0:F1} ms, waits {1:F1} ms   title {2:F1} ms   present call {3:F2} ms" -f $s.submit_work_ms, $s.submit_wait_ms, $s.title_ms, $s.present_call_ms)
if ($spread -gt $Threshold) { Write-Host ("WARNING: per-run medians differ by {0:F1}%, more than the {1}% gate. Add runs before trusting a delta." -f $spread, $Threshold) }
if ($invalid.Count) { Write-Host "INVALID: $($invalid -join '; ')"; Write-Host "results kept in $labelDir but must not be used as a baseline"; exit 4 }

if ($SaveBaselineAs) {
    $dest = Join-Path (Join-Path $BenchDir 'baselines') $SaveBaselineAs
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($f in 'summary.csv', 'buckets.csv', 'meta.json') { Copy-Item -LiteralPath (Join-Path $labelDir $f) -Destination $dest -Force }
    Write-Host "baseline stored: $dest"
}
if ($Baseline) {
    $b = Read-SummaryCsv $Baseline
    if (-not $b) { Stop-Bench 2 "no baseline summary at '$Baseline'" }
    $cur = Read-SummaryCsv $labelDir
    $r = Compare-Summaries $b $cur $Threshold (Read-BucketsCsv $Baseline) (Read-BucketsCsv $labelDir)
    Write-Host ''; $r.Lines | ForEach-Object { Write-Host $_ }
    exit $r.Exit
}
exit 0
