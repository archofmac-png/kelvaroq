#requires -Version 7.0
<#
.SYNOPSIS
  Render gate for SCARLETT perf patches: compare a candidate capture set with a stored reference.
  Protocol: bench/PROTOCOL.md ("Render gate"). Sets are produced by bench/capture.ps1.

.DESCRIPTION
  1. Compatibility: refuses to compare sets whose declared frame lists, save-tree hash, keys hash,
     console profile, frame-file pattern or dump-target setting differ, or whose files do not match
     their own manifest (modified or truncated after capture), or when the reference is incomplete.
  2. Exact pass: SHA-256 per file. Identical bytes -> unchanged.
  3. Perceptual pass on files whose bytes differ (PNG, 8/16-bit, non-interlaced): mean absolute
     difference per channel, share of changed and visibly changed pixels, bounding box of the visible
     change, a tile grid of per-tile MAD, and an edge-map comparison (luma gradient) to tell geometry
     that moved from colour that changed.
  4. Class per file: unchanged | sub-visible | visible | structural | missing | extra.
     A differing file that cannot be decoded is classed visible (it can never pass silently).
  5. Markdown report (and a JSON twin) for pasting into a review.

  Exit codes
    0  every file byte-identical
    1  sub-visible differences only
    2  at least one visible or structural difference (or an extra file in the candidate)
    3  at least one missing file (takes precedence over 2: a set with holes proves nothing)
    4  REFUSED: sets are not comparable or a set is invalid. No verdict. Blocks like 2 and 3.
    5  usage / environment error

  The thresholds are judgement calls. They have NOT been calibrated against real captures of the
  title. Calibrate with a determinism control (capture the same build twice and verify: must be 0)
  and one known change before trusting the sub-visible/visible boundary.
