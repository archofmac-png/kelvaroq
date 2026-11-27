using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Kelvaroq {
/// first-run: resolve the game, preflight, precompile (shaders, then pipelines), verify the cache is
/// warm, launch once. This file is the logic and has no process or window in it, so every rule below
/// is exercised by the "firstrun" self-test suite without title data. The real engine and launch are
/// in FirstRunCommand.cs.
///
/// Rules this file keeps:
///  * Nothing here deletes anything. The only file it writes is first-run-v1.json (atomic replace).
///  * Preflight runs before the cache is touched. The cold-cache check is shown but does not gate:
///    a cold cache is what this command exists to fix; step 4 is the gate for it.
///  * The launch delegate runs at most once, and only after a warm verify.
///  * Failed steps leave state the next run resumes from: finished steps are skipped, the engine
///    reuses its own partial work, and a failed verify reopens the pipeline steps only.

/// A step that stops the run. Message is user-facing text; Code is the process exit code.
internal sealed class FirstRunFailure : Exception {
    internal readonly string Step; internal readonly int Code;
    internal FirstRunFailure(string step,int code,string message) : base(message) { Step = step; Code = code; }
}

internal struct StepProgress { internal long Done, Total, Failed; }

/// One engine invocation. Args may hold "{cache}".
internal sealed class FirstRunStep {
    internal string Id, Phase, Title, Verb; internal string[] Args;
}

internal sealed class EngineExit { internal int Code; internal string Tail = ""; }

internal interface IFirstRunEngine {
    /// Why the engine cannot be used at all (missing, disabled by environment), or null.
    string Unavailable();
    /// Names the engine build. A step recorded under another identity is not trusted.
    string Identity();
    /// Runs one step. When stop() turns true it must ask the engine to drain and save, then return.
    EngineExit Run(Installation game,FirstRunStep step,Action<StepProgress> progress,Func<bool> stop);
    /// The engine's own warm check ("precompile --check"): recipes with no host pipeline, null = no answer.
    int? Outstanding(Installation game);
}

internal sealed class FirstRunOptions {
    internal string Selection, Cache, SkipPreflight;
    internal IFirstRunEngine Engine;
    internal Func<Installation,PreflightFacts> Facts;
    /// Validates that a launch is possible and returns the launch. Called in step 2, run in step 5.
    internal Func<Installation,Func<int>> Prepare;
    internal Func<bool> Stop = () => false;
    internal Func<DateTime> Now = () => DateTime.UtcNow;
    internal Func<Exception,string> Describe = ex => ex.Message;
    internal TextWriter Out = Console.Out;
}

/// "precompile 1101 2752 0" (verb, done, total, failed). The rules of preload.rs Progress::parse.
internal static class ProgressLine {
    internal static bool Parse(string line,string verb,out StepProgress value) {
        value = new StepProgress();
        if (line == null) return false;
        var parts = line.Split((char[])null,StringSplitOptions.RemoveEmptyEntries);
        long done, total, failed;
        if (parts.Length != 4 || parts[0] != verb) return false;
        if (!TryCount(parts[1],out done) || !TryCount(parts[2],out total) || !TryCount(parts[3],out failed)) return false;
        if (done > total || failed > done) return false;
        value = new StepProgress { Done = done, Total = total, Failed = failed };
        return true;
    }
    static bool TryCount(string text,out long n) {
        return Int64.TryParse(text,NumberStyles.None,CultureInfo.InvariantCulture,out n) && n <= UInt32.MaxValue;
    }
}

/// Items per second from what this run measured since it started; the rate recorded by an earlier
/// run only stands in until this run has finished something.
internal sealed class Throughput {
    readonly Func<DateTime> now; readonly DateTime started; readonly double prior;
    long first = -1, done, total;
    internal Throughput(Func<DateTime> clock,double priorRate) { now = clock; started = clock(); prior = priorRate; }
    internal void Observe(long doneNow,long totalNow) { if (first < 0) first = doneNow; done = doneNow; total = totalNow; }
    internal double Rate {
        get {
            double seconds = (now() - started).TotalSeconds; long delta = done - Math.Max(first,0);
            return first >= 0 && delta > 0 && seconds > 0 ? delta / seconds : prior;
        }
    }
    internal TimeSpan? Eta {
        get { double rate = Rate; return rate > 0 && total >= done ? (TimeSpan?)TimeSpan.FromSeconds((total - done) / rate) : null; }
    }
    internal static string Format(TimeSpan? eta) {
        if (!eta.HasValue) return "estimating";
        double s = Math.Ceiling(eta.Value.TotalSeconds);
        if (s < 60) return "under 1 min";
        long minutes = (long)Math.Ceiling(s / 60);
        return minutes < 60 ? "about " + minutes + " min" : "about " + (minutes / 60) + " h " + (minutes % 60).ToString("00") + " min";
    }
}

/// FromEngine: the files looked warm and the engine's own count said otherwise.
internal sealed class WarmResult { internal bool Ok, FromEngine; internal string Reason; }

/// The check bench/heavy.ps1 Test-WarmCache makes: the file checks first (the engine answers 0 for a
/// cache with no recipes), then the engine's own outstanding count, which must be exactly 0.
internal static class WarmCache {
    internal static WarmResult Verify(string cache,Installation game,IFirstRunEngine engine) {
        string cold = Preflight.ColdReason(cache);
        if (cold != null) return new WarmResult { Reason = cold };
        int? outstanding = engine.Outstanding(game);
        if (!outstanding.HasValue) return new WarmResult { FromEngine = true, Reason = "the engine gave no 'precompile-check N' line" };
        if (outstanding.Value != 0) return new WarmResult { FromEngine = true, Reason = outstanding.Value + " recorded pipeline recipes have no published host pipeline for this engine build and adapter" };
        return new WarmResult { Ok = true, Reason = "warm" };
    }
}

internal sealed class StepRecord {
    public bool complete { get; set; }
    public long done { get; set; }
    public long total { get; set; }
    public long failed { get; set; }
    public double rate { get; set; }
    public string identity { get; set; }
}

internal sealed class FirstRunState {
    public int version { get; set; }
    public Dictionary<string,StepRecord> steps { get; set; }
    internal const string FileName = "first-run-v1.json";
    internal static FirstRunState Load(string path) {
        try {
            if (File.Exists(path)) {
                var state = Files.Json.Deserialize<FirstRunState>(File.ReadAllText(path));
                if (state != null && state.version == 1 && state.steps != null) return state;
            }
        } catch (Exception) {}   // unreadable state only means "nothing recorded"; the engine owns the real work
        return new FirstRunState { version = 1, steps = new Dictionary<string,StepRecord>() };
    }
    internal StepRecord Record(string id) {
        StepRecord r;
        if (!steps.TryGetValue(id,out r)) { r = new StepRecord(); steps[id] = r; }
        return r;
    }
    internal void Save(string path) {
        string temp = Files.Unique(Path.GetDirectoryName(path));
        File.WriteAllText(temp,Files.Json.Serialize(this));
        Files.Publish(temp,path);
    }
}

internal static class GameResolver {
    /// A folder resolves to the one executable MicrosoftGame.Config declares for Scarlett; an
    /// executable resolves to itself, wherever the manifest sits above it. Zero or several declared
    /// is a refusal that names them.
    internal static Installation Resolve(string selection,Func<Exception,string> describe) {
        if (String.IsNullOrWhiteSpace(selection))
            throw new FirstRunFailure("resolve",FirstRun.Refused,"no game given. Pass the game folder or its executable: --first-run <folder-or-exe>.");
        try {
            string path;
            try { path = Files.Full(Path.GetFullPath(selection)); }
            catch (ArgumentException) { throw new Problem("unsafePath"); }
            catch (NotSupportedException) { throw new Problem("unsafePath"); }
            if (!Directory.Exists(path)) return Installation.Select(path);
            var declared = Installation.Declared(path);
            if (declared == null)
                throw new FirstRunFailure("resolve",FirstRun.Refused,"no MicrosoftGame.Config in '" + path + "'. Pass the folder that contains it, or the executable itself.");
            var names = declared.OrderBy(n => n,StringComparer.OrdinalIgnoreCase).ToList();
            if (names.Count == 0)
                throw new FirstRunFailure("resolve",FirstRun.Refused,"MicrosoftGame.Config in '" + path + "' declares no executable for Scarlett.");
            if (names.Count > 1)
                throw new FirstRunFailure("resolve",FirstRun.Refused,"MicrosoftGame.Config in '" + path + "' declares " + names.Count + " executables: " +
                    String.Join("; ",names) + ". Refusing to guess; pass the one you mean as the executable path.");
            if (!File.Exists(names[0]))
                throw new FirstRunFailure("resolve",FirstRun.Refused,"MicrosoftGame.Config declares '" + names[0] + "' but that file is not there. Restore it, then retry.");
            return Installation.Select(names[0]);
        } catch (Problem ex) { throw new FirstRunFailure("resolve",FirstRun.Refused,describe(ex)); }
    }
}

internal static class FirstRun {
    internal const int Refused = 2, Cold = 3, StepFailed = 4, GameFailed = 5, Interrupted = 130, Unexpected = 1;
    const string Resume = " Run the same command again to resume; finished work is kept.";

    /// Phase 1 translates every shader. Phase 2 builds the pipelines: the pack-based prebuild, then the
    /// recorded recipes (which writes the precompiled-v1.txt receipt the warm check requires).
    /// The engine owns the partial work inside a step; first-run only decides which steps to invoke.
    internal static readonly FirstRunStep[] Steps = {
        new FirstRunStep { Id = "translate", Phase = "shaders", Title = "translate every shader", Verb = "translate",
            Args = new[]{"translate","--cache","{cache}"} },
        new FirstRunStep { Id = "pipelines-pack", Phase = "pipelines", Title = "queue pipelines from the shader pack", Verb = "translate",
            Args = new[]{"translate","--cache","{cache}","--pipelines"} },
        new FirstRunStep { Id = "pipelines-build", Phase = "pipelines", Title = "build the recorded pipelines", Verb = "precompile",
            Args = new[]{"precompile","--cache","{cache}"} },
    };

    static void Say(FirstRunOptions o,string text) { o.Out.WriteLine(text); o.Out.Flush(); }
    static string Count(long n) { return n.ToString("N0",CultureInfo.InvariantCulture); }

    internal static int Run(FirstRunOptions o) {
        try {
            Say(o,"[1/5] resolve the game");
            var game = GameResolver.Resolve(o.Selection,o.Describe);
            Say(o,"      " + game.Image);

            Say(o,"[2/5] preflight (before the cache is touched)");
            Func<int> launch = CheckPreflight(o,game);

            Say(o,"[3/5] precompile");
            var warm = WarmCache.Verify(o.Cache,game,o.Engine);
            if (warm.Ok) {
                Say(o,"      the cache is already warm: nothing to compile");
                Say(o,"[4/5] verify");
                Say(o,"      warm (checked above, as bench/heavy.ps1 checks it)");
            } else {
                Say(o,"      the cache is cold: " + warm.Reason);
                // Files that look finished while the engine says otherwise: a step recorded "done" is stale.
                if (warm.FromEngine) Reopen(o);
                Precompile(o,game);
                Say(o,"[4/5] verify");
                warm = WarmCache.Verify(o.Cache,game,o.Engine);
                if (!warm.Ok) {
                    Reopen(o);
                    throw new FirstRunFailure("verify",Cold,"the cache is still cold after precompile: " + warm.Reason +
                        ". Not launching: a cold cache draws wrong and is the problem this command exists to prevent." + Resume);
                }
                Say(o,"      warm");
            }

            Say(o,"[5/5] launch");
            int status = launch();
            if (status != 0) throw new FirstRunFailure("launch",GameFailed,"the game exited with status " + status + ".");
            return 0;
        } catch (FirstRunFailure f) {
            Say(o,"first-run stopped at step '" + f.Step + "': " + f.Message);
            return f.Code;
        } catch (Exception ex) {
            Say(o,"first-run failed unexpectedly: " + o.Describe(ex) + " Compiled work is untouched." + Resume);
            return Unexpected;
        }
    }

    /// Step 2. Read-only: it never creates the cache directory.
    static Func<int> CheckPreflight(FirstRunOptions o,Installation game) {
        try { Files.Separate(game.Root,o.Cache); }
        catch (Problem ex) { throw new FirstRunFailure("preflight",Refused,o.Describe(ex)); }
        string unavailable = o.Engine.Unavailable();
        if (unavailable != null) throw new FirstRunFailure("preflight",Refused,unavailable);
        Func<int> launch;
        try { launch = o.Prepare(game); }
        catch (Problem ex) { throw new FirstRunFailure("preflight",Refused,o.Describe(ex)); }
        var results = Preflight.Run(o.Facts(game));
        // A cold cache is the reason to be here: step 3 reports it, and step 4 is its gate. Every other blocking check gates here.
        var gating = results.Where(q => q.Id != "pipelineCache").ToList();
        foreach (var r in gating.Where(q => q.Level == PreflightLevel.Warn || q.Level == PreflightLevel.Block))
            Say(o,"      " + (r.Level == PreflightLevel.Block ? "BLOCK " : "warn  ") + r.Id + ": " + r.Message);
        var gate = Preflight.Gate(gating,o.SkipPreflight);
        if (!gate.Proceed) throw new FirstRunFailure("preflight",Refused,gate.Report + "\n      Nothing was written to the cache.");
        if (gate.Report.Length > 0) Say(o,"      " + gate.Report.Replace("\n","\n      "));
        Say(o,"      ok");
        return launch;
    }

    /// Names the build, the game image and the shader folder's creation time, so a step recorded for
    /// an older engine, another game or a cleared shader folder is run again instead of trusted.
    static string Identity(FirstRunOptions o,Installation game) {
        string shaders = Path.Combine(o.Cache,"shaders"), image = game.Image;
        var info = new FileInfo(image);
        return o.Engine.Identity() + "|" + image.ToLowerInvariant() + "|" + (info.Exists ? info.Length : -1) + "|" +
            (info.Exists ? info.LastWriteTimeUtc.Ticks : 0) + "|" + (Directory.Exists(shaders) ? Directory.GetCreationTimeUtc(shaders).Ticks : 0);
    }

    static string StatePath(FirstRunOptions o) { return Path.Combine(o.Cache,FirstRunState.FileName); }

    static void Save(FirstRunOptions o,FirstRunState state) {
        try { state.Save(StatePath(o)); }
        catch (IOException ex) { Say(o,"      warning: could not record progress (" + ex.Message + "); the engine's own work is unaffected."); }
        catch (UnauthorizedAccessException ex) { Say(o,"      warning: could not record progress (" + ex.Message + "); the engine's own work is unaffected."); }
    }

    /// A failed verify means a finished pipeline step was not enough. Reopen the pipeline steps (only
    /// their bookkeeping; compiled work stays) so the next run calls the engine, which retries what failed.
    static void Reopen(FirstRunOptions o) {
        var state = FirstRunState.Load(StatePath(o));
        foreach (var step in Steps.Where(s => s.Phase == "pipelines")) state.Record(step.Id).complete = false;
        Save(o,state);
    }

    static void Precompile(FirstRunOptions o,Installation game) {
        Directory.CreateDirectory(o.Cache);
        var state = FirstRunState.Load(StatePath(o));
        var sync = new object();
        for (int i = 0; i < Steps.Length; i++) {
            var step = Steps[i]; var rec = state.Record(step.Id);
            if (o.Stop()) throw new FirstRunFailure("precompile",Interrupted,"interrupted before '" + step.Id + "' started." + Resume);
            if (rec.complete && rec.identity == Identity(o,game)) { Say(o,"      " + step.Id + ": finished in an earlier run, kept"); continue; }
            rec.complete = false;
            Say(o,"      (" + (i + 1) + "/" + Steps.Length + ") " + step.Phase + ": " + step.Title);
            var meter = new Throughput(o.Now,rec.rate);
            var last = new StepProgress(); DateTime lastSaid = DateTime.MinValue, lastSaved = o.Now();
            var exit = o.Engine.Run(game,step,delegate(StepProgress p) {
                lock (sync) {
                    last = p; meter.Observe(p.Done,p.Total);
                    rec.done = p.Done; rec.total = p.Total; rec.failed = p.Failed; rec.rate = meter.Rate;
                    DateTime t = o.Now();
                    if (lastSaid == DateTime.MinValue || (t - lastSaid).TotalSeconds >= 5 || p.Done == p.Total) {
                        lastSaid = t;
                        Say(o,"        " + step.Id + " " + Count(p.Done) + " / " + Count(p.Total) + " (" + (p.Total == 0 ? 100 : p.Done * 100 / p.Total) + "%)" +
                            (p.Failed > 0 ? ", " + Count(p.Failed) + " failed" : "") + "  " + meter.Rate.ToString("0.0",CultureInfo.InvariantCulture) + "/s  ETA " + Throughput.Format(meter.Eta));
                    }
                    if ((t - lastSaved).TotalSeconds >= 10) { lastSaved = t; Save(o,state); }
                }
            },o.Stop);
            lock (sync) {
                bool stopped = o.Stop();
                // Exit 0 under a stop request means "drained and saved", not "finished": only the counts say finished.
                bool finished = exit.Code == 0 && (!stopped || (last.Total > 0 && last.Done == last.Total));
                rec.rate = meter.Rate;
                if (!finished) {
                    Save(o,state);
                    if (stopped) throw new FirstRunFailure("precompile (" + step.Id + ")",Interrupted,"interrupted at " + Count(last.Done) + " / " + Count(last.Total) + "." + Resume);
                    throw new FirstRunFailure("precompile (" + step.Id + ")",StepFailed,"the engine exited with status " + exit.Code +
                        (String.IsNullOrWhiteSpace(exit.Tail) ? "" : ":\n" + exit.Tail.TrimEnd()) + "\n      " + Resume.Trim());
                }
                rec.complete = true; rec.identity = Identity(o,game);
                Save(o,state);
                if (last.Failed > 0) Say(o,"      " + step.Id + ": " + Count(last.Failed) + " item(s) failed; the verify step decides whether that matters");
                Say(o,"      " + step.Id + ": done");
            }
        }
    }
}
}
