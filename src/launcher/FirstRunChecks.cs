using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace Kelvaroq {
/// Suite "firstrun": --self-test firstrun. No title data and no engine: the fixtures are empty
/// placeholder files, and FakeEngine keeps its partial work on disk the way the real engine does,
/// so "resume" and "never restart" are checked against files, not against a flag.
internal static class FirstRunChecks {
    static void Check(bool ok) { Checks.Check(ok); }

    /// Units per step (translate, pack, build): 30 + 10 + 60.
    static readonly int[] Totals = {30,10,60};

    sealed class FakeEngine : IFirstRunEngine {
        readonly string cache;
        internal readonly List<string> Ran = new List<string>();
        internal readonly Queue<int> Answers = new Queue<int>();   // consumed by Outstanding(); then the receipt decides
        internal int Compiled, OutstandingCalls;
        internal volatile bool StopFlag;
        internal string InterruptStep, FailStep, Down, Id = "engine-1";
        internal int InterruptAfter;
        internal FakeEngine(string cacheDir) { cache = cacheDir; }
        public string Unavailable() { return Down; }
        public string Identity() { return Id; }
        string UnitFile(string step,int n) {
            return step == "translate" ? Path.Combine(cache,"shaders","s" + n)
                 : step == "pipelines-pack" ? Path.Combine(cache,"pipelines","warm-v1","r" + n)
                 : Path.Combine(cache,"pipelines","built-" + n);
        }
        public EngineExit Run(Installation game,FirstRunStep step,Action<StepProgress> progress,Func<bool> stop) {
            Ran.Add(step.Id);
            int total = Totals[Array.FindIndex(FirstRun.Steps,s => s.Id == step.Id)];
            string counter = Path.Combine(cache,step.Id + ".count");
            int done = File.Exists(counter) ? Int32.Parse(File.ReadAllText(counter)) : 0;
            Directory.CreateDirectory(Path.Combine(cache,"shaders")); Directory.CreateDirectory(Path.Combine(cache,"pipelines","warm-v1"));
            if (step.Id == FailStep) return new EngineExit { Code = 1, Tail = "boom" };
            progress(new StepProgress { Done = done, Total = total });
            // Like the real engine: a stop request drains, saves and exits 0 with work left over.
            while (done < total && !stop()) {
                done++; Compiled++;
                File.WriteAllText(UnitFile(step.Id,done),"unit " + done);
                File.WriteAllText(counter,done.ToString());
                progress(new StepProgress { Done = done, Total = total });
                if (step.Id == InterruptStep && done == InterruptAfter) StopFlag = true;
            }
            if (done == total && step.Id == "pipelines-build") File.WriteAllText(Path.Combine(cache,"pipelines","precompiled-v1.txt"),"receipt");
            return new EngineExit();
        }
        public int? Outstanding(Installation game) {
            OutstandingCalls++;
            if (Answers.Count > 0) return Answers.Dequeue();
            return File.Exists(Path.Combine(cache,"pipelines","precompiled-v1.txt")) ? 0 : 1;
        }
    }

    sealed class Launches { internal int Prepared, Launched; }

    static string Game(string root,string name,string[] declared,string[] present) {
        string folder = Path.Combine(root,name); Directory.CreateDirectory(folder);
        var xml = new StringBuilder("<Game><ExecutableList>");
        foreach (string exe in declared) xml.Append("<Executable Name='" + exe + "' TargetDeviceFamily='Scarlett'/>");
        xml.Append("</ExecutableList></Game>");
        File.WriteAllText(Path.Combine(folder,"MicrosoftGame.Config"),xml.ToString());
        foreach (string exe in present) {
            string file = Path.Combine(folder,exe); Directory.CreateDirectory(Path.GetDirectoryName(file)); File.WriteAllBytes(file,new byte[0]);
        }
        File.WriteAllBytes(Path.Combine(folder,"appdata0.rpf"),new byte[0]);
        return folder;
    }

    static PreflightFacts Facts(Installation game,string cache,long commit) {
        var hardware = Hardware.Sample(); hardware.Preferred.DriverDate = Checks.FixtureNow.AddMonths(-1);
        return new PreflightFacts { CommitLimit = commit, Hardware = hardware, GameRoot = game.Root, Image = game.Image, CacheDir = cache,
            Engines = new List<string>(), Gamepad = true, RunPaths = new[]{@"C:\vt\kelvaroq-desktop.exe"}, Now = Checks.FixtureNow };
    }

    static FirstRunOptions Options(string selection,string cache,FakeEngine engine,Launches launches,long commit) {
        return new FirstRunOptions { Selection = selection, Cache = cache, SkipPreflight = null, Engine = engine, Out = new StringWriter(),
            Facts = game => Facts(game,cache,commit),
            Prepare = game => { launches.Prepared++; return delegate { launches.Launched++; return 0; }; },
            Stop = () => engine.StopFlag };
    }

    static string Refusal(Action action) {
        try { action(); }
        catch (FirstRunFailure f) { Check(f.Code == FirstRun.Refused && f.Step == "resolve"); return f.Message; }
        throw new InvalidOperationException("Unexpected success");
    }

    /// Every file under dir with its content, minus the bookkeeping that is allowed to change between runs.
    static Dictionary<string,string> Snapshot(string dir) {
        var all = new Dictionary<string,string>();
        if (!Directory.Exists(dir)) return all;
        foreach (string file in Directory.EnumerateFiles(dir,"*",SearchOption.AllDirectories))
            if (!file.EndsWith(".count") && !file.EndsWith(".json")) all[file.Substring(dir.Length)] = File.ReadAllText(file);
        return all;
    }

    static FirstRunState State(string cache) { return FirstRunState.Load(Path.Combine(cache,FirstRunState.FileName)); }

    internal static void Run(string root) {
        Resolver(root);
        Meter();
        ColdToLaunch(root);
        WarmShortCircuit(root);
        Interrupted(root);
        FailedVerify(root);
        FailedStep(root);
        PreflightBlocks(root);
    }

    static void Resolver(string root) {
        Func<Exception,string> plain = ex => ex.Message;
        string one = Game(root,"one",new[]{"bin/sample.exe"},new[]{"bin/sample.exe"});
        string exe = Path.Combine(one,"bin","sample.exe");
        Check(GameResolver.Resolve(one,plain).Image == exe && GameResolver.Resolve(one,plain).Root == one);
        Check(GameResolver.Resolve(exe,plain).Image == exe);   // an executable resolves to itself, folder or not

        string several = Game(root,"several",new[]{"a.exe","b.exe"},new[]{"a.exe","b.exe"});
        string text = Refusal(() => GameResolver.Resolve(several,plain));
        Check(text.Contains("2 executables") && text.Contains("a.exe") && text.Contains("b.exe"));
        Check(GameResolver.Resolve(Path.Combine(several,"b.exe"),plain).Image == Path.Combine(several,"b.exe"));   // naming one is the way out

        string zero = Game(root,"zero",new string[0],new string[0]);
        Check(Refusal(() => GameResolver.Resolve(zero,plain)).Contains("declares no executable"));
        string bare = Path.Combine(root,"bare"); Directory.CreateDirectory(bare);
        Check(Refusal(() => GameResolver.Resolve(bare,plain)).Contains("no MicrosoftGame.Config"));
        string gone = Game(root,"gone",new[]{"missing.exe"},new string[0]);
        text = Refusal(() => GameResolver.Resolve(gone,plain));
        Check(text.Contains("missing.exe") && text.Contains("not there"));
        Check(Refusal(() => GameResolver.Resolve(null,plain)).Contains("no game given"));
        Check(Refusal(() => GameResolver.Resolve("  ",plain)).Contains("no game given"));
        // Folder selection must not have changed what Select already refused.
        Reject(() => Installation.Select(several));
    }
    static void Reject(Action action) { Checks.Reject(action); }

    static void Meter() {
        StepProgress p;
        Check(ProgressLine.Parse("precompile 1101 2752 0","precompile",out p) && p.Done == 1101 && p.Total == 2752 && p.Failed == 0);
        Check(ProgressLine.Parse("translate 5 5 2","translate",out p) && p.Failed == 2);
        foreach (string bad in new[]{"precompile 9 8 0","precompile 1 2 2","precompile 1 2","log 1 2 0","precompile 1 2 0 x","precompile -1 2 0","precompile-check 3","translate 1 2 0",""})
            Check(!ProgressLine.Parse(bad,"precompile",out p));

        DateTime t = new DateTime(2026,11,26,12,0,0,DateTimeKind.Utc);
        var measured = new Throughput(() => t,0);
        Check(measured.Eta == null && Throughput.Format(measured.Eta) == "estimating");
        measured.Observe(100,1100); t = t.AddSeconds(10); measured.Observe(200,1100);
        Check(Math.Abs(measured.Rate - 10.0) < 1e-9 && Math.Abs(measured.Eta.Value.TotalSeconds - 90.0) < 1e-9);
        Check(Throughput.Format(measured.Eta) == "about 2 min");
        // A resumed run measures only what it did itself: 40 already done is not throughput.
        t = new DateTime(2026,11,26,12,0,0,DateTimeKind.Utc);
        var resumed = new Throughput(() => t,0);
        resumed.Observe(40,100); t = t.AddSeconds(20); resumed.Observe(60,100);
        Check(Math.Abs(resumed.Rate - 1.0) < 1e-9 && Math.Abs(resumed.Eta.Value.TotalSeconds - 40.0) < 1e-9);
        // The recorded rate only stands in until this run has finished something.
        var prior = new Throughput(() => t,4.0); prior.Observe(0,100);
        Check(prior.Rate == 4.0 && Math.Abs(prior.Eta.Value.TotalSeconds - 25.0) < 1e-9 && Throughput.Format(prior.Eta) == "under 1 min");
        Check(Throughput.Format(TimeSpan.FromMinutes(185)) == "about 3 h 05 min");
    }

    static void ColdToLaunch(string root) {
        string game = Game(root,"cold",new[]{"sample.exe"},new[]{"sample.exe"}), cache = Path.Combine(root,"cache-cold");
        var engine = new FakeEngine(cache); var launches = new Launches();
        var options = Options(game,cache,engine,launches,96L << 30);
        int code = FirstRun.Run(options);
        string text = options.Out.ToString();
        Check(code == 0 && launches.Launched == 1 && launches.Prepared == 1);
        // Shaders are translated before any pipeline is built, and nothing runs twice.
        Check(engine.Ran.SequenceEqual(new[]{"translate","pipelines-pack","pipelines-build"}));
        Check(engine.Compiled == Totals.Sum() && engine.OutstandingCalls == 1);
        Check(text.IndexOf("[2/5]") < text.IndexOf("[3/5]") && text.IndexOf("[3/5]") < text.IndexOf("[4/5]") && text.IndexOf("[4/5]") < text.IndexOf("[5/5]"));
        Check(text.Contains("ETA") && text.Contains("the cache is cold"));
        var state = State(cache);
        Check(FirstRun.Steps.All(s => state.steps[s.Id].complete));
    }

    static void WarmShortCircuit(string root) {
        string game = Game(root,"warm",new[]{"sample.exe"},new[]{"sample.exe"}), cache = Path.Combine(root,"cache-warm");
        var first = new FakeEngine(cache);
        Check(FirstRun.Run(Options(game,cache,first,new Launches(),96L << 30)) == 0);
        var before = Snapshot(cache); string stateBefore = File.ReadAllText(Path.Combine(cache,FirstRunState.FileName));

        // The second invocation: steps 1, 2 and 4, then the launch. No engine step, no write.
        var second = new FakeEngine(cache); var launches = new Launches();
        var options = Options(game,cache,second,launches,96L << 30);
        Check(FirstRun.Run(options) == 0);
        Check(second.Ran.Count == 0 && second.Compiled == 0 && second.OutstandingCalls == 1 && launches.Launched == 1);
        Check(options.Out.ToString().Contains("nothing to compile"));
        var after = Snapshot(cache);
        Check(before.Count == after.Count && before.All(kv => after.ContainsKey(kv.Key) && after[kv.Key] == kv.Value));
        Check(File.ReadAllText(Path.Combine(cache,FirstRunState.FileName)) == stateBefore);

        // The engine disagreeing is a cold cache, whatever the files say.
        var disagree = new FakeEngine(cache); disagree.Answers.Enqueue(7); launches = new Launches();
        Check(FirstRun.Run(Options(game,cache,disagree,launches,96L << 30)) == 0 && disagree.Ran.Count > 0 && launches.Launched == 1);
        // An unreadable state file is "nothing recorded", not a crash.
        File.WriteAllText(Path.Combine(cache,FirstRunState.FileName),"{ not json");
        Check(FirstRunState.Load(Path.Combine(cache,FirstRunState.FileName)).steps.Count == 0);
    }

    static void Interrupted(string root) {
        string game = Game(root,"resume",new[]{"sample.exe"},new[]{"sample.exe"}), cache = Path.Combine(root,"cache-resume");
        var first = new FakeEngine(cache) { InterruptStep = "pipelines-build", InterruptAfter = 25 }; var launches = new Launches();
        var options = Options(game,cache,first,launches,96L << 30);
        Check(FirstRun.Run(options) == FirstRun.Interrupted && launches.Launched == 0);
        Check(options.Out.ToString().Contains("Run the same command again to resume"));
        Check(first.Compiled == 30 + 10 + 25 && !File.Exists(Path.Combine(cache,"pipelines","precompiled-v1.txt")));
        var halfway = Snapshot(cache); var state = State(cache);
        Check(state.steps["translate"].complete && state.steps["pipelines-pack"].complete && !state.steps["pipelines-build"].complete && state.steps["pipelines-build"].done == 25);

        // The next invocation picks up at the 26th unit: finished steps are not invoked, nothing is redone.
        var second = new FakeEngine(cache);
        Check(FirstRun.Run(Options(game,cache,second,launches,96L << 30)) == 0);
        Check(second.Ran.SequenceEqual(new[]{"pipelines-build"}));
        Check(second.Compiled == 35 && first.Compiled + second.Compiled == Totals.Sum());
        var after = Snapshot(cache);
        Check(halfway.All(kv => after.ContainsKey(kv.Key) && after[kv.Key] == kv.Value));   // partial work kept, byte for byte
        Check(launches.Launched == 1);

        // Another engine build must not trust the recorded steps: it is asked again (it reuses its own work).
        var rebuilt = new FakeEngine(cache) { Id = "engine-2" }; rebuilt.Answers.Enqueue(3);
        Check(FirstRun.Run(Options(game,cache,rebuilt,new Launches(),96L << 30)) == 0);
        Check(rebuilt.Ran.SequenceEqual(new[]{"translate","pipelines-pack","pipelines-build"}) && rebuilt.Compiled == 0);
    }

    static void FailedVerify(string root) {
        string game = Game(root,"verify",new[]{"sample.exe"},new[]{"sample.exe"}), cache = Path.Combine(root,"cache-verify");
        var first = new FakeEngine(cache); first.Answers.Enqueue(5); var launches = new Launches();
        var options = Options(game,cache,first,launches,96L << 30);
        Check(FirstRun.Run(options) == FirstRun.Cold && launches.Launched == 0);
        Check(options.Out.ToString().Contains("still cold") && options.Out.ToString().Contains("Not launching"));
        // The verify failure reopens the pipeline steps only; the shaders stay done.
        var state = State(cache);
        Check(state.steps["translate"].complete && !state.steps["pipelines-pack"].complete && !state.steps["pipelines-build"].complete);
        var compiled = Snapshot(cache);

        var second = new FakeEngine(cache); second.Answers.Enqueue(5); second.Answers.Enqueue(0);
        Check(FirstRun.Run(Options(game,cache,second,launches,96L << 30)) == 0);
        Check(second.Ran.SequenceEqual(new[]{"pipelines-pack","pipelines-build"}) && second.Compiled == 0 && launches.Launched == 1);
        Check(compiled.All(kv => Snapshot(cache).ContainsKey(kv.Key)));

        // No answer from the engine is not "warm" either.
        string noAnswer = Path.Combine(root,"cache-noanswer");
        var silent = new FakeEngine(noAnswer) { Down = null }; var none = new Launches();
        Directory.CreateDirectory(Path.Combine(noAnswer,"shaders")); Directory.CreateDirectory(Path.Combine(noAnswer,"pipelines","warm-v1"));
        File.WriteAllText(Path.Combine(noAnswer,"pipelines","warm-v1","r1"),"x"); File.WriteAllText(Path.Combine(noAnswer,"pipelines","precompiled-v1.txt"),"receipt");
        Check(!WarmCache.Verify(noAnswer,new Installation(),new NoAnswerEngine()).Ok && WarmCache.Verify(noAnswer,new Installation(),silent).Ok);
    }
    sealed class NoAnswerEngine : IFirstRunEngine {
        public string Unavailable() { return null; }
        public string Identity() { return "x"; }
        public EngineExit Run(Installation game,FirstRunStep step,Action<StepProgress> progress,Func<bool> stop) { return new EngineExit(); }
        public int? Outstanding(Installation game) { return null; }
    }

    static void FailedStep(string root) {
        string game = Game(root,"failed",new[]{"sample.exe"},new[]{"sample.exe"}), cache = Path.Combine(root,"cache-failed");
        var first = new FakeEngine(cache) { FailStep = "pipelines-build" }; var launches = new Launches();
        var options = Options(game,cache,first,launches,96L << 30);
        Check(FirstRun.Run(options) == FirstRun.StepFailed && launches.Launched == 0);
        Check(options.Out.ToString().Contains("pipelines-build") && options.Out.ToString().Contains("boom"));
        var state = State(cache);
        Check(state.steps["translate"].complete && state.steps["pipelines-pack"].complete && !state.steps["pipelines-build"].complete);
        var second = new FakeEngine(cache);
        Check(FirstRun.Run(Options(game,cache,second,launches,96L << 30)) == 0 && second.Ran.SequenceEqual(new[]{"pipelines-build"}) && launches.Launched == 1);
    }

    static void PreflightBlocks(string root) {
        string game = Game(root,"blocked",new[]{"sample.exe"},new[]{"sample.exe"}), cache = Path.Combine(root,"cache-blocked");
        var engine = new FakeEngine(cache); var launches = new Launches();
        var options = Options(game,cache,engine,launches,10L << 30);   // under the 80 GiB commit floor
        Check(FirstRun.Run(options) == FirstRun.Refused);
        string text = options.Out.ToString();
        Check(text.Contains("commit") && text.Contains("Nothing was written to the cache"));
        // Preflight comes first: the cache is not even created, the engine is never called, nothing launches.
        Check(!Directory.Exists(cache) && engine.Ran.Count == 0 && engine.OutstandingCalls == 0 && launches.Launched == 0);
        Check(!text.Contains("[3/5]"));
        // The cold cache alone is not a preflight failure here; any other blocking check still is.
        engine = new FakeEngine(cache) { Down = "engine missing" }; var down = new Launches();
        Check(FirstRun.Run(Options(game,cache,engine,down,96L << 30)) == FirstRun.Refused && !Directory.Exists(cache) && down.Prepared == 0);
        // Not a resolvable game: refused at step 1, and the cache still is not touched.
        string noGame = Path.Combine(root,"nothing-here");
        Check(FirstRun.Run(Options(noGame,cache,engine,launches,96L << 30)) == FirstRun.Refused && !Directory.Exists(cache));
        // A game folder holding the cache would let a precompile write into the title's tree.
        Check(FirstRun.Run(Options(game,Path.Combine(game,"cache"),new FakeEngine(Path.Combine(game,"cache")),launches,96L << 30)) == FirstRun.Refused
            && !Directory.Exists(Path.Combine(game,"cache")));
        Check(launches.Launched == 0);
    }
}
}