#>
[CmdletBinding()]
param(
    [ValidateSet('Verify', 'SelfTest')][string]$Mode = 'Verify',
    [string]$Reference,                 # set directory, or a name under -CapturesDir
    [string]$Candidate,                 # set directory, or a name under -CapturesDir
    [string]$CapturesDir,               # default bench/out/captures
    [string]$ReportPath,                # default bench/out/reports/verify-<candidate>-vs-<reference>.md
    [double]$SubVisibleMad = 0.5,       # mean abs RGB difference (0-255) above which a frame is visible
    [int]$VisibleDelta = 8,             # a pixel is "visibly changed" when any channel differs by >= this
    [double]$VisiblePixelFraction = 0.0005,   # visible when more than this share of pixels visibly changed
    [int]$EdgeThreshold = 24,           # luma gradient (|dx|+|dy|) at or above which a pixel is an edge
    [double]$StructuralEdgeRatio = 0.05,      # structural when edge-map XOR / union reaches this ...
    [double]$StructuralMinEdgeFraction = 0.0002, # ... and the XOR is at least this share of all pixels
    [int]$GridX = 8,
    [int]$GridY = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ci = [System.Globalization.CultureInfo]::InvariantCulture
$BenchDir = $PSScriptRoot
$SchemaVersion = 1

# ---- pixel work in C#: PowerShell loops over 8 M pixels are not an option --------------------------
$csharp = @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace Rv {
  public sealed class Img { public int W, H; public byte[] Rgba; public bool HasAlpha; }

  public sealed class Diff {
    public long Pixels, Changed, Visible, EdgeA, EdgeB, EdgeXor, EdgeUnion;
    public double[] ChannelMad = new double[4];
    public double RgbMad;
    public int MaxDelta;
    public int GridX, GridY;
    public double[] TileMad;
    public long[] TileVisible;
    public int BoxX0 = -1, BoxY0 = -1, BoxX1 = -1, BoxY1 = -1;
  }

  public static class Png {
    static readonly byte[] Sig = { 137, 80, 78, 71, 13, 10, 26, 10 };
    static uint[] table;

    static uint Crc(byte[] b, int off, int len) {
      if (table == null) {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[n] = c; }
        table = t;
      }
      uint crc = 0xFFFFFFFFu;
      for (int i = 0; i < len; i++) crc = table[(crc ^ b[off + i]) & 0xFF] ^ (crc >> 8);
      return crc ^ 0xFFFFFFFFu;
    }
    static uint BE(byte[] b, int p) { return ((uint)b[p] << 24) | ((uint)b[p + 1] << 16) | ((uint)b[p + 2] << 8) | b[p + 3]; }
    static void PutBE(Stream s, uint v) { s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v); }

    public static Img Decode(byte[] f) {
      if (f.Length < 8 + 12 + 13 + 12) throw new InvalidDataException("file too short for a PNG");
      for (int i = 0; i < 8; i++) if (f[i] != Sig[i]) throw new InvalidDataException("not a PNG (bad signature)");
      int pos = 8, w = 0, h = 0, depth = 0, ct = 0, interlace = 0;
      bool ihdr = false, iend = false;
      var idat = new MemoryStream();
      byte[] plte = null, trns = null;
      while (pos + 12 <= f.Length && !iend) {
        uint len = BE(f, pos);
        if (len > 0x7FFFFFFF || pos + 12L + len > f.Length) throw new InvalidDataException("truncated PNG chunk");
        int l = (int)len;
        string type = Encoding.ASCII.GetString(f, pos + 4, 4);
        if (Crc(f, pos + 4, 4 + l) != BE(f, pos + 8 + l)) throw new InvalidDataException("CRC mismatch in " + type);
        int d = pos + 8;
        if (type == "IHDR") {
          if (l != 13) throw new InvalidDataException("bad IHDR");
          w = (int)BE(f, d); h = (int)BE(f, d + 4); depth = f[d + 8]; ct = f[d + 9]; interlace = f[d + 12];
          if (f[d + 10] != 0 || f[d + 11] != 0) throw new InvalidDataException("unknown compression/filter method");
          ihdr = true;
        } else if (type == "PLTE") { plte = new byte[l]; Array.Copy(f, d, plte, 0, l); }
        else if (type == "tRNS") { trns = new byte[l]; Array.Copy(f, d, trns, 0, l); }
        else if (type == "IDAT") idat.Write(f, d, l);
        else if (type == "IEND") iend = true;
        pos += 12 + l;
      }
      if (!ihdr) throw new InvalidDataException("no IHDR");
      if (!iend) throw new InvalidDataException("no IEND (truncated file)");
      if (interlace != 0) throw new NotSupportedException("interlaced PNG");
      if (!(depth == 8 || depth == 16) || !(ct == 0 || ct == 2 || ct == 3 || ct == 4 || ct == 6) || (ct == 3 && depth != 8))
        throw new NotSupportedException("PNG depth " + depth + " colour type " + ct);
      if (w <= 0 || h <= 0 || (long)w * h > 134217728L) throw new InvalidDataException("unreasonable PNG size " + w + "x" + h);
      int channels = ct == 0 ? 1 : ct == 2 ? 3 : ct == 3 ? 1 : ct == 4 ? 2 : 4;
      int bpp = channels * depth / 8;
      long strideL = (long)w * bpp;
      if (strideL > 0x3FFFFFFF || (strideL + 1) * h > 0x7FFFFFC7L) throw new InvalidDataException("PNG too large");
      int stride = (int)strideL;
      byte[] raw = new byte[(stride + 1) * h];
      using (var z = new ZLibStream(new MemoryStream(idat.ToArray()), CompressionMode.Decompress)) {
        int got = 0;
        while (got < raw.Length) { int n = z.Read(raw, got, raw.Length - got); if (n <= 0) break; got += n; }
        if (got != raw.Length) throw new InvalidDataException("image data shorter than the header says");
      }
      for (int y = 0; y < h; y++) {
        int row = y * (stride + 1), prev = row - (stride + 1), ft = raw[row];
        row++; prev++;
        for (int x = 0; x < stride; x++) {
          int a = x >= bpp ? raw[row + x - bpp] : 0;
          int b = y > 0 ? raw[prev + x] : 0;
          int c = (y > 0 && x >= bpp) ? raw[prev + x - bpp] : 0;
          int v = raw[row + x], r;
          switch (ft) {
            case 0: r = v; break;
            case 1: r = v + a; break;
            case 2: r = v + b; break;
            case 3: r = v + ((a + b) >> 1); break;
            case 4: { int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c); r = v + ((pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)); break; }
            default: throw new InvalidDataException("bad PNG filter " + ft);
          }
          raw[row + x] = (byte)r;
        }
      }
      var img = new Img { W = w, H = h, Rgba = new byte[w * h * 4], HasAlpha = ct == 4 || ct == 6 || (ct == 3 && trns != null) };
      byte[] o = img.Rgba;
      int step = depth / 8;   // bytes per sample
      for (int y = 0; y < h; y++) {
        int row = y * (stride + 1) + 1;
        for (int x = 0; x < w; x++) {
          int s = row + x * bpp, q = (y * w + x) * 4;
          byte r, g, bl, al = 255;
          switch (ct) {
            case 0: r = g = bl = raw[s]; break;
            case 2: r = raw[s]; g = raw[s + step]; bl = raw[s + 2 * step]; break;
            case 3: {
              int i = raw[s];
              if (plte == null || i * 3 + 2 >= plte.Length) throw new InvalidDataException("palette index out of range");
              r = plte[i * 3]; g = plte[i * 3 + 1]; bl = plte[i * 3 + 2];
              if (trns != null && i < trns.Length) al = trns[i];
              break; }
            case 4: r = g = bl = raw[s]; al = raw[s + step]; break;
            default: r = raw[s]; g = raw[s + step]; bl = raw[s + 2 * step]; al = raw[s + 3 * step]; break;
          }
          o[q] = r; o[q + 1] = g; o[q + 2] = bl; o[q + 3] = al;
        }
      }
      return img;
    }

    // Test support: 8-bit RGBA PNG, filter 0. 'text' adds a tEXt chunk so bytes differ with identical pixels.
    public static byte[] Encode(int w, int h, byte[] rgba, string text, bool compress) {
      var ms = new MemoryStream();
      ms.Write(Sig, 0, 8);
      Action<string, byte[]> chunk = (type, data) => {
        PutBE(ms, (uint)data.Length);
        var td = new byte[4 + data.Length];
        Encoding.ASCII.GetBytes(type).CopyTo(td, 0); data.CopyTo(td, 4);
        ms.Write(td, 0, td.Length);
        PutBE(ms, Crc(td, 0, td.Length));
      };
      var ih = new MemoryStream();
      PutBE(ih, (uint)w); PutBE(ih, (uint)h); ih.WriteByte(8); ih.WriteByte(6); ih.WriteByte(0); ih.WriteByte(0); ih.WriteByte(0);
      chunk("IHDR", ih.ToArray());
      if (text != null) chunk("tEXt", Encoding.ASCII.GetBytes("Comment\0" + text));
      var rawStream = new MemoryStream();
      for (int y = 0; y < h; y++) { rawStream.WriteByte(0); rawStream.Write(rgba, y * w * 4, w * 4); }
      var comp = new MemoryStream();
      using (var z = new ZLibStream(comp, compress ? CompressionLevel.Optimal : CompressionLevel.NoCompression, true)) { rawStream.Position = 0; rawStream.CopyTo(z); }
      chunk("IDAT", comp.ToArray());
      chunk("IEND", new byte[0]);
      return ms.ToArray();
    }

    public static Diff Compare(Img a, Img b, int gx, int gy, int visDelta, int edgeThr) {
      if (a.W != b.W || a.H != b.H) throw new ArgumentException("image sizes differ");
      int w = a.W, h = a.H; long n = (long)w * h;
      var d = new Diff { Pixels = n, GridX = gx, GridY = gy, TileMad = new double[gx * gy], TileVisible = new long[gx * gy] };
      var tileSum = new long[gx * gy]; var tileCnt = new long[gx * gy]; var ch = new long[4];
      var la = new byte[n]; var lb = new byte[n];
      byte[] A = a.Rgba, B = b.Rgba;
      var colTile = new int[w];
      for (int x = 0; x < w; x++) colTile[x] = (int)((long)x * gx / w);
      for (int y = 0; y < h; y++) {
        int rowTile = (int)((long)y * gy / h) * gx;
        for (int x = 0; x < w; x++) {
          int i = y * w + x, p = i * 4;
          int dr = Math.Abs(A[p] - B[p]), dg = Math.Abs(A[p + 1] - B[p + 1]), db = Math.Abs(A[p + 2] - B[p + 2]), da = Math.Abs(A[p + 3] - B[p + 3]);
          ch[0] += dr; ch[1] += dg; ch[2] += db; ch[3] += da;
          int m = Math.Max(Math.Max(dr, dg), Math.Max(db, da));
          if (m > d.MaxDelta) d.MaxDelta = m;
          if (m > 0) d.Changed++;
          int t = rowTile + colTile[x];
          tileSum[t] += dr + dg + db; tileCnt[t]++;
          if (m >= visDelta) {
            d.Visible++; d.TileVisible[t]++;
            if (d.BoxX0 < 0 || x < d.BoxX0) d.BoxX0 = x;
            if (d.BoxX1 < 0 || x > d.BoxX1) d.BoxX1 = x;
            if (d.BoxY0 < 0) d.BoxY0 = y;
            d.BoxY1 = y;
          }
          la[i] = (byte)((54 * A[p] + 183 * A[p + 1] + 19 * A[p + 2]) >> 8);
          lb[i] = (byte)((54 * B[p] + 183 * B[p + 1] + 19 * B[p + 2]) >> 8);
        }
      }
      for (int c = 0; c < 4; c++) d.ChannelMad[c] = ch[c] / (double)n;
      d.RgbMad = (ch[0] + ch[1] + ch[2]) / (3.0 * n);
      for (int t = 0; t < tileSum.Length; t++) d.TileMad[t] = tileCnt[t] > 0 ? tileSum[t] / (3.0 * tileCnt[t]) : 0;
      for (int y = 0; y < h - 1; y++) {
        for (int x = 0; x < w - 1; x++) {
          int i = y * w + x;
          bool ea = Math.Abs(la[i + 1] - la[i]) + Math.Abs(la[i + w] - la[i]) >= edgeThr;
          bool eb = Math.Abs(lb[i + 1] - lb[i]) + Math.Abs(lb[i + w] - lb[i]) >= edgeThr;
          if (ea) d.EdgeA++;
          if (eb) d.EdgeB++;
          if (ea != eb) d.EdgeXor++;
          if (ea || eb) d.EdgeUnion++;
        }
      }
      return d;
    }
  }
}
'@
Add-Type -AssemblyName System.IO.Compression
if (-not ('Rv.Png' -as [type])) { Add-Type -TypeDefinition $csharp -Language CSharp }

