using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace Kelvaroq {
/// Preflight: refuse early, with a fixable message, for the failure modes that otherwise
/// kill a run after launch. Every threshold below cites the document it comes from.
/// docs/RUNBOOK.md = RUNBOOK, FORGE-BRIEF.md = BRIEF. A number with no citation was given
/// by the requester in the task, and is marked "task spec".

internal enum PreflightLevel { Pass, Warn, Block, Skip }

internal sealed class PreflightResult {
    internal string Id, Name, Message;
    internal PreflightLevel Level;
    internal bool Advisory;
}

/// Thrown by Enforce. The message is already user-facing text, not a locale key.
internal sealed class PreflightBlocked : Exception {
    internal PreflightBlocked(string message) : base(message) {}
}

/// Everything a check reads. Probes fill it once; tests fill it by hand.
internal sealed class PreflightFacts {
    internal long? CommitLimit;          // bytes, null = could not read
    internal Hardware Hardware;          // null = detection disabled or failed
    internal string GameRoot, Image, CacheDir;
    internal List<string> Engines = new List<string>();  // "name (pid N)" per running engine
    internal bool? Gamepad;              // null = could not probe
    internal string[] RunPaths = new string[0];
    internal DateTime Now = DateTime.UtcNow;

    internal static PreflightFacts Live(Hardware hardware,string root,string image,string cache) {
        var facts = new PreflightFacts { Hardware = hardware, GameRoot = root, Image = image, CacheDir = cache,
            CommitLimit = Native.CommitLimit(), Gamepad = Native.Gamepad(), Now = DateTime.UtcNow,
            RunPaths = new[]{ Product.Base, image, root, cache }.Where(p => !String.IsNullOrEmpty(p)).ToArray() };
        try {
            foreach (string name in new[]{"kelvaroq-engine","victory"})
                foreach (var p in Process.GetProcessesByName(name)) using (p) facts.Engines.Add(name + ".exe (pid " + p.Id + ")");
        } catch (Exception) {}
        return facts;
    }

    /// For doctor: accept an .exe, a folder, or nothing. Prefer the manifest-aware selection and
    /// fall back to the raw path so a half-broken install is reported rather than thrown.
    internal static PreflightFacts Live(Hardware hardware,string selection,Preferences prefs) {
        string root = null, image = null;
        if (!String.IsNullOrWhiteSpace(selection)) {
            try { var game = Installation.Select(selection); root = game.Root; image = game.Image; }
            catch (Exception) {
                try {
                    string full = Path.GetFullPath(selection);
                    if (Directory.Exists(full)) root = full;
                    else { image = full; root = Path.GetDirectoryName(full); }
                } catch (Exception) {}
            }
        }
        return Live(hardware,root,image,prefs.ActiveCache);
    }

    static class Native {
        [StructLayout(LayoutKind.Sequential)] struct MemoryStatus {
            public uint Length, Load; public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtended;
        }
        [DllImport("kernel32.dll",SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MemoryStatus s);
        [StructLayout(LayoutKind.Sequential)] struct XState { public uint Packet; public ushort Buttons; public byte LT, RT; public short LX, LY, RX, RY; }
        [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint user,out XState state);

        /// ullTotalPageFile is the commit limit (RAM + paging files) for a 64-bit process.
        internal static long? CommitLimit() {
            try { var s = new MemoryStatus { Length = (uint)Marshal.SizeOf(typeof(MemoryStatus)) };
                  return GlobalMemoryStatusEx(ref s) ? (long?)checked((long)s.TotalPageFile) : null; }
            catch (Exception) { return null; }
        }
        internal static bool? Gamepad() {
            try { for (uint i = 0; i < 4; i++) { XState s; if (XInputGetState(i,out s) == 0) return true; } return false; }
            catch (Exception) { return null; }
        }
    }
}

internal sealed class PreflightOutcome {
    internal bool Proceed;
    internal string Report = "";
    internal List<PreflightResult> Overridden = new List<PreflightResult>();
}

internal static class Preflight {
    const string SkipVariable = "VICTORY_SKIP_PREFLIGHT";
    // RUNBOOK section 0: "32 GB RAM, 80 GB commit limit".
    const long CommitFloor = 80L << 30, RamRecommended = 32L << 30;
    // RUNBOOK section 0: "16 GB+ VRAM recommended | 12 GB is the floor; 8 GB drops head and skin meshes".
    const long VramFloorGiB = 12, VramRecommendedGiB = 16;
    // Task spec (not in a doc): driver older than 6 months.
    const int DriverMaxAgeMonths = 6;
    // bench/heavy.ps1 Test-WarmCache file checks (-MinRecipes default 1, heavy.ps1:35); RUNBOOK section 3 "Cold pipeline cache".
    const int MinRecipes = 1;
    // RUNBOOK section 0: "D3D12 GPU, shader model 6.6, mesh shaders"; FL 12_0 is the existing Gpu.fl12 meaning.
    internal static string SkipRequested { get { return Environment.GetEnvironmentVariable(SkipVariable); } }

    static string G(long bytes) { return (bytes / (double)(1L << 30)).ToString("0.#",CultureInfo.InvariantCulture) + " GiB"; }

    static PreflightResult Make(string id,string name,bool advisory,PreflightLevel level,string message) {
        return new PreflightResult { Id = id, Name = name, Advisory = advisory, Level = level, Message = message };
    }

    /// A probe that throws can never block: it becomes a warning that the check could not run.
    internal static PreflightResult Guarded(string id,string name,bool advisory,Func<PreflightResult> check) {
        try { return check(); }
        catch (Exception ex) { return Make(id,name,advisory,PreflightLevel.Warn,"could not verify: " + ex.Message); }
    }

    // Only a definite "no" blocks; "unknown" is a warning for blocking checks, a skip for advisory ones.
    static PreflightResult Capability(string id,string name,PreflightFacts f,Func<Gpu,bool?> read,string missing,string fix) {
        var gpu = f.Hardware == null ? null : f.Hardware.Preferred;
        if (gpu == null) return Make(id,name,false,PreflightLevel.Warn,"no GPU detected, cannot verify " + missing + ". Fix: install the GPU driver or unset VICTORY_LAUNCHER_HARDWARE=0.");
        var value = read(gpu);
        if (!value.HasValue) return Make(id,name,false,PreflightLevel.Warn,missing + " could not be verified on " + gpu.name + ".");
        return value.Value ? Make(id,name,false,PreflightLevel.Pass,gpu.name + ": ok")
                           : Make(id,name,false,PreflightLevel.Block,gpu.name + " lacks " + missing + ". Fix: " + fix);
    }

    internal static List<PreflightResult> Run(PreflightFacts f) {
        var list = new List<PreflightResult>();
        // ---- blocking set ----
        list.Add(Guarded("commit","Commit limit",false,() => {
            if (!f.CommitLimit.HasValue) return Make("commit","Commit limit",false,PreflightLevel.Warn,"commit limit could not be read.");
            long limit = f.CommitLimit.Value;
            if (limit >= CommitFloor) return Make("commit","Commit limit",false,PreflightLevel.Pass,G(limit) + " (need " + G(CommitFloor) + ")");
            long ram = f.Hardware != null && f.Hardware.ram.HasValue ? f.Hardware.ram.Value : 0;
            string paging = ram > 0 ? "RAM " + G(ram) + " + paging file about " + G(Math.Max(0,limit - ram)) : "RAM + paging file";
            return Make("commit","Commit limit",false,PreflightLevel.Block,"commit limit " + G(limit) + " is under " + G(CommitFloor) + " (" + paging +
                "); the run dies with Windows error 1455. Fix: raise the paging file by at least " + G(CommitFloor - limit) + " (Advanced system settings > Performance > Virtual memory), then retry.");
        }));
        list.Add(Guarded("vram","Video memory",false,() => {
            var gpu = f.Hardware == null ? null : f.Hardware.Preferred;
            if (gpu == null || gpu.vram <= 0) return Make("vram","Video memory",false,PreflightLevel.Warn,"video memory could not be read.");
            long gib = Hardware.GiB(gpu.vram);
            if (gib < VramFloorGiB) return Make("vram","Video memory",false,PreflightLevel.Block,gpu.name + " has " + gib + " GiB, under the " + VramFloorGiB +
                " GiB floor (8 GB cards drop head and skin meshes). Fix: use a GPU with " + VramRecommendedGiB + " GiB or more.");
            if (gib < VramRecommendedGiB) return Make("vram","Video memory",false,PreflightLevel.Warn,gpu.name + " has " + gib + " GiB; " + VramRecommendedGiB +
                " GiB or more is recommended for the world path. It will run.");
            return Make("vram","Video memory",false,PreflightLevel.Pass,gib + " GiB");
        }));
        list.Add(Guarded("featureLevel","Feature level 12_0",false,() => {
            var gpu = f.Hardware == null ? null : f.Hardware.Preferred;
            if (gpu == null) return Make("featureLevel","Feature level 12_0",false,PreflightLevel.Warn,"no GPU detected, cannot verify Direct3D 12 FL 12_0. Fix: install the GPU driver or unset VICTORY_LAUNCHER_HARDWARE=0.");
            return gpu.fl12 ? Make("featureLevel","Feature level 12_0",false,PreflightLevel.Pass,"12_0 or newer")
                            : Make("featureLevel","Feature level 12_0",false,PreflightLevel.Block,gpu.name + " does not reach Direct3D 12 FL 12_0. Fix: update the driver or use a Direct3D 12 GPU.");
        }));
        list.Add(Guarded("shaderModel","Shader Model 6.6",false,() => Capability("shaderModel","Shader Model 6.6",f,g => g.sm66,"Shader Model 6.6","update the GPU driver (needs a WDDM 3.0+ driver).")));
        list.Add(Guarded("meshShaders","Mesh shaders",false,() => Capability("meshShaders","Mesh shaders",f,g => g.mesh,"mesh shaders","use a GPU with mesh shader support; the world path uses mesh pipelines.")));
        list.Add(Guarded("gameDir","Game directory",false,() => {
            if (String.IsNullOrEmpty(f.GameRoot) || !Directory.Exists(f.GameRoot))
                return Make("gameDir","Game directory",false,PreflightLevel.Block,"game directory not found: '" + f.GameRoot + "'. Fix: pick the folder with MicrosoftGame.Config in the launcher.");
            if (!String.IsNullOrEmpty(f.Image) && !File.Exists(f.Image))
                return Make("gameDir","Game directory",false,PreflightLevel.Block,"executable not found: '" + f.Image + "'. Fix: restore the file or pick the executable again.");
            return Make("gameDir","Game directory",false,PreflightLevel.Pass,f.GameRoot);
        }));
        list.Add(Guarded("archive","Archive appdata0.rpf",false,() => {
            string dir = !String.IsNullOrEmpty(f.Image) ? Path.GetDirectoryName(f.Image) : f.GameRoot;
            if (String.IsNullOrEmpty(dir)) return Make("archive","Archive appdata0.rpf",false,PreflightLevel.Skip,"no game directory to look in.");
            // Task spec: absence is known to reproduce a breakpoint at +0x2237178 before the first window.
            return File.Exists(Path.Combine(dir,"appdata0.rpf"))
                ? Make("archive","Archive appdata0.rpf",false,PreflightLevel.Pass,"present")
                : Make("archive","Archive appdata0.rpf",false,PreflightLevel.Block,"appdata0.rpf is missing beside the executable (" + dir +
                    "); the run breaks at +0x2237178 before the first window. Fix: restore appdata0.rpf next to the executable (re-verify the copy).");
        }));
        list.Add(Guarded("pipelineCache","Pipeline cache",false,() => {
            string why = ColdReason(f.CacheDir);
            return why == null ? Make("pipelineCache","Pipeline cache",false,PreflightLevel.Pass,"warm (file checks)")
                : Make("pipelineCache","Pipeline cache",false,PreflightLevel.Block,"pipeline cache is cold: " + why +
                    ". Fix: run 'kelvaroq-desktop.exe --first-run' (docs/RUNBOOK.md section 2c) and retry.");
        }));
        list.Add(Guarded("engineRunning","Other engine running",false,() => f.Engines.Count == 0
            ? Make("engineRunning","Other engine running",false,PreflightLevel.Pass,"none")
            : Make("engineRunning","Other engine running",false,PreflightLevel.Block,"another engine is running: " + String.Join(", ",f.Engines) +
                ". Fix: close it (Task Manager > Details > End task) and retry.")));
        // ---- advisory set: warn, never block ----
        list.Add(Guarded("ram","System RAM",true,() => {
            if (f.Hardware == null || !f.Hardware.ram.HasValue) return Make("ram","System RAM",true,PreflightLevel.Skip,"RAM size unavailable.");
            return f.Hardware.ram.Value >= RamRecommended - (1L << 29)  // GiB-rounded, like Hardware.Warnings
                ? Make("ram","System RAM",true,PreflightLevel.Pass,Hardware.GiB(f.Hardware.ram.Value) + " GiB")
                : Make("ram","System RAM",true,PreflightLevel.Warn,Hardware.GiB(f.Hardware.ram.Value) + " GiB is under the 32 GiB recommended (RUNBOOK section 0); expect paging.");
        }));
        list.Add(Guarded("driverAge","GPU driver age",true,() => {
            var gpu = f.Hardware == null ? null : f.Hardware.Preferred;
            if (gpu == null || !gpu.DriverDate.HasValue) return Make("driverAge","GPU driver age",true,PreflightLevel.Skip,"driver date unavailable.");
            return gpu.DriverDate.Value < f.Now.AddMonths(-DriverMaxAgeMonths)
                ? Make("driverAge","GPU driver age",true,PreflightLevel.Warn,"driver is from " + gpu.DriverDate.Value.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture) + ", over " + DriverMaxAgeMonths + " months old. Consider updating it.")
                : Make("driverAge","GPU driver age",true,PreflightLevel.Pass,gpu.DriverDate.Value.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture));
        }));
        list.Add(Guarded("gamepad","XInput device",true,() => !f.Gamepad.HasValue ? Make("gamepad","XInput device",true,PreflightLevel.Skip,"XInput unavailable.")
            : f.Gamepad.Value ? Make("gamepad","XInput device",true,PreflightLevel.Pass,"connected")
            : Make("gamepad","XInput device",true,PreflightLevel.Warn,"no XInput controller found. Connect one if you want to play with a pad.")));
        list.Add(Guarded("asciiPath","ASCII path",true,() => {
            var bad = (f.RunPaths ?? new string[0]).FirstOrDefault(p => p.Any(c => c > 127));
            return bad == null ? Make("asciiPath","ASCII path",true,PreflightLevel.Pass,"ok")
                : Make("asciiPath","ASCII path",true,PreflightLevel.Warn,"path has non-ASCII characters: '" + bad + "'. Move it somewhere short like C:\\vt if anything fails to start.");
        }));
        return list;
    }

    /// Mirrors bench/heavy.ps1 Test-WarmCache file checks. Returns null when warm.
    /// It does not run 'precompile --check' (that needs the engine; see the doctor limits in the report).
    internal static string ColdReason(string cache) {
        if (String.IsNullOrEmpty(cache) || !Directory.Exists(cache)) return "cache directory not found: '" + cache + "'";
        foreach (string d in new[]{"pipelines","shaders"})
            if (!Directory.Exists(Path.Combine(cache,d))) return "no '" + d + "' directory in the cache";
        string recipes = Path.Combine(cache,"pipelines","warm-v1");
        int n = Directory.Exists(recipes) ? Directory.EnumerateFiles(recipes,"*",SearchOption.AllDirectories).Count() : 0;
        if (n < MinRecipes) return "only " + n + " recorded pipeline recipes in pipelines/warm-v1 (need " + MinRecipes + ")";
        if (!File.Exists(Path.Combine(cache,"pipelines","precompiled-v1.txt"))) return "no pipelines/precompiled-v1.txt receipt, nothing was precompiled";
        return null;
    }

    internal static bool Blocked(IEnumerable<PreflightResult> results) { return results.Any(r => r.Level == PreflightLevel.Block); }

    /// The override is exactly VICTORY_SKIP_PREFLIGHT=1. Anything else is not an override.
    internal static PreflightOutcome Gate(IEnumerable<PreflightResult> results,string skip) {
        var blockers = results.Where(r => r.Level == PreflightLevel.Block).ToList();
        var outcome = new PreflightOutcome { Proceed = blockers.Count == 0 };
        if (blockers.Count == 0) return outcome;
        var text = new StringBuilder();
        if (skip == "1") {
            outcome.Proceed = true; outcome.Overridden = blockers;
            text.AppendLine(SkipVariable + "=1: launching despite " + blockers.Count + " blocking check(s):");
        } else text.AppendLine("Launch refused by preflight (" + blockers.Count + " blocking). Set " + SkipVariable + "=1 to override.");
        foreach (var r in blockers) text.AppendLine("  [" + r.Id + "] " + r.Message);
        outcome.Report = text.ToString().TrimEnd();
        return outcome;
    }

    /// The normal-launch gate. Returns the override report ("" when nothing was overridden); throws when blocked.
    internal static string Enforce(PreflightFacts facts) {
        var outcome = Gate(Run(facts),SkipRequested);
        if (!outcome.Proceed) throw new PreflightBlocked(outcome.Report);
        return outcome.Report;
    }

    /// Runs every check, prints a table, and returns 2 when anything blocks, else 0. Never launches.
    /// It ignores VICTORY_SKIP_PREFLIGHT on purpose: doctor reports the truth.
    internal static int Doctor(PreflightFacts facts,TextWriter output) {
        var results = Run(facts);
        int width = results.Max(r => r.Id.Length);
        output.WriteLine("PREFLIGHT DOCTOR");
        foreach (var r in results) {
            string tag = r.Level == PreflightLevel.Block ? "BLOCK" : r.Level == PreflightLevel.Warn ? "WARN" : r.Level == PreflightLevel.Skip ? "skip" : "ok";
            output.WriteLine(tag.PadRight(5) + "  " + (r.Advisory ? "adv " : "blk ") + r.Id.PadRight(width) + "  " + r.Message);
        }
        int blocked = results.Count(r => r.Level == PreflightLevel.Block);
        output.WriteLine(blocked == 0 ? "RESULT: nothing blocks (exit 0)" : "RESULT: " + blocked + " blocking (exit 2)");
        output.Flush();
        return blocked == 0 ? 0 : 2;
    }

    // ---- doctor entry point for the GUI-subsystem launcher ----
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool SetStdHandle(int which,IntPtr handle);
    [DllImport("kernel32.dll",CharSet = CharSet.Unicode,SetLastError = true)]
    static extern IntPtr CreateFile(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);

    /// The launcher is a windows-subsystem exe: with no inherited stdout, attach to the parent console.
    /// A redirected stdout (pipe or file) is used as is.
    internal static void OpenOutput() {
        IntPtr h = GetStdHandle(-11);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) {
            if (!AttachConsole(0xFFFFFFFF)) return;
            IntPtr con = CreateFile("CONOUT$",0xC0000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
            if (con == new IntPtr(-1)) return;
            SetStdHandle(-11,con); SetStdHandle(-12,con);
        }
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput(),new UTF8Encoding(false)) { AutoFlush = true });
    }

    /// kelvaroq-desktop.exe --doctor [exe-or-folder]. Exit 0 clean, 2 blocked, 1 could not run.
    internal static int RunDoctor(string[] args,string home) {
        OpenOutput();
        var prefs = Preferences.Load(home);
        string selection = args.Length > 1 ? args[1] : prefs.executable;
        var hardware = Hardware.Enabled ? Hardware.Detect() : null;
        return Doctor(PreflightFacts.Live(hardware,selection,prefs),Console.Out);
    }
}
}
