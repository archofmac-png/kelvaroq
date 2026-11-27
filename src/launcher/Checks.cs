using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

namespace Kelvaroq {
internal static class Checks {
    static void Check(bool ok) { if (!ok) throw new InvalidOperationException("Assertion failed"); }
    static void HardwareProfiles(string home,Preferences prefs) {
        var locale = new Locale("en");
        var machine = Hardware.Sample();
        var gpu = machine.Preferred;
        Func<int?[]> values = () => ProfileRule.Rules.Select(r => r.Value(machine,prefs)).ToArray();
        Check(!prefs.customProfile && gpu.VendorName == "NVIDIA" && !machine.Warnings(locale).Any());
        Check(values().SequenceEqual(new int?[]{192,1024,96,8,0}));

        gpu.name = "GeForce RTX 3060"; gpu.vram = 12L << 30;
        machine.physical = 8; machine.logical = 16; machine.ram = (16L << 30) - (128L << 20);
        Check(!machine.Warnings(locale).Any() && values().SequenceEqual(new int?[]{128,512,64,4,0}));

        gpu.name = "Radeon RX 7900 XTX"; gpu.vendor = 0x1002; gpu.vram = 24L << 30;
        gpu.wave_min = 32; gpu.wave_max = 64; machine.ram = 32L << 30;
        prefs.customProfile = true; prefs.profileValues["VICTORY_WAVE64_PAIRED"] = 1;
        Check(gpu.VendorName == "AMD" && values().SequenceEqual(new int?[]{192,1024,96,4,null}));

        gpu.name = "Arc A770"; gpu.vendor = 0x8086; gpu.vram = 16L << 30;
        gpu.wave_min = 8; gpu.wave_max = 32;
        Check(gpu.VendorName == "Intel" && values().SequenceEqual(new int?[]{192,1024,96,4,1}));
        prefs.profileValues["VICTORY_WIDE_THREADS"] = 2;
        prefs.profileValues["VICTORY_TEXTURE_STAGE_MB"] = -4;
        prefs.profileValues["VICTORY_UNRECOGNIZED_TEST_KEY"] = 1;
        prefs.Write(home); prefs = Preferences.Load(home);
        var child = new System.Diagnostics.ProcessStartInfo();
        child.EnvironmentVariables.Clear();
        child.EnvironmentVariables["VICTORY_CARD_BUFFERS_MB"] = "700";
        Product.Configure(child,new Installation { Root = home },prefs,locale,false,machine);
        Check(child.EnvironmentVariables["VICTORY_CARD_BUFFERS_MB"] == "700");
        Check(child.EnvironmentVariables["VICTORY_TEXTURE_STAGE_MB"] == "192");
        Check(child.EnvironmentVariables["VICTORY_WAVE64_PAIRED"] == "1");
        Check(child.EnvironmentVariables["VICTORY_WIDE_THREADS"] == "2");
        Check(!child.EnvironmentVariables.ContainsKey("VICTORY_UNRECOGNIZED_TEST_KEY"));
        prefs.customProfile = false;
        Check(values()[3] == 4 && values()[4] == 0);
        var integrated = new Gpu { name = "Integrated GPU", fl12 = true, uma = true,
            sm66 = true, mesh = false, bindless = true, root11 = true };
        machine.gpus = new[]{integrated}; machine.ram = 8L << 30;
        Check(machine.Warnings(locale).Contains(locale.T("missingHardware",locale.T("meshShaders"))));
        Check(machine.Warnings(locale).Contains(locale.T("lowRam")) && values().All(v => v == null));
        machine.gpus = new[]{integrated,gpu};
        Check(machine.Preferred == gpu && machine.Warnings(locale).Contains(locale.T("hybridGpu")));
        Check(values().SequenceEqual(new int?[]{64,256,32,4,0}));
        machine.gpus = new[]{gpu}; gpu.vram = 6L << 30;
        Check(values().SequenceEqual(new int?[]{64,256,32,4,0}));
        gpu.sm66 = null;
        Check(machine.Warnings(locale).Contains(locale.T("unverifiedHardware","Shader Model 6.6")));
        gpu.sm66 = true;
        var old = Environment.GetEnvironmentVariable("VICTORY_LAUNCHER_PROFILES");
        var oldDetection = Environment.GetEnvironmentVariable("VICTORY_LAUNCHER_HARDWARE");
        try {
            foreach (var key in new[]{"VICTORY_LAUNCHER_PROFILES","VICTORY_LAUNCHER_HARDWARE"}) {
                Environment.SetEnvironmentVariable(key,"0");
                child.EnvironmentVariables.Clear(); ProfileRule.Apply(child,machine,prefs);
                Check(child.EnvironmentVariables.Count == 0);
                Environment.SetEnvironmentVariable(key,null);
            }
        } finally {
            Environment.SetEnvironmentVariable("VICTORY_LAUNCHER_PROFILES",old);
            Environment.SetEnvironmentVariable("VICTORY_LAUNCHER_HARDWARE",oldDetection);
        }
    }
    // ---- preflight fixtures: empty placeholder files only, no title data ----
    static readonly DateTime FixtureNow = new DateTime(2026,11,26,12,0,0,DateTimeKind.Utc);
    static PreflightFacts Healthy(string root) {
        string dir = Files.Unique(root), game = Path.Combine(dir,"title"), cache = Path.Combine(dir,"cache");
        Directory.CreateDirectory(Path.Combine(cache,"pipelines","warm-v1")); Directory.CreateDirectory(Path.Combine(cache,"shaders"));
        File.WriteAllText(Path.Combine(cache,"pipelines","warm-v1","r1"),"x");
        File.WriteAllText(Path.Combine(cache,"pipelines","precompiled-v1.txt"),"receipt");
        Directory.CreateDirectory(game);
        File.WriteAllBytes(Path.Combine(game,"sample.exe"),new byte[0]);
        File.WriteAllBytes(Path.Combine(game,"appdata0.rpf"),new byte[0]);
        var hardware = Hardware.Sample(); hardware.Preferred.DriverDate = FixtureNow.AddMonths(-1);
        return new PreflightFacts { CommitLimit = 96L << 30, Hardware = hardware, GameRoot = game,
            Image = Path.Combine(game,"sample.exe"), CacheDir = cache, Engines = new List<string>(),
            Gamepad = true, RunPaths = new[]{@"C:\vt\kelvaroq-desktop.exe"}, Now = FixtureNow };
    }
    static PreflightResult Result(PreflightFacts f,string id) { return Preflight.Run(f).Single(r => r.Id == id); }
    static void Verdict(string root,string id,PreflightLevel expected,Action<PreflightFacts> change) {
        var f = Healthy(root); change(f); var r = Result(f,id);
        Check(r.Level == expected);
        if (expected == PreflightLevel.Block) Check(r.Message.Contains("Fix:"));
    }
    static void RunPreflight(string root) {
        string[] blocking = {"commit","vram","featureLevel","shaderModel","meshShaders","gameDir","archive","pipelineCache","engineRunning"};
        string[] advisory = {"ram","driverAge","gamepad","asciiPath"};
        var clean = Preflight.Run(Healthy(root));
        Check(blocking.Concat(advisory).OrderBy(x => x).SequenceEqual(clean.Select(r => r.Id).OrderBy(x => x)));
        Check(clean.All(r => r.Level == PreflightLevel.Pass) && !Preflight.Blocked(clean));
        Check(blocking.All(id => !clean.Single(r => r.Id == id).Advisory) && advisory.All(id => clean.Single(r => r.Id == id).Advisory));

        // commit limit: 80 GiB is the line (docs/RUNBOOK.md section 0)
        Verdict(root,"commit",PreflightLevel.Pass,f => f.CommitLimit = 80L << 30);
        Verdict(root,"commit",PreflightLevel.Block,f => f.CommitLimit = (80L << 30) - 1);
        Check(Result(new Func<PreflightFacts>(() => { var f = Healthy(root); f.CommitLimit = 60L << 30; return f; })(),"commit").Message.Contains("paging file"));
        Verdict(root,"commit",PreflightLevel.Warn,f => f.CommitLimit = null);
        // VRAM: block under 12, warn 12..16, pass at 16
        Verdict(root,"vram",PreflightLevel.Block,f => f.Hardware.Preferred.vram = 8L << 30);
        Verdict(root,"vram",PreflightLevel.Warn,f => f.Hardware.Preferred.vram = 12L << 30);
        Verdict(root,"vram",PreflightLevel.Warn,f => f.Hardware.Preferred.vram = 15L << 30);
        Verdict(root,"vram",PreflightLevel.Pass,f => f.Hardware.Preferred.vram = 16L << 30);
        Verdict(root,"vram",PreflightLevel.Warn,f => f.Hardware = null);
        // device capabilities: only a definite "no" blocks; unknown is a warning
        Verdict(root,"featureLevel",PreflightLevel.Block,f => f.Hardware.Preferred.fl12 = false);
        Verdict(root,"shaderModel",PreflightLevel.Block,f => f.Hardware.Preferred.sm66 = false);
        Verdict(root,"shaderModel",PreflightLevel.Warn,f => f.Hardware.Preferred.sm66 = null);
        Verdict(root,"meshShaders",PreflightLevel.Block,f => f.Hardware.Preferred.mesh = false);
        Verdict(root,"meshShaders",PreflightLevel.Warn,f => f.Hardware.gpus = new Gpu[0]);
        // files
        Verdict(root,"gameDir",PreflightLevel.Block,f => f.GameRoot = Path.Combine(f.GameRoot,"missing"));
        Verdict(root,"gameDir",PreflightLevel.Block,f => File.Delete(f.Image));
        Verdict(root,"archive",PreflightLevel.Block,f => File.Delete(Path.Combine(f.GameRoot,"appdata0.rpf")));
        Check(Result(new Func<PreflightFacts>(() => { var f = Healthy(root); File.Delete(Path.Combine(f.GameRoot,"appdata0.rpf")); return f; })(),"archive").Message.Contains("appdata0.rpf"));
        // pipeline cache: the three cold states bench/heavy.ps1 Test-WarmCache refuses
        Verdict(root,"pipelineCache",PreflightLevel.Block,f => f.CacheDir = Path.Combine(f.CacheDir,"absent"));
        Verdict(root,"pipelineCache",PreflightLevel.Block,f => Files.RemoveTree(Path.Combine(f.CacheDir,"shaders")));
        Verdict(root,"pipelineCache",PreflightLevel.Block,f => File.Delete(Path.Combine(f.CacheDir,"pipelines","warm-v1","r1")));
        Verdict(root,"pipelineCache",PreflightLevel.Block,f => File.Delete(Path.Combine(f.CacheDir,"pipelines","precompiled-v1.txt")));
        // another engine
        Verdict(root,"engineRunning",PreflightLevel.Block,f => f.Engines.Add("kelvaroq-engine.exe (pid 4242)"));
        Check(Result(new Func<PreflightFacts>(() => { var f = Healthy(root); f.Engines.Add("kelvaroq-engine.exe (pid 4242)"); return f; })(),"engineRunning").Message.Contains("4242"));

        // advisory: warn, never block
        Verdict(root,"ram",PreflightLevel.Warn,f => f.Hardware.ram = 16L << 30);
        Verdict(root,"ram",PreflightLevel.Pass,f => f.Hardware.ram = 32L << 30);
        Verdict(root,"driverAge",PreflightLevel.Warn,f => f.Hardware.Preferred.DriverDate = FixtureNow.AddMonths(-7));
        Verdict(root,"driverAge",PreflightLevel.Pass,f => f.Hardware.Preferred.DriverDate = FixtureNow.AddMonths(-5));
        Verdict(root,"driverAge",PreflightLevel.Skip,f => f.Hardware.Preferred.DriverDate = null);
        Verdict(root,"gamepad",PreflightLevel.Warn,f => f.Gamepad = false);
        Verdict(root,"gamepad",PreflightLevel.Skip,f => f.Gamepad = null);
        Verdict(root,"asciiPath",PreflightLevel.Warn,f => f.RunPaths = new[]{"C:\\Jeux\\Caf\u00e9\\game.exe"});
        var worst = Healthy(root); worst.Hardware.ram = 8L << 30; worst.Hardware.Preferred.DriverDate = FixtureNow.AddYears(-3);
        worst.Gamepad = false; worst.RunPaths = new[]{"C:\\\u00e9"};
        var advisoryOnly = Preflight.Run(worst);
        Check(advisory.All(id => advisoryOnly.Single(r => r.Id == id).Level == PreflightLevel.Warn) && !Preflight.Blocked(advisoryOnly));
        Check(Preflight.Gate(advisoryOnly,null).Proceed);
        // a probe that throws can never block, advisory or not
        foreach (bool isAdvisory in new[]{true,false}) {
            var thrown = Preflight.Guarded("probe","Probe",isAdvisory,() => { throw new InvalidOperationException("boom"); });
            Check(thrown.Level == PreflightLevel.Warn && thrown.Message.Contains("boom"));
        }

        // override flag: honoured only as exactly "1", and prints exactly what it overrode
        var blocked = Healthy(root); blocked.CommitLimit = 10L << 30; blocked.Engines.Add("victory.exe (pid 7)");
        var results = Preflight.Run(blocked);
        Check(Preflight.Blocked(results));
        var stopped = Preflight.Gate(results,null);
        Check(!stopped.Proceed && stopped.Report.Contains("commit") && stopped.Report.Contains("engineRunning") && !stopped.Report.Contains("launching despite") && stopped.Overridden.Count == 0);
        foreach (string notOne in new[]{"","0","true","yes"}) Check(!Preflight.Gate(results,notOne).Proceed);
        var skipped = Preflight.Gate(results,"1");
        Check(skipped.Proceed && skipped.Report.Contains("VICTORY_SKIP_PREFLIGHT=1") && skipped.Overridden.Count == 2);
        Check(skipped.Overridden.Select(r => r.Id).OrderBy(x => x).SequenceEqual(new[]{"commit","engineRunning"}));
        Check(skipped.Overridden.All(r => skipped.Report.Contains(r.Message)) && !skipped.Report.Contains("vram"));
        Check(Preflight.Gate(Preflight.Run(Healthy(root)),"1").Overridden.Count == 0 && Preflight.Gate(Preflight.Run(Healthy(root)),"1").Report == "");
        string held = Environment.GetEnvironmentVariable("VICTORY_SKIP_PREFLIGHT");
        try {
            Environment.SetEnvironmentVariable("VICTORY_SKIP_PREFLIGHT",null);
            try { Preflight.Enforce(blocked); throw new InvalidOperationException("Unexpected success"); } catch (PreflightBlocked) {}
            Environment.SetEnvironmentVariable("VICTORY_SKIP_PREFLIGHT","1");
            Check(Preflight.Enforce(blocked).Contains("commit"));
        } finally { Environment.SetEnvironmentVariable("VICTORY_SKIP_PREFLIGHT",held); }

        // doctor: runs everything, prints a table, never launches
        var output = new StringWriter();
        Check(Preflight.Doctor(Healthy(root),output) == 0);
        foreach (string id in blocking.Concat(advisory)) Check(output.ToString().Contains(id));
        output = new StringWriter();
        Check(Preflight.Doctor(blocked,output) == 2 && output.ToString().Contains("BLOCK") && output.ToString().Contains("commit"));
        Check(Preflight.Doctor(worst,new StringWriter()) == 0);
        // doctor ignores the override: it reports, it does not launch
        var env = Environment.GetEnvironmentVariable("VICTORY_SKIP_PREFLIGHT");
        try { Environment.SetEnvironmentVariable("VICTORY_SKIP_PREFLIGHT","1"); Check(Preflight.Doctor(blocked,new StringWriter()) == 2); }
        finally { Environment.SetEnvironmentVariable("VICTORY_SKIP_PREFLIGHT",env); }
    }
    static void Reject(Action action) {
        try { action(); } catch (Exception ex) {
            if (ex is Problem || ex is InvalidDataException || ex is IOException || ex is ArgumentException) return;
            throw;
        }
        throw new InvalidOperationException("Unexpected success");
    }
    internal static void Run(string suite,string root) {
        string home = Path.Combine(root,"preferences"), history = Path.Combine(home,"snapshots");
        var p = new Preferences { data = Path.Combine(root,"data"), cache = Path.Combine(root,"cache") };
        Directory.CreateDirectory(home);
        switch (suite) {
            case "hardware":
                HardwareProfiles(home,p);
                break;
            case "preflight":
                RunPreflight(root);
                break;
            case "releases":
                const string fixture = "{\"tag_name\":\"v0.10.1\",\"body\":\"## Changes\\r\\n- Faster startup\",\"html_url\":\"https://example.invalid/\",\"draft\":false,\"prerelease\":false}";
                var release = Release.Parse(fixture);
                Check(release.body == "Changes Faster startup" && release.Page == "https://github.com/fablinoo/kelvaroq/releases/tag/v0.10.1");
                Check(release.NewerThan("0.2.9") && !release.NewerThan("0.10.1") && !release.NewerThan("1.0.0"));
                foreach (string tag in new[]{"0.3.0","v0.3","v0.03.0","v0.3.0-beta","v1.2.3.4","v1.2.3\n","v0.2.0/other"})
                    Check(Release.Number(tag) == null);
                Reject(() => Release.Parse("{}")); Reject(() => Release.Parse("{"));
                Reject(() => Release.Parse(fixture.Replace("\"draft\":false","\"draft\":true")));
                Reject(() => Release.Parse(fixture.Replace("\"prerelease\":false","\"prerelease\":true")));
                Check(Release.Parse("{\"tag_name\":\"v1.0.0\",\"body\":null}").body == "");
                break;
            case "updatePolicy":
                var clock = new DateTime(2026,1,1,12,0,0,DateTimeKind.Utc);
                var check = ReleaseCheck.Load(home);
                Check(p.updates);
                p.updates = false; p.Write(home);
                Check(!check.Begin(Preferences.Load(home).updates,clock,() => { throw new Exception(); }) && check.attempted == 0);
                Check(check.Begin(true,clock,() => check.Write(home)));
                check = ReleaseCheck.Load(home);
                Check(!check.Begin(true,clock.AddDays(1).AddTicks(-1),() => { throw new Exception(); }));
                Check(check.Begin(true,clock.AddDays(1),() => check.Write(home)));
                check.latest = Release.Parse("{\"tag_name\":\"v0.3.1\",\"body\":\"Summary\"}"); check.succeeded = true; check.Write(home);
                Check(ReleaseCheck.Load(home).latest.NewerThan("0.2.0"));
                break;
            case "engine":
                var legacy = Path.Combine(root,"victory.exe"); var branded = Path.Combine(root,"kelvaroq-engine.exe");
                File.WriteAllText(legacy,"old"); Check(Product.EngineIn(root) == legacy);
                File.WriteAllText(branded,"new"); Check(Product.EngineIn(root) == branded);
                break;
            case "language":
                var english = new Locale("en").Strings;
                foreach (string code in Locale.Codes) {
                    var table = new Locale(code).Strings;
                    Check(table.Count == english.Count && english.Keys.All(k => table.ContainsKey(k) && !String.IsNullOrWhiteSpace(table[k])));
                    foreach (var key in english.Keys) foreach (var placeholder in new[]{"{0}","{1}","{2}"})
                        Check(english[key].Contains(placeholder) == table[key].Contains(placeholder));
                }
                Check(new Locale("fr-CA").Code == "fr"); Check(new Locale("pt-PT").Code == "pt-BR"); break;
            case "settings":
                p.Write(home); var file = Path.Combine(home,"settings");
                var json = Files.Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file));
                json["schema_version"] = 1; json.Remove("days"); json.Remove("recent"); json.Remove("updates");
                File.WriteAllText(file,Files.Json.Serialize(json));
                var migrated = Preferences.Load(home);
                Check(migrated.schema_version == 2 && migrated.days == 14 && migrated.recent == 8 && migrated.data == p.data && migrated.updates);
                Check(Preferences.Load(home).schema_version == 2);
                json["schema_version"] = 17; File.WriteAllText(file,Files.Json.Serialize(json)); Reject(() => Preferences.Load(home));
                p.cache = p.data; Reject(() => p.Write(home)); break;
            case "paths":
                string config = Path.Combine(root,"MicrosoftGame.Config"), exe = Path.Combine(root,"bin","sample.exe");
                Directory.CreateDirectory(Path.GetDirectoryName(exe)); File.WriteAllBytes(exe,new byte[0]);
                Reject(() => Installation.Select(exe)); Reject(() => Installation.Select(root));
                File.WriteAllText(config,"<Game><ExecutableList><!-- <Executable Name='ignored.exe'/> --><Executable Name='bin/sample.exe' TargetDeviceFamily='Scarlett'/></ExecutableList></Game>",Encoding.Unicode);
                Check(Installation.Select(root).Image == exe); Check(Installation.Select(exe).Root == root);
                var other = Path.Combine(root,"other.exe"); File.WriteAllText(other,""); Reject(() => Installation.Select(other));
                File.WriteAllText(config,"<Game><ExecutableList><Executable Name='../outside.exe'/></ExecutableList></Game>"); Reject(() => Installation.Select(root));
                File.WriteAllText(config,"<"); Reject(() => Installation.Select(root)); break;
            case "retention":
                DateTime now = new DateTime(2026,11,10,16,0,0,DateTimeKind.Utc);
                var samples = new[]{0,1,2,24,25,48,72}.Select(h => new Snapshot { Info = new Manifest { created_at = now.AddHours(-h).ToString("o") } }).ToList();
                Check(Archives.Expired(samples,now,2,3).SequenceEqual(new[]{samples[2],samples[4],samples[6]}));
                Check(Archives.Expired(samples,now,1,0).Count() == 6); break;
            case "move":
                Directory.CreateDirectory(p.cache); File.WriteAllText(Path.Combine(p.cache,"one"),"original");
                var dest = Path.Combine(root,"target");
                Reject(() => Relocation.Move(p.cache,dest,n => {},delegate { throw new IOException(); }));
                Check(!Directory.Exists(dest) && Files.Size(p.cache) == 8);
                Reject(() => Relocation.Move(p.cache,dest,n => {},useNew => {
                    if (useNew) File.WriteAllText(Path.Combine(p.cache,"changed"),"new");
                }));
                Check(!Directory.Exists(dest) && File.Exists(Path.Combine(p.cache,"changed")));
                int last = 0; Relocation.Move(p.cache,dest,n => last = n,delegate {});
                Check(last == 100 && !Directory.Exists(p.cache) && File.ReadAllText(Path.Combine(dest,"one")) == "original"); break;
            case "clear":
                foreach (var name in new[]{"shaders","pipelines"}) {
                    var dir = Path.Combine(p.cache,name); Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir,"entry"),"cache");
                }
                Files.ClearShaders(p.cache); Check(!Directory.Exists(Path.Combine(p.cache,"shaders")) && Files.Size(p.cache) == 5);
                Directory.CreateDirectory(p.data); File.WriteAllText(Path.Combine(p.data,"slot"),"saved");
                Archives.ClearData(p,history,"def"); Check(Files.Size(p.data) == 0);
                Archives.Restore(Archives.History(history).Single().Path,p,history,"def");
                Check(File.ReadAllText(Path.Combine(p.data,"slot")) == "saved");
                break;
            case "options":
                var info = new System.Diagnostics.ProcessStartInfo { UseShellExecute = false };
                var game = new Installation { Image = Path.Combine(root,"bin","sample.exe"), Root = root };
                p.monitor = true; p.preload = false;
                Product.Configure(info,game,p,new Locale("en"),true);
                Check(info.EnvironmentVariables["VICTORY_GAME_DIR"] == root && info.EnvironmentVariables["VICTORY_CACHE_DIR"] == p.cache &&
                    info.EnvironmentVariables["VICTORY_DATA_DIR"] == p.data && info.EnvironmentVariables["VICTORY_PIPELINE_PRECOMPILE"] == "0" &&
                    info.EnvironmentVariables["VICTORY_LAUNCHER_MONITOR"] == "1" && info.EnvironmentVariables["VICTORY_STATS_SHM"] == "1");
                break;
            case "session":
                Directory.CreateDirectory(p.data);
                string state = Path.Combine(p.data,"slot");
                File.WriteAllText(state,"before");
                Check(Session.Run(p,history,"abc",true,delegate {
                    Check(Archives.History(history).Single().Info.reason == "beforeLaunch");
                    File.WriteAllText(state,"after"); return 0;
                }) == 0);
                Check(Archives.History(history).Count == 2 && Archives.History(history)[0].Info.reason == "afterExit");
                Check(Session.Run(p,history,"abc",true,delegate { return 2; }) == 2);
                Check(Archives.History(history).Count == 3);
                Session.Run(p,history,"abc",false,delegate { return 0; });
                Check(Archives.History(history).Count == 3);
                break;
            case "recovery":
                Directory.CreateDirectory(history);
                var token = Guid.NewGuid().ToString("N");
                var prefix = Path.Combine(root,".kelvaroq-" + token);
                Directory.CreateDirectory(prefix + ".previous");
                File.WriteAllText(Path.Combine(prefix + ".previous","save"),"last good");
                Directory.CreateDirectory(prefix + ".incoming");
                File.WriteAllText(Path.Combine(history,"replacement.json"),Files.Json.Serialize(new Archives.Replacement { token = token, destination = p.data }));
                Archives.Recover(p.data,history); Archives.Recover(p.data,history);
                Check(File.ReadAllText(Path.Combine(p.data,"save")) == "last good" && !Directory.Exists(prefix + ".incoming"));
                break;
            case "archive":
                Directory.CreateDirectory(Path.Combine(p.data,"empty")); string save = Path.Combine(p.data,"save");
                File.WriteAllText(save,"first");
                string snapshot = Archives.Write(p.data,history,"abc","manual","sample");
                string export = Path.Combine(root,"export.zip"); Archives.Export(snapshot,export);
                File.WriteAllText(save,"second"); Archives.Restore(export,p,history,"def");
                Check(File.ReadAllText(save) == "first" && Directory.Exists(Path.Combine(p.data,"empty")));
                var backup = Archives.History(history).Single(s => s.Info.reason == "beforeRestore");
                Archives.Restore(backup.Path,p,history,"def"); Check(File.ReadAllText(save) == "second");
                foreach (string fault in new[]{"version","checksum","traversal","missing","corrupt"}) {
                    var damaged = Path.Combine(root,fault + ".zip"); File.Copy(export,damaged);
                    if (fault == "corrupt") File.WriteAllText(damaged,"invalid");
                    else using (var stream = File.Open(damaged,FileMode.Open)) using (var zip = new ZipArchive(stream,ZipArchiveMode.Update)) {
                        var e = zip.GetEntry("manifest.json"); Manifest m;
                        using (var r = new StreamReader(e.Open())) m = Files.Json.Deserialize<Manifest>(r.ReadToEnd());
                        e.Delete();
                        if (fault == "version") m.format_version = 0;
                        if (fault == "checksum") m.files[0].sha256 = new string('0',64);
                        if (fault == "traversal") m.files[0].path = "../escape";
                        if (fault != "missing") using (var w = new StreamWriter(zip.CreateEntry("manifest.json").Open())) w.Write(Files.Json.Serialize(m));
                    }
                    Reject(() => Archives.Restore(damaged,p,history,"def"));
                    Check(File.ReadAllText(save) == "second" && !File.Exists(Path.Combine(root,"escape")));
                }
                break;
            case "logs":
                LogChecks(root);
                break;
            case "moveSteps":
                MoveStepChecks(root);
                break;
            case "restoreFails":
                RestoreFailureChecks(root);
                break;
            default: throw new ArgumentException(suite);
        }
    }
    static string Step(Action action) {
        try { action(); } catch (StepFailure ex) { return ex.Step; }
        throw new InvalidOperationException("Unexpected success");
    }
    static void LogChecks(string root) {
        string log = Path.Combine(root,"crashes.log");
        Func<int,string> rotated = n => log + "." + n;
        // missing and zero-byte logs never rotate, whatever the cap
        Check(!LogRotation.Rotate(log,10,3,null));
        File.WriteAllBytes(log,new byte[0]);
        Check(!LogRotation.Rotate(log,1,3,null) && File.Exists(log) && !File.Exists(rotated(1)));
        // boundary: cap-1 stays, exactly cap rotates
        File.WriteAllBytes(log,new byte[9]);
        Check(!LogRotation.Rotate(log,10,3,null) && File.Exists(log));
        File.WriteAllBytes(log,new byte[10]);
        Check(LogRotation.Rotate(log,10,3,null) && !File.Exists(log) && new FileInfo(rotated(1)).Length == 10);
        // keep-N: generations shift and the oldest falls off
        for (int g = 2; g <= 5; g++) { File.WriteAllText(log,"generation" + g + "....."); Check(LogRotation.Rotate(log,10,3,null)); }
        Check(File.ReadAllText(rotated(1)).StartsWith("generation5") && File.ReadAllText(rotated(2)).StartsWith("generation4") &&
            File.ReadAllText(rotated(3)).StartsWith("generation3") && !File.Exists(rotated(4)));
        // a smaller keep than before also clears stale older generations
        File.WriteAllText(rotated(4),"stale");
        File.WriteAllText(log,"generation6.....");
        Check(LogRotation.Rotate(log,10,3,null) && !File.Exists(rotated(4)));
        // the current session's file is never rotated away
        File.WriteAllText(log,"current session file");
        Check(!LogRotation.Rotate(log,10,3,log) && File.ReadAllText(log) == "current session file");
        // a file the writer still holds open is left alone and nothing is lost
        string before = File.ReadAllText(rotated(1));
        using (new FileStream(log,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
            Check(!LogRotation.Rotate(log,10,3,null));
        Check(File.ReadAllText(log) == "current session file" && File.ReadAllText(rotated(1)) == before);
        Reject(() => LogRotation.Rotate(log,0,3,null)); Reject(() => LogRotation.Rotate(log,10,0,null));
        Check(LogRotation.MaxBytes > 0 && LogRotation.Keep > 0);
    }
    static IEnumerable<string> Leftovers(string folder) {
        return Directory.EnumerateFileSystemEntries(folder,".kelvaroq-*");
    }
    static void MoveStepChecks(string root) {
        string parent = Path.Combine(root,"volume"), source = Path.Combine(parent,"old"), dest = Path.Combine(parent,"new");
        Directory.CreateDirectory(Path.Combine(source,"sub"));
        File.WriteAllText(Path.Combine(source,"one"),"original"); File.WriteAllText(Path.Combine(source,"sub","two"),"second");
        // every step before the point of no return fails with its own name and changes nothing
        foreach (string step in Relocation.Steps) {
            var selected = new List<bool>();
            Check(Step(() => Relocation.Move(source,dest,n => {},selected.Add,s => { if (s == step) throw new IOException("injected"); })) == step);
             Check(!Directory.Exists(dest) && File.ReadAllText(Path.Combine(source,"one")) == "original" &&
                File.ReadAllText(Path.Combine(source,"sub","two")) == "second" && Files.Size(source) == 14);
            Check(!selected.Any() || !selected.Last());
            Check(!Leftovers(parent).Any());
        }
        // checksum failure on the copy is its own step, not a silent success
        Check(Step(() => Relocation.Move(source,dest,n => {},delegate {},s => {
            if (s == "verify-checksums") foreach (string copy in Directory.EnumerateFiles(parent,"one",SearchOption.AllDirectories).Where(c => Path.GetFileName(Path.GetDirectoryName(c)).StartsWith(".kelvaroq-"))) {
                File.WriteAllText(copy,"corrupt!!"); }
        })) == "verify-checksums");
         Check(!Directory.Exists(dest) && File.ReadAllText(Path.Combine(source,"one")) == "original" && !Leftovers(parent).Any());
        // while the move is in flight a marker names the move; the source is untouched until the flip
        bool marked = false;
        Relocation.Move(source,dest,n => {},delegate {},s => {
            if (s == "copy") { marked = Leftovers(parent).Any(p => p.EndsWith(".move")); Check(Files.Size(source) == 14); }
        });
        Check(marked && !Leftovers(parent).Any() && !Directory.Exists(source) && File.ReadAllText(Path.Combine(dest,"one")) == "original");
    }
    static void RestoreFailureChecks(string root) {
        string history = Path.Combine(root,"snapshots");
        var p = new Preferences { data = Path.Combine(root,"data"), cache = Path.Combine(root,"cache") };
        Directory.CreateDirectory(p.data); string save = Path.Combine(p.data,"save");
        File.WriteAllText(save,"live");
        string good = Archives.Write(p.data,history,"abc","manual","sample");
        File.WriteAllText(save,"newer");
        // an archive that fails verification still leaves a snapshot of the state it would have replaced
        string bad = Path.Combine(root,"bad.zip"); File.WriteAllText(bad,"invalid");
        Reject(() => Archives.Restore(bad,p,history,"def"));
        var taken = Archives.History(history).Where(s => !s.Damaged && s.Info.reason == "beforeRestore").ToList();
        Check(taken.Count == 1 && File.ReadAllText(save) == "newer");
        Archives.Restore(taken[0].Path,p,history,"def"); Check(File.ReadAllText(save) == "newer");
        // a failure at either publish point after the snapshot leaves the live data as it was
        foreach (string point in new[]{"publish","swap"}) {
            File.WriteAllText(save,"before-" + point);
            int count = Archives.History(history).Count;
            Check(Step(() => Archives.Restore(good,p,history,"def",s => { if (s == point) throw new IOException("injected"); })) == point);
            Check(File.ReadAllText(save) == "before-" + point && Archives.History(history).Count == count + 1);
            Check(Archives.History(history).Any(s => s.Info.reason == "beforeRestore"));
            Check(!Leftovers(root).Any());
        }
    }
}
}