# ---- helpers ------------------------------------------------------------------------------------
function Stop-Verify([int]$Code, [string]$Message) {
    [Console]::Error.WriteLine("render-verify.ps1: $Message")
    exit $Code
}
function Get-Prop($Obj, [string]$Name, $Default = $null) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
    return $Default
}
function Get-FileSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-NaturalKey([string]$s) { [regex]::Replace($s, '\d+', { param($m) $m.Value.PadLeft(10, '0') }) }
function Get-DefaultCapturesDir { Join-Path (Join-Path $BenchDir 'out') 'captures' }

function Resolve-SetDir([string]$Spec, [string]$Root) {
    if (-not $Spec) { return $null }
    if (Test-Path -LiteralPath $Spec -PathType Container) { return (Resolve-Path -LiteralPath $Spec).Path }
    $p = Join-Path $Root $Spec
    if (Test-Path -LiteralPath $p -PathType Container) { return (Resolve-Path -LiteralPath $p).Path }
    return $null
}

# Loads and validates one capture set. Never throws for a bad set: returns Problems instead.
# A set is valid when capture.json parses, every manifest entry exists with its recorded size and
# SHA-256, and nothing unrecorded sits in capture/. A frame the engine never produced is NOT a
# problem here: it is simply absent from the manifest (the comparison reports it as missing).
function Read-CaptureSet([string]$Dir) {
    $set = @{ Dir = $Dir; Name = (Split-Path -Leaf $Dir); Meta = $null; Files = @{}; Problems = [System.Collections.Generic.List[string]]::new() }
    $sidecar = Join-Path $Dir 'capture.json'
    if (-not (Test-Path -LiteralPath $sidecar)) { $set.Problems.Add('no capture.json: not a capture set (or the capture never finished writing its sidecar)'); return $set }
    try { $meta = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json -Depth 20 } catch { $set.Problems.Add("capture.json does not parse: $($_.Exception.Message)"); return $set }
    $set.Meta = $meta
    if ((Get-Prop $meta 'schema') -ne $SchemaVersion) { $set.Problems.Add("capture.json schema $(Get-Prop $meta 'schema' '?') (this verifier reads $SchemaVersion)"); return $set }
    $capDir = Join-Path $Dir 'capture'
    $seen = @{}
    foreach ($f in @(Get-Prop $meta 'files' @())) {
        $rel = [string]$f.path
        $full = Join-Path $capDir ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $set.Problems.Add("manifest lists '$rel' but the file is gone"); continue }
        $len = (Get-Item -LiteralPath $full).Length
        if ($len -ne [int64]$f.bytes) { $set.Problems.Add("'$rel' is $len bytes, manifest says $($f.bytes): modified after capture"); continue }
        $sha = Get-FileSha $full
        if ($sha -ne [string]$f.sha256) { $set.Problems.Add("'$rel' hash differs from its manifest entry: modified after capture"); continue }
        $set.Files[$rel.ToLowerInvariant()] = @{ Path = $rel; Full = $full; Bytes = $len; Sha = $sha }
        $seen[$rel.ToLowerInvariant()] = $true
    }
    if (Test-Path -LiteralPath $capDir -PathType Container) {
        $base = (Resolve-Path -LiteralPath $capDir).Path.TrimEnd('\', '/')
        foreach ($f in Get-ChildItem -LiteralPath $capDir -File -Recurse) {
            $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
            if (-not $seen.ContainsKey($rel.ToLowerInvariant())) { $set.Problems.Add("'$rel' is in capture/ but not in the manifest") }
        }
    }
    return $set
}

