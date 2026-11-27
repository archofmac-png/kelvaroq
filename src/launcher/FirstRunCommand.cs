using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace Kelvaroq {
/// The real engine and launch behind FirstRun. kelvaroq-desktop.exe --first-run [folder-or-exe].
/// Exit codes: 0 launched and the game exited cleanly | 1 unexpected | 2 refused before any work
/// (game, preflight, engine) | 3 cache still cold after precompile (not launched) | 4 an engine step
/// failed | 5 the game exited non-zero | 130 interrupted. 3, 4 and 130 leave state the next run resumes.
/// The launcher is a windows-subsystem exe: wait for it with Start-Process -Wait -PassThru.
internal sealed class ProcessEngine : IFirstRunEngine {
    /// After the engine is asked to drain (stdin closed, the protocol of precompile.rs), it gets this
    /// long to save before it is ended. What it had saved is kept either way.
    static readonly TimeSpan Grace = TimeSpan.FromSeconds(90);
    readonly string engine; readonly Preferences prefs; readonly Locale locale; readonly Hardware hardware;
    internal ProcessEngine(Preferences preferences,Locale language,Hardware machine) {
        engine = Product.EngineIn(Path.Combine(Product.Base,"native")); prefs = preferences; locale = language; hardware = machine;
    }
    public string Unavailable() {
        if (!File.Exists(engine)) return "the engine was not found at '" + engine + "'. Reinstall the package.";
        if (!Product.PreloadAllowed) return "VICTORY_PIPELINE_PRECOMPILE or VICTORY_PIPELINE_WARMUP is 0 in the environment, so the engine will not record or build pipelines. Unset it and retry.";
        return null;
    }
    public string Identity() {
        var info = new FileInfo(engine);
        return info.Exists ? info.Length + ":" + info.LastWriteTimeUtc.Ticks : "missing";
    }
    ProcessStartInfo Start(Installation game,IEnumerable<string> args) {
        var start = new ProcessStartInfo(engine,String.Join(" ",args.Select(a => "\"" + a.Replace("{cache}",prefs.ActiveCache) + "\""))) {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(engine),
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        Product.Configure(start,game,prefs,locale,false,hardware);
        start.EnvironmentVariables["VICTORY_PIPELINE_PRECOMPILE"] = "1";   // this command exists to build them, whatever the play setting is
        return start;
    }
    static void Keep(Queue<string> tail,string line) { lock (tail) { tail.Enqueue(line); while (tail.Count > 20) tail.Dequeue(); } }
    public EngineExit Run(Installation game,FirstRunStep step,Action<StepProgress> progress,Func<bool> stop) {
        var tail = new Queue<string>();
        using (var child = new Process { StartInfo = Start(game,step.Args) }) {
            child.OutputDataReceived += delegate(object sender,DataReceivedEventArgs e) {
                if (e.Data == null) return;
                StepProgress p;
                if (ProgressLine.Parse(e.Data,step.Verb,out p)) progress(p); else Keep(tail,e.Data);
            };
            child.ErrorDataReceived += delegate(object sender,DataReceivedEventArgs e) { if (e.Data != null) Keep(tail,e.Data); };
            child.Start(); child.BeginOutputReadLine(); child.BeginErrorReadLine();
            bool asked = false; DateTime askedAt = DateTime.UtcNow;
            while (!child.WaitForExit(200)) {
                if (!asked && stop()) {
                    asked = true; askedAt = DateTime.UtcNow;
                    try { child.StandardInput.Close(); } catch (IOException) {}
                }
                if (asked && DateTime.UtcNow - askedAt > Grace) { try { child.Kill(); } catch (InvalidOperationException) {} child.WaitForExit(); break; }
            }
            child.WaitForExit();   // lets the async readers deliver the last lines
            lock (tail) return new EngineExit { Code = child.ExitCode, Tail = String.Join("\n",tail) };
        }
    }
    public int? Outstanding(Installation game) {
        using (var child = new Process { StartInfo = Start(game,new[]{"precompile","--check","--cache","{cache}"}) }) {
            child.Start(); child.StandardInput.Close();
            var errors = child.StandardError.ReadToEndAsync();
            string output = child.StandardOutput.ReadToEnd();
            if (!child.WaitForExit(180000)) { try { child.Kill(); } catch (InvalidOperationException) {} return null; }
            var match = Regex.Match(output,@"precompile-check\s+(\d+)");
            int n;
            return match.Success && Int32.TryParse(match.Groups[1].Value,out n) ? (int?)n : null;
        }
    }
}

internal static class FirstRunCommand {
    static volatile bool stopRequested;

    internal static int Run(string[] args,string home,Preferences prefs,Locale locale) {
        var rest = args.Skip(1).ToArray();
        if (rest.Length > 1) { Console.Error.WriteLine("usage: kelvaroq-desktop.exe --first-run [game-folder-or-exe]"); return FirstRun.Refused; }
        // Ctrl+C asks the engine to drain and save, then stops. The second Ctrl+C is not swallowed.
        Console.CancelKeyPress += delegate(object sender,ConsoleCancelEventArgs e) {
            if (stopRequested) return;
            stopRequested = true; e.Cancel = true;
            Console.Error.WriteLine("first-run: interrupt requested, saving what the engine has built...");
        };
        var hardware = Hardware.Enabled ? Hardware.Detect() : null;
        var build = Product.Build();
        var options = new FirstRunOptions {
            Selection = rest.Length == 1 ? rest[0] : prefs.executable,
            Cache = prefs.ActiveCache,
            SkipPreflight = Preflight.SkipRequested,
            Engine = new ProcessEngine(prefs,locale,hardware),
            Facts = game => PreflightFacts.Live(hardware,game.Root,game.Image,prefs.ActiveCache),
            Stop = () => stopRequested,
            Describe = locale.Error,
            Out = Console.Out,
            // Same launch as the window's Launch(): the command, the data snapshots around it, the child's stderr.
            Prepare = game => {
                var command = Product.Command(game,prefs,locale,false,false,hardware);
                return delegate {
                    bool snapshots = Product.Enabled("VICTORY_SAVE_HISTORY") && Product.Enabled("VICTORY_SAVE_SNAPSHOTS");
                    string error = "";
                    int status = Session.Run(prefs,Path.Combine(home,"snapshots"),build.patched_tree ?? "unknown",snapshots,delegate {
                        using (var child = Process.Start(command)) { error = child.StandardError.ReadToEnd(); child.WaitForExit(); return child.ExitCode; }
                    });
                    if (status != 0 && error.Trim().Length > 0) Console.Error.WriteLine(error.Trim());
                    return status;
                };
            },
        };
        return FirstRun.Run(options);
    }
}
}