function Get-FrameList($Meta) { @(Get-Prop $Meta 'frames' @()) | ForEach-Object { [int]$_ } }

# Returns a list of refusal reasons; empty means comparable.
function Test-Comparable($Ref, $Cand) {
    $why = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @(@{ L = 'reference'; S = $Ref }, @{ L = 'candidate'; S = $Cand })) {
        foreach ($p in $s.S.Problems) { $why.Add("$($s.L) set '$($s.S.Name)': $p") }
    }
    if ($why.Count) { return $why }
    $rm = $Ref.Meta; $cm = $Cand.Meta
    if ((Get-Prop $rm 'status') -ne 'complete') {
        $why.Add("reference set '$($Ref.Name)' has status '$(Get-Prop $rm 'status' '?')': an incomplete capture is never a reference")
    }
    $rf = @(Get-FrameList $rm); $cf = @(Get-FrameList $cm)
    if ($rf.Count -ne $cf.Count) { $why.Add("frame counts differ: reference $($rf.Count), candidate $($cf.Count)") }
    elseif (($rf -join ',') -ne ($cf -join ',')) { $why.Add("frame lists differ: reference [$($rf -join ',')], candidate [$($cf -join ',')]") }
    foreach ($k in 'save_tree_sha256', 'keys_sha256') {
        $a = Get-Prop $rm $k ''; $b = Get-Prop $cm $k ''
        if (-not $a -or -not $b) { $why.Add("$k is missing from a sidecar") }
        elseif ($a -ne $b) { $why.Add("$k differs: reference $($a.Substring(0, 12)), candidate $($b.Substring(0, 12))") }
    }
    foreach ($k in 'console_profile', 'frame_pattern', 'dump_targets') {
        $a = [string](Get-Prop $rm $k ''); $b = [string](Get-Prop $cm $k '')
        if ($a -ne $b) { $why.Add("$k differs: reference '$a', candidate '$b'") }
    }
    return $why
}

function Get-FrameClass($D, [bool]$SizeMatch, $Opt) {
    if (-not $SizeMatch) { return @{ Class = 'structural'; Note = 'image dimensions differ' } }
    if ($D.Changed -eq 0) { return @{ Class = 'sub-visible'; Note = 'pixels identical, file bytes differ (encoder or metadata)' } }
    $minEdge = [math]::Ceiling($Opt.StructuralMinEdgeFraction * $D.Pixels)
    $ratio = if ($D.EdgeUnion -gt 0) { $D.EdgeXor / [double]$D.EdgeUnion } else { 0.0 }
    if ($D.EdgeXor -ge $minEdge -and $ratio -ge $Opt.StructuralEdgeRatio) {
        return @{ Class = 'structural'; Note = ('edge map moved: {0} of {1} edge pixels differ ({2:P1})' -f $D.EdgeXor, $D.EdgeUnion, $ratio) }
    }
    $vf = $D.Visible / [double]$D.Pixels
    if ($D.RgbMad -gt $Opt.SubVisibleMad -or $vf -gt $Opt.VisiblePixelFraction) {
        $why = if ($D.RgbMad -gt $Opt.SubVisibleMad) { ('RGB MAD {0:F3} > {1}' -f $D.RgbMad, $Opt.SubVisibleMad) } else { ('{0:P3} of pixels changed by >= {1} > {2:P3}' -f $vf, $Opt.VisibleDelta, $Opt.VisiblePixelFraction) }
        return @{ Class = 'visible'; Note = $why }
    }
    return @{ Class = 'sub-visible'; Note = '' }
}

function Compare-OneFile($RefFile, $CandFile, $Opt) {
    $row = [pscustomobject]@{ Path = $RefFile.Path; Class = ''; BytesEqual = $false; Note = ''; Diff = $null; RefBytes = $RefFile.Bytes; CandBytes = $CandFile.Bytes }
    if ($RefFile.Sha -eq $CandFile.Sha) { $row.Class = 'unchanged'; $row.BytesEqual = $true; return $row }
    $isPng = $RefFile.Path -match '\.png$' -and $CandFile.Path -match '\.png$'
    if (-not $isPng) { $row.Class = 'visible'; $row.Note = 'bytes differ and the file type has no decoder: treated as visible'; return $row }
    try {
        $a = [Rv.Png]::Decode([IO.File]::ReadAllBytes($RefFile.Full))
        $b = [Rv.Png]::Decode([IO.File]::ReadAllBytes($CandFile.Full))
    } catch {
        $row.Class = 'visible'; $row.Note = "bytes differ and a PNG did not decode ($($_.Exception.Message)): treated as visible"; return $row
    }
    $size = ($a.W -eq $b.W -and $a.H -eq $b.H)
    if (-not $size) {
        $row.Class = 'structural'; $row.Note = "dimensions differ: reference $($a.W)x$($a.H), candidate $($b.W)x$($b.H)"; return $row
    }
    $d = [Rv.Png]::Compare($a, $b, $Opt.GridX, $Opt.GridY, $Opt.VisibleDelta, $Opt.EdgeThreshold)
    $c = Get-FrameClass $d $true $Opt
    $row.Class = $c.Class; $row.Note = $c.Note; $row.Diff = $d
    if ($a.HasAlpha -ne $b.HasAlpha) { $row.Note = (($row.Note, 'alpha channel present on one side only') | Where-Object { $_ }) -join '; ' }
    return $row
}

$Severity = @{ 'unchanged' = 0; 'sub-visible' = 1; 'visible' = 2; 'structural' = 2; 'extra' = 2; 'missing' = 3 }

# Core. Returns @{ Exit; Refusal (string[]); Rows; Report (string); Json (object) }. Never calls exit.
function Invoke-Verify([string]$RefDir, [string]$CandDir, $Opt) {
    $ref = Read-CaptureSet $RefDir; $cand = Read-CaptureSet $CandDir
    $why = @(Test-Comparable $ref $cand)
    if ($why.Count) { return @{ Exit = 4; Refusal = $why; Rows = @(); Report = $null; Json = $null } }

    $keys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($k in $ref.Files.Keys) { [void]$keys.Add($k) }
    foreach ($k in $cand.Files.Keys) { [void]$keys.Add($k) }
    # Files the sidecar promised for each declared frame but the candidate never produced are missing
    # even when the reference lacks them too (cannot happen for a complete reference, kept explicit).
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($k in ($keys | Sort-Object { Get-NaturalKey $_ })) {
        $rf = $ref.Files[$k]; $cf = $cand.Files[$k]
        if ($rf -and -not $cf) { $rows.Add([pscustomobject]@{ Path = $rf.Path; Class = 'missing'; BytesEqual = $false; Note = 'in the reference, not in the candidate'; Diff = $null; RefBytes = $rf.Bytes; CandBytes = 0 }); continue }
        if ($cf -and -not $rf) { $rows.Add([pscustomobject]@{ Path = $cf.Path; Class = 'extra'; BytesEqual = $false; Note = 'in the candidate, not in the reference: nothing to verify it against'; Diff = $null; RefBytes = 0; CandBytes = $cf.Bytes }); continue }
        $rows.Add((Compare-OneFile $rf $cf $Opt))
    }
    $worst = 0
    foreach ($r in $rows) { $worst = [math]::Max($worst, $Severity[$r.Class]) }
    $exit = $worst
    $report = Format-Report $ref $cand $rows $exit $Opt
    $json = [ordered]@{
        schema = 1; reference = $ref.Name; candidate = $cand.Name; exit = $exit
        counts = [ordered]@{}
        files = @($rows | ForEach-Object {
                $o = [ordered]@{ path = $_.Path; class = $_.Class; bytes_equal = $_.BytesEqual; note = $_.Note }
                if ($_.Diff) {
                    $o.rgb_mad = $_.Diff.RgbMad; $o.channel_mad = @($_.Diff.ChannelMad); $o.max_delta = $_.Diff.MaxDelta
                    $o.changed_pixel_fraction = $_.Diff.Changed / [double]$_.Diff.Pixels
                    $o.visible_pixel_fraction = $_.Diff.Visible / [double]$_.Diff.Pixels
                    $o.edge_xor = $_.Diff.EdgeXor; $o.edge_union = $_.Diff.EdgeUnion
                    $o.tile_mad = @($_.Diff.TileMad)
                }
                $o })
        thresholds = [ordered]@{ sub_visible_mad = $Opt.SubVisibleMad; visible_delta = $Opt.VisibleDelta; visible_pixel_fraction = $Opt.VisiblePixelFraction; edge_threshold = $Opt.EdgeThreshold; structural_edge_ratio = $Opt.StructuralEdgeRatio; structural_min_edge_fraction = $Opt.StructuralMinEdgeFraction; grid = "$($Opt.GridX)x$($Opt.GridY)"; calibrated = $false }
    }
    foreach ($c in 'unchanged', 'sub-visible', 'visible', 'structural', 'extra', 'missing') { $json.counts[$c] = @($rows | Where-Object { $_.Class -eq $c }).Count }
    return @{ Exit = $exit; Refusal = @(); Rows = $rows; Report = $report; Json = $json }
}

# ---- report -------------------------------------------------------------------------------------
function Format-Report($Ref, $Cand, $Rows, [int]$Exit, $Opt) {
    $L = [System.Collections.Generic.List[string]]::new()
    $meaning = switch ($Exit) {
        0 { 'IDENTICAL: every file is byte-for-byte equal to the reference.' }
        1 { 'SUB-VISIBLE ONLY: differences exist but sit below the visibility thresholds. Mergeable under the render gate.' }
        2 { 'VISIBLE OR STRUCTURAL: the picture changed. **Blocks the merge regardless of frame time.**' }
        3 { 'MISSING FRAMES: the candidate lacks files the reference has. **Blocks the merge regardless of frame time.**' }
    }
    $L.Add("# Render verify: ``$($Cand.Name)`` vs reference ``$($Ref.Name)``")
    $L.Add('')
    $L.Add("**Exit $Exit.** $meaning")
    $L.Add('')
    $L.Add('| class | files |'); $L.Add('|---|---:|')
    foreach ($c in 'unchanged', 'sub-visible', 'visible', 'structural', 'extra', 'missing') { $L.Add("| $c | $(@($Rows | Where-Object { $_.Class -eq $c }).Count) |") }
    $L.Add('')
    $L.Add('## Sets'); $L.Add('')
    $L.Add('| | reference | candidate |'); $L.Add('|---|---|---|')
    $short = { param($v) $s = [string]$v; if ($s.Length -gt 12) { $s.Substring(0, 12) } else { $s } }
    foreach ($k in 'status', 'utc', 'engine_sha256', 'save_tree_sha256', 'keys_sha256', 'console_profile', 'frame_pattern', 'dump_targets') {
        $a = & $short (Get-Prop $Ref.Meta $k ''); $b = & $short (Get-Prop $Cand.Meta $k '')
        $L.Add("| $k | ``$a`` | ``$b`` |")
    }
    $L.Add("| frames | $(@(Get-FrameList $Ref.Meta).Count): $((Get-FrameList $Ref.Meta) -join ', ') | $(@(Get-FrameList $Cand.Meta).Count): $((Get-FrameList $Cand.Meta) -join ', ') |")
    $L.Add('')
    $L.Add('## Per file'); $L.Add('')
    $L.Add('| file | class | MAD rgb | R | G | B | A | max Δ | changed px | visible px | edge Δ | note |')
    $L.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|')
    foreach ($r in $Rows) {
        if ($r.Diff) {
            $d = $r.Diff
            $L.Add(('| {0} | **{1}** | {2:F3} | {3:F3} | {4:F3} | {5:F3} | {6:F3} | {7} | {8:P3} | {9:P3} | {10}/{11} | {12} |' -f $r.Path, $r.Class, $d.RgbMad, $d.ChannelMad[0], $d.ChannelMad[1], $d.ChannelMad[2], $d.ChannelMad[3], $d.MaxDelta, ($d.Changed / [double]$d.Pixels), ($d.Visible / [double]$d.Pixels), $d.EdgeXor, $d.EdgeUnion, $r.Note))
        } else {
            $L.Add("| $($r.Path) | **$($r.Class)** | | | | | | | | | | $($r.Note) |")
        }
    }
    $withDiff = @($Rows | Where-Object { $_.Diff -and $_.Class -ne 'unchanged' -and $_.Diff.Changed -gt 0 })
    if ($withDiff.Count) {
        $L.Add(''); $L.Add("## Where it changed (tile grid $($Opt.GridX)x$($Opt.GridY), mean abs RGB difference per tile, 0-255)"); $L.Add('')
        foreach ($r in $withDiff) {
            $d = $r.Diff
            $L.Add("### $($r.Path) — $($r.Class)"); $L.Add('')
            if ($d.BoxX0 -ge 0) { $L.Add("Visible change bounding box: x $($d.BoxX0)..$($d.BoxX1), y $($d.BoxY0)..$($d.BoxY1) (pixels changed by >= $($Opt.VisibleDelta)).") ; $L.Add('') }
            $order = 0..($d.TileMad.Count - 1) | Sort-Object { -$d.TileMad[$_] } | Select-Object -First 3
            $L.Add('Worst tiles: ' + (($order | Where-Object { $d.TileMad[$_] -gt 0 } | ForEach-Object { 'col {0} row {1}: {2:F2}' -f ($_ % $d.GridX), [math]::Floor($_ / $d.GridX), $d.TileMad[$_] }) -join '; '))
            $L.Add(''); $L.Add('```')
            for ($y = 0; $y -lt $d.GridY; $y++) {
                $L.Add((0..($d.GridX - 1) | ForEach-Object { '{0,7:F2}' -f $d.TileMad[$y * $d.GridX + $_] }) -join '')
            }
            $L.Add('```'); $L.Add('')
        }
    }
    $L.Add('## Thresholds'); $L.Add('')
    $L.Add(('Sub-visible: RGB MAD <= {0} and at most {1:P3} of pixels changed by >= {2}. Structural: edge-map XOR >= {3:P3} of all pixels and >= {4:P0} of the edge union (luma gradient >= {5}). **These are uncalibrated.** Run a determinism control (same build captured twice must verify to exit 0) and one known change before trusting the boundary.' -f $Opt.SubVisibleMad, $Opt.VisiblePixelFraction, $Opt.VisibleDelta, $Opt.StructuralMinEdgeFraction, $Opt.StructuralEdgeRatio, $Opt.EdgeThreshold))
    $L.Add('')
    $L.Add('Exit codes: 0 identical, 1 sub-visible only, 2 visible or structural, 3 missing frames, 4 refused (sets not comparable).')
    return ($L -join "`n") + "`n"
}

function Write-AtomicText([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---- self test ----------------------------------------------------------------------------------
function New-TestPixels([int]$W, [int]$H, [int]$RectX = 40) {
    $px = [byte[]]::new($W * $H * 4)
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $i = ($y * $W + $x) * 4
            $px[$i] = [byte]($x * 255 / $W); $px[$i + 1] = [byte]($y * 255 / $H); $px[$i + 2] = [byte](($x + $y) * 255 / ($W + $H)); $px[$i + 3] = 255
            if ($x -ge $RectX -and $x -lt $RectX + 60 -and $y -ge 40 -and $y -lt 100) { $px[$i] = 250; $px[$i + 1] = 250; $px[$i + 2] = 20 }
        }
    }
    return , $px
}

# Writes a capture set shaped like bench/capture.ps1's, from @{ 'frame-1.png' = bytes } .
function New-TestSet([string]$Root, [string]$Name, [hashtable]$Files, [hashtable]$Meta = @{}) {
    $dir = Join-Path $Root $Name; $cap = Join-Path $dir 'capture'
    New-Item -ItemType Directory -Force -Path $cap | Out-Null
    $entries = @()
    foreach ($k in $Files.Keys) {
        $p = Join-Path $cap $k; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        [IO.File]::WriteAllBytes($p, [byte[]]$Files[$k])
        $entries += [ordered]@{ path = $k; bytes = ([byte[]]$Files[$k]).Length; sha256 = Get-FileSha $p }
    }
    $m = [ordered]@{
        schema = 1; name = $Name; status = 'complete'; utc = '2000-01-01T00:00:00Z'; frames = @(1, 2, 3); frame_count = 3
        frame_pattern = 'frame-{0}.png'; dump_targets = $null; console_profile = 'series-x'
        save_tree_sha256 = ('a' * 64); keys_sha256 = ('b' * 64); engine_sha256 = ('c' * 64); files = $entries
    }
    foreach ($k in $Meta.Keys) { $m[$k] = $Meta[$k] }
    ConvertTo-Json -InputObject $m -Depth 8 | Set-Content -LiteralPath (Join-Path $dir 'capture.json') -Encoding utf8
    return $dir
}

function Invoke-SelfTest {
    $st = @{ fail = 0 }
    $check = { param($ok, $what) if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what" -ForegroundColor Red; $st.fail++ } }
    $Opt = @{ SubVisibleMad = $SubVisibleMad; VisibleDelta = $VisibleDelta; VisiblePixelFraction = $VisiblePixelFraction; EdgeThreshold = $EdgeThreshold; StructuralEdgeRatio = $StructuralEdgeRatio; StructuralMinEdgeFraction = $StructuralMinEdgeFraction; GridX = $GridX; GridY = $GridY }
    $root = Join-Path ([IO.Path]::GetTempPath()) "render-verify-selftest-$PID"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    try {
        $W = 256; $H = 192
        $base = New-TestPixels $W $H
        $png = { param($px, $text = $null, $compress = $true) , [Rv.Png]::Encode($W, $H, [byte[]]$px, $text, $compress) }
        $baseBytes = & $png $base
        $frames = 'frame-1.png', 'frame-2.png', 'frame-3.png'
        $mk = { param($name, $f1 = $baseBytes, $meta = @{}) New-TestSet $root $name @{ 'frame-1.png' = $f1; 'frame-2.png' = $baseBytes; 'frame-3.png' = $baseBytes } $meta }
        $ref = & $mk 'ref'
        $run = { param($name) $r = Invoke-Verify $ref (Join-Path $root $name) $Opt; $r }

        Write-Host 'png codec'
        $rt = [Rv.Png]::Decode($baseBytes)
        & $check ($rt.W -eq $W -and $rt.H -eq $H -and [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([byte[]]$rt.Rgba)) -eq [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([byte[]]$base))) 'encode -> decode round-trips pixels exactly'
        $threw = $false; try { [void][Rv.Png]::Decode([byte[]]$baseBytes[0..($baseBytes.Length - 20)]) } catch { $threw = $true }
        & $check $threw 'a truncated PNG is rejected'

        Write-Host 'classification'
        $null = & $mk 'same'
        $r = & $run 'same'; & $check ($r.Exit -eq 0 -and @($r.Rows | Where-Object Class -eq 'unchanged').Count -eq 3) 'identical set -> exit 0, three unchanged'

        $null = & $mk 'reenc' (& $png $base 'other encoder' $false)
        $r = & $run 'reenc'; & $check ($r.Exit -eq 1 -and $r.Rows[0].Class -eq 'sub-visible' -and $r.Rows[0].Note -match 'pixels identical') 'same pixels, different file bytes -> sub-visible, exit 1'

        $n = $base.Clone(); for ($i = 0; $i -lt $n.Length; $i += 16) { $n[$i] = [byte][math]::Min(255, $n[$i] + 1) }
        $null = & $mk 'noise' (& $png $n)
        $r = & $run 'noise'; & $check ($r.Exit -eq 1 -and $r.Rows[0].Class -eq 'sub-visible' -and -not $r.Rows[0].BytesEqual) '+1 on a quarter of one channel -> sub-visible, exit 1'

        $v = $base.Clone()
        for ($y = 120; $y -lt 170; $y++) { for ($x = 150; $x -lt 200; $x++) { $i = ($y * $W + $x) * 4; $v[$i] = [byte][math]::Min(255, $v[$i] + 40) } }
        $null = & $mk 'tint' (& $png $v)
        $r = & $run 'tint'
        & $check ($r.Exit -eq 2 -and $r.Rows[0].Class -eq 'visible') 'a tinted 50x50 block -> visible, exit 2'
        $d = $r.Rows[0].Diff
        & $check ($d.BoxX0 -eq 150 -and $d.BoxX1 -eq 199 -and $d.BoxY0 -eq 120 -and $d.BoxY1 -eq 169) 'bounding box of the visible change is exact'
        $hot = (0..($d.TileMad.Count - 1) | Sort-Object { -$d.TileMad[$_] })[0]
        & $check (($hot % 8) -eq 5 -and [math]::Floor($hot / 8) -in 5, 6) 'hottest tile is inside the block (col 5, row 5 or 6: both fully covered)'
        & $check ($r.Report -match 'col 5 row [56]' -and $r.Report -match '```') 'report names the hot tile and carries the grid'

        $s = New-TestPixels $W $H 56   # same scene, rectangle moved 16 px
        $null = & $mk 'moved' (& $png $s)
        $r = & $run 'moved'; & $check ($r.Exit -eq 2 -and $r.Rows[0].Class -eq 'structural') 'a moved rectangle -> structural, exit 2'

        $small = [Rv.Png]::Encode(128, 96, [byte[]](New-TestPixels 128 96), $null, $true)
        $null = & $mk 'resized' $small
        $r = & $run 'resized'; & $check ($r.Exit -eq 2 -and $r.Rows[0].Class -eq 'structural' -and $r.Rows[0].Note -match 'dimensions') 'different dimensions -> structural'

        $null = & $mk 'junk' ([byte[]](1..200))
        $r = & $run 'junk'; & $check ($r.Exit -eq 2 -and $r.Rows[0].Class -eq 'visible' -and $r.Rows[0].Note -match 'did not decode') 'bytes differ and file does not decode -> visible, never silent'

        $txt = New-TestSet $root 'dumpA' @{ 'frame-1.png' = $baseBytes; 'frame-2.png' = $baseBytes; 'frame-3.png' = $baseBytes; 'dump-1.bin' = [byte[]](1..50) }
        $txtB = New-TestSet $root 'dumpB' @{ 'frame-1.png' = $baseBytes; 'frame-2.png' = $baseBytes; 'frame-3.png' = $baseBytes; 'dump-1.bin' = [byte[]](1..51) }
        $r = Invoke-Verify $txt $txtB $Opt; & $check ($r.Exit -eq 2 -and ($r.Rows | Where-Object Path -eq 'dump-1.bin').Class -eq 'visible') 'a changed non-PNG dump is visible (exact-bytes only)'

        Write-Host 'missing and extra'
        $miss = New-TestSet $root 'miss' @{ 'frame-1.png' = $baseBytes; 'frame-3.png' = $baseBytes } @{ status = 'incomplete' }
        $r = & $run 'miss'; & $check ($r.Exit -eq 3 -and @($r.Rows | Where-Object Class -eq 'missing').Count -eq 1) 'a frame the candidate lacks -> missing, exit 3 (incomplete candidate is allowed)'
        $both = New-TestSet $root 'missvis' @{ 'frame-1.png' = (& $png $v); 'frame-3.png' = $baseBytes } @{ status = 'incomplete' }
        $r = & $run 'missvis'; & $check ($r.Exit -eq 3) 'missing outranks visible'
        $extra = New-TestSet $root 'extra' @{ 'frame-1.png' = $baseBytes; 'frame-2.png' = $baseBytes; 'frame-3.png' = $baseBytes; 'new.bin' = [byte[]](1..9) }
        $r = & $run 'extra'; & $check ($r.Exit -eq 2 -and ($r.Rows | Where-Object Path -eq 'new.bin').Class -eq 'extra') 'a file with no reference counterpart -> extra, exit 2'

        Write-Host 'refusals (exit 4, no verdict)'
        $null = & $mk 'cnt' $baseBytes @{ frames = @(1, 2); frame_count = 2 }
        $r = & $run 'cnt'; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'frame counts differ: reference 3, candidate 2') 'different frame counts'
        $null = & $mk 'lst' $baseBytes @{ frames = @(1, 2, 4) }
        $r = & $run 'lst'; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'frame lists differ') 'same count, different frames'
        $null = & $mk 'save' $baseBytes @{ save_tree_sha256 = ('d' * 64) }
        $r = & $run 'save'; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'save_tree_sha256 differs') 'different save hash'
        $null = & $mk 'keys' $baseBytes @{ keys_sha256 = ('e' * 64) }
        $r = & $run 'keys'; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'keys_sha256 differs') 'different input script'
        $null = & $mk 'prof' $baseBytes @{ console_profile = 'series-s' }
        $r = & $run 'prof'; & $check ($r.Exit -eq 4) 'different console profile'
        $incRef = & $mk 'incref' $baseBytes @{ status = 'incomplete' }
        $r = Invoke-Verify $incRef (Join-Path $root 'same') $Opt; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'never a reference') 'incomplete set as the reference'
        $tam = & $mk 'tamper'
        [IO.File]::WriteAllBytes((Join-Path $tam 'capture/frame-2.png'), [byte[]](1..30))
        $r = & $run 'tamper'; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'modified after capture') 'a file modified after capture'
        $stray = & $mk 'stray'
        [IO.File]::WriteAllBytes((Join-Path $stray 'capture/stray.png'), [byte[]](1..5))
        $r = & $run 'stray'; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'not in the manifest') 'an unrecorded file in capture/'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'nosidecar/capture') | Out-Null
        $r = Invoke-Verify $ref (Join-Path $root 'nosidecar') $Opt; & $check ($r.Exit -eq 4 -and ($r.Refusal -join ' ') -match 'no capture.json') 'a directory with no sidecar (crashed before it was written)'

        Write-Host 'report'
        $r = & $run 'tint'
        & $check ($r.Report -match 'Exit 2' -and $r.Report -match 'Blocks the merge' -and $r.Report -match 'uncalibrated') 'report states the exit, the block, and that thresholds are uncalibrated'
        & $check ($r.Json.counts.visible -eq 1 -and $r.Json.counts.unchanged -eq 2) 'json twin carries the counts'
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    if ($st.fail) { Write-Host "$($st.fail) self-test failure(s)" -ForegroundColor Red; exit 1 }
    Write-Host 'self-test passed'
    exit 0
}

# ---- entry --------------------------------------------------------------------------------------
if ($Mode -eq 'SelfTest') { Invoke-SelfTest }

if (-not $CapturesDir) { $CapturesDir = Get-DefaultCapturesDir }
if (-not $Reference -or -not $Candidate) { Stop-Verify 5 '-Reference and -Candidate are required' }
if ($GridX -lt 1 -or $GridY -lt 1 -or $GridX -gt 64 -or $GridY -gt 64) { Stop-Verify 5 '-GridX/-GridY must be 1..64' }
$refDir = Resolve-SetDir $Reference $CapturesDir
$candDir = Resolve-SetDir $Candidate $CapturesDir
if (-not $refDir) { Stop-Verify 5 "reference set not found: '$Reference' (also looked in $CapturesDir)" }
if (-not $candDir) { Stop-Verify 5 "candidate set not found: '$Candidate' (also looked in $CapturesDir)" }

$Opt = @{ SubVisibleMad = $SubVisibleMad; VisibleDelta = $VisibleDelta; VisiblePixelFraction = $VisiblePixelFraction; EdgeThreshold = $EdgeThreshold; StructuralEdgeRatio = $StructuralEdgeRatio; StructuralMinEdgeFraction = $StructuralMinEdgeFraction; GridX = $GridX; GridY = $GridY }
$res = Invoke-Verify $refDir $candDir $Opt
if ($res.Exit -eq 4 -and $res.Refusal.Count) {
    [Console]::Error.WriteLine('render-verify.ps1: REFUSED, the sets are not comparable (no verdict; this blocks a merge):')
    foreach ($w in $res.Refusal) { [Console]::Error.WriteLine("  - $w") }
    exit 4
}
if (-not $ReportPath) {
    $ReportPath = Join-Path (Join-Path (Join-Path $BenchDir 'out') 'reports') ("verify-{0}-vs-{1}.md" -f (Split-Path -Leaf $candDir), (Split-Path -Leaf $refDir))
}
Write-AtomicText $ReportPath $res.Report
Write-AtomicText ([IO.Path]::ChangeExtension($ReportPath, '.json')) ((ConvertTo-Json -InputObject $res.Json -Depth 8) + "`n")
$cnt = $res.Json.counts
Write-Host ("render-verify: exit {0}  unchanged {1}  sub-visible {2}  visible {3}  structural {4}  extra {5}  missing {6}" -f $res.Exit, $cnt.unchanged, $cnt['sub-visible'], $cnt.visible, $cnt.structural, $cnt.extra, $cnt.missing)
foreach ($r in @($res.Rows | Where-Object { $_.Class -ne 'unchanged' })) { Write-Host ("  {0,-12} {1}  {2}" -f $r.Class, $r.Path, $r.Note) }
Write-Host "report: $ReportPath"
exit $res.Exit
