using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using System.Xml;
using System.Xml.Linq;

namespace Kelvaroq {
internal class Problem : Exception {
    internal Problem(string key) : base(key) {}
    internal Problem(string key, Exception inner) : base(key,inner) {}
}
/// A multi-step operation failed. Names the step so the operator is never left guessing.
/// Message is the localisation key of the underlying problem ("failed" for an unexpected one).
internal sealed class StepFailure : Problem {
    internal readonly string Step;
    internal StepFailure(string step, Exception inner) : base(inner is Problem ? inner.Message : "failed",inner) { Step = step; }
}
internal static class Files {
    internal static readonly StringComparer Names = StringComparer.OrdinalIgnoreCase;
    internal static JavaScriptSerializer Json { get { return new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }; } }
    internal static string Unique(string parent) { return Path.Combine(parent, ".kelvaroq-" + Guid.NewGuid().ToString("N")); }
    internal static void Publish(string temp, string path) {
        if (File.Exists(path)) File.Replace(temp, path, null);
        else File.Move(temp, path);
    }
    internal static string Full(string path) {
        if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) || path.StartsWith(@"\\?\") || path.StartsWith(@"\\.\")) throw new Problem("unsafePath");
        return Path.GetFullPath(path).TrimEnd('\\');
    }
    internal static bool Within(string path, string root) {
        return Names.Equals(path,root) || path.StartsWith(root + "\\",StringComparison.OrdinalIgnoreCase);
    }
    internal static void Separate(string a, string b) {
        a = Full(a); b = Full(b);
        if (Within(a,b) || Within(b,a)) throw new Problem("overlap");
    }
    internal static void NoLinks(string path) {
        for (var p = new DirectoryInfo(path); p != null; p = p.Parent) {
            FileAttributes flags;
            try { flags = File.GetAttributes(p.FullName); }
            catch (FileNotFoundException) { continue; }
            catch (DirectoryNotFoundException) { continue; }
            if ((flags & FileAttributes.ReparsePoint) != 0) throw new Problem("unsafePath");
        }
    }
    internal static void SafeRoot(string path) {
        var p = Full(path);
        if (!Names.Equals(p, path.TrimEnd('\\')) || p.Length <= Path.GetPathRoot(path).TrimEnd('\\').Length) throw new Problem("unsafePath");
        NoLinks(p);
        foreach (var folder in new[]{Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86}) {
            var reserved = Environment.GetFolderPath(folder);
            if (reserved.Length > 0 && Within(p,reserved)) throw new Problem("unsafePath");
        }
        foreach (var folder in new[]{Environment.SpecialFolder.UserProfile, Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.MyDocuments}) {
            var reserved = Environment.GetFolderPath(folder);
            if (reserved.Length > 0 && Within(reserved,p)) throw new Problem("unsafePath");
        }
    }
    internal static IEnumerable<string> Tree(string root) {
        NoLinks(root);
        FileAttributes rootFlags;
        try { rootFlags = File.GetAttributes(root); }
        catch (FileNotFoundException) { yield break; }
        catch (DirectoryNotFoundException) { yield break; }
        if ((rootFlags & FileAttributes.Directory) == 0) throw new Problem("unsafePath");
        var pending = new Stack<string>(); pending.Push(root);
        while (pending.Count > 0) {
            foreach (string path in Directory.EnumerateFileSystemEntries(pending.Pop())) {
                var flags = File.GetAttributes(path);
                if ((flags & FileAttributes.ReparsePoint) != 0) throw new Problem("unsafePath");
                if ((flags & FileAttributes.Directory) != 0) pending.Push(path);
                yield return path;
            }
        }
    }
    internal static void ClearShaders(string cache) {
        SafeRoot(cache);
        RemoveTree(Path.Combine(cache,"shaders"));
    }
    internal static long Size(string path) { return Tree(path).Where(File.Exists).Sum(p => new FileInfo(p).Length); }
    internal static string Hash(Stream input) {
        using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
    }
    internal static void RemoveTree(string path) {
        if (Directory.Exists(path)) {
            foreach (string unused in Tree(path)) {}
            Directory.Delete(path,true);
        }
    }
    internal static void ValidPart(string part) {
        string stem = part.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        if (part.Length == 0 || part.EndsWith(".") || part.EndsWith(" ") || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            new[]{"CON","PRN","AUX","NUL","CONIN$","CONOUT$"}.Contains(stem) ||
            System.Text.RegularExpressions.Regex.IsMatch(stem, @"^(COM|LPT)[0-9¹²³]$")) throw new Problem("unsafePath");
    }
}

/// Approach after XCL 50a9fde: find the manifest that declares a nested executable.
/// Approach after XCL 817328d: decode XML before interpreting executable entries.
internal sealed class Installation {
    internal string Root, Image;
    internal static Installation Select(string selection) {
        string path = Files.Full(selection);
        bool folder = Directory.Exists(path);
        if (!folder && (!File.Exists(path) || !Files.Names.Equals(Path.GetExtension(path),".exe"))) throw new Problem("selectExe");
        var parent = new DirectoryInfo(folder ? path : Path.GetDirectoryName(path));
        while (parent != null) {
            string config = Path.Combine(parent.FullName,"MicrosoftGame.Config");
            if (File.Exists(config)) {
                var options = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 4 * 1024 * 1024 };
                XDocument doc;
                try { using (var r = XmlReader.Create(config,options)) doc = XDocument.Load(r); }
                catch (XmlException) { throw new Problem("badManifest"); }
                var names = new HashSet<string>(Files.Names);
                foreach (var list in doc.Root.Elements().Where(e => e.Name.LocalName == "ExecutableList")) {
                    foreach (var entry in list.Elements().Where(e => e.Name.LocalName == "Executable")) {
                        var family = (string)entry.Attribute("TargetDeviceFamily");
                        if (family != null && !Files.Names.Equals(family,"Scarlett")) continue;
                        var name = (string)entry.Attribute("Name");
                        if (String.IsNullOrEmpty(name) || !Files.Names.Equals(Path.GetExtension(name),".exe")) throw new Problem("badManifest");
                        foreach (var part in name.Replace('/','\\').Split('\\')) if (part != ".") Files.ValidPart(part);
                        names.Add(Path.GetFullPath(Path.Combine(parent.FullName,name)));
                    }
                }
                if (folder && names.Count > 1) throw new Problem("ambiguous");
                string exe = folder ? names.FirstOrDefault() : path;
                if (exe == null || !names.Contains(exe) || !File.Exists(exe)) throw new Problem("wrongExe");
                Files.NoLinks(exe);
                return new Installation { Root = parent.FullName, Image = exe };
            }
            if (folder) break;
            parent = parent.Parent;
        }
        throw new Problem("noManifest");
    }
}

internal sealed class Preferences {
    public int schema_version { get; set; }
    public string language { get; set; }
    public string executable { get; set; }
    public string cache { get; set; }
    public string data { get; set; }
    public bool updates { get; set; }
    public bool monitor { get; set; }
    public bool preload { get; set; }
    public bool customProfile { get; set; }
    public Dictionary<string,int> profileValues { get; set; }
    public int recent { get; set; }
    public int days { get; set; }
    public Preferences() {
        schema_version = 2; updates = true; language = "system"; recent = 8; days = 14; preload = true;
        profileValues = new Dictionary<string,int>();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var legacy = Path.Combine(local,"victory");
        var root = Directory.Exists(legacy) || !Product.Enabled("VICTORY_LAUNCHER_STORAGE") ? legacy : Path.Combine(local,"Kelvaroq");
        cache = Environment.GetEnvironmentVariable("VICTORY_CACHE_DIR") ?? Path.Combine(root,"cache");
        data = Environment.GetEnvironmentVariable("VICTORY_DATA_DIR") ?? Path.Combine(root,"data");
    }
    internal string ActiveData { get { return Product.Enabled("VICTORY_LAUNCHER_STORAGE") ? data : new Preferences().data; } }
    internal string ActiveCache { get { return Product.Enabled("VICTORY_LAUNCHER_STORAGE") ? cache : new Preferences().cache; } }
    internal void Validate(string home) {
        if (schema_version != 2 || recent < 1 || recent > 100 || days < 0 || days > 365 ||
            (language != "system" && !Locale.Codes.Contains(language))) throw new Problem("badSettings");
        Files.SafeRoot(cache); Files.SafeRoot(data); Files.Separate(cache,data);
        foreach (var p in new[]{data,cache}) { Files.Separate(p,home); Files.Separate(p,AppDomain.CurrentDomain.BaseDirectory); }
    }
    internal static Preferences Load(string home) {
        string file = Path.Combine(home,"settings");
        if (!File.Exists(file)) { var fresh = new Preferences(); fresh.Validate(home); return fresh; }
        var raw = File.ReadAllText(file);
        var props = Files.Json.Deserialize<Dictionary<string,object>>(raw);
        if (!props.ContainsKey("schema_version")) throw new Problem("badSettings");
        var prefs = Files.Json.Deserialize<Preferences>(raw);
        if (prefs.schema_version == 1) { prefs.recent = 8; prefs.days = 14; prefs.schema_version = 2; prefs.Write(home); }
        prefs.Validate(home);
        return prefs;
    }
    internal void Write(string home) {
        Validate(home); Directory.CreateDirectory(home);
        string file = Path.Combine(home,"settings"), temp = Files.Unique(home);
        try {
            using (var stream = new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                byte[] bytes = Encoding.UTF8.GetBytes(Files.Json.Serialize(this));
                stream.Write(bytes,0,bytes.Length); stream.Flush(true);
            }
            Files.Publish(temp,file);
        } finally { File.Delete(temp); }
    }
}

internal static class Relocation {
    /// The steps of a move, in order. A failure in any of them leaves the source exactly as it was
    /// and the destination absent. "cleanup" follows them: by then the destination is verified
    /// and live, and only the retired copy of the source could not be removed.
    internal static readonly string[] Steps = {"verify-destination","write-marker","copy","verify-checksums","flip","verify-source"};
    static string Hex(byte[] hash) { return BitConverter.ToString(hash).Replace("-","").ToLowerInvariant(); }
    // Flushed before anything is copied, so a crash leaves evidence of what was in flight and how far it got.
    static void Mark(string marker, string source, string dest, string stage, string step) {
        var note = new Dictionary<string,string>{{"source",source},{"destination",dest},{"stage",stage},{"step",step}};
        using (var stream = new FileStream(marker,FileMode.Create,FileAccess.Write,FileShare.None)) {
            byte[] bytes = Encoding.UTF8.GetBytes(Files.Json.Serialize(note));
            stream.Write(bytes,0,bytes.Length); stream.Flush(true);
        }
    }
    /// verify the destination, write a marker, copy, verify checksums, flip, verify the source, then retire it.
    /// The source is never deleted before the destination is verified. A failure names its step (StepFailure).
    /// reach is a fault-injection point called as each step begins; production callers pass null.
    internal static void Move(string source, string dest, Action<int> progress, Action<bool> selectDestination, Action<string> reach = null) {
        string step = Steps[0];
        Action<string> at = delegate(string name) { step = name; if (reach != null) reach(name); };
        try { Transfer(source,dest,progress,selectDestination,at); }
        catch (StepFailure) { throw; }
        catch (Exception ex) { throw new StepFailure(step,ex); }
    }
    static void Transfer(string source, string dest, Action<int> progress, Action<bool> selectDestination, Action<string> at) {
        at("verify-destination");
        Files.SafeRoot(source); Files.SafeRoot(dest); Files.Separate(source,dest);
        if (File.Exists(dest) || Directory.Exists(dest)) throw new Problem("destinationExists");
        string stage = Files.Unique(Path.GetDirectoryName(dest)), marker = stage + ".move";
        string parked = Files.Unique(Path.GetDirectoryName(source));
        try {
            at("write-marker");
            Directory.CreateDirectory(Path.GetDirectoryName(dest));
            Mark(marker,source,dest,stage,"copy");
            Directory.CreateDirectory(stage);
            at("copy");
            var paths = Files.Tree(source).ToList();
            long total = paths.Where(File.Exists).Sum(p => new FileInfo(p).Length), copied = 0;
            int reported = -1;
            var buffer = new byte[131072];
            var hashes = new Dictionary<string,string>(Files.Names);
            var folders = new HashSet<string>(Files.Names);
            foreach (string path in paths) {
                string relative = path.Substring(source.TrimEnd('\\').Length + 1), target = Path.Combine(stage,relative);
                if (Directory.Exists(path)) { Directory.CreateDirectory(target); folders.Add(relative); continue; }
                using (var input = File.OpenRead(path))
                using (var output = new FileStream(target,FileMode.CreateNew))
                using (var sha = System.Security.Cryptography.SHA256.Create()) {
                    int n;
                    while ((n = input.Read(buffer,0,buffer.Length)) != 0) {
                        output.Write(buffer,0,n); sha.TransformBlock(buffer,0,n,null,0); copied += n;
                        int percent = (int)(copied * 100 / Math.Max(total,1));
                        if (reported != percent) { progress(percent); reported = percent; }
                    }
                    sha.TransformFinalBlock(buffer,0,0); output.Flush(true);
                    hashes[relative] = Hex(sha.Hash);
                }
            }
            // What was written is read back and compared with what was read from the source.
            at("verify-checksums");
            int verified = 0;
            foreach (string path in Files.Tree(stage)) {
                string relative = path.Substring(stage.Length + 1), want;
                if (Directory.Exists(path)) { if (!folders.Contains(relative)) throw new Problem("checksum"); continue; }
                using (var written = File.OpenRead(path))
                    if (!hashes.TryGetValue(relative,out want) || Files.Hash(written) != want) throw new Problem("checksum");
                verified++;
            }
            if (verified != hashes.Count) throw new Problem("checksum");
            at("flip");
            Mark(marker,source,dest,stage,"flip");
            Directory.Move(stage,dest);
            try { selectDestination(true); } catch { Directory.Move(dest,stage); throw; }
            // A writer can add or replace a file during a cross-volume copy.
            // Retire the source by name, then compare the exact tree being removed.
            try {
                at("verify-source");
                if (Directory.Exists(source)) {
                    Directory.Move(source,parked);
                    var copiedNames = new HashSet<string>(Files.Tree(dest).Select(p => p.Substring(dest.Length)),Files.Names);
                    foreach (var original in Files.Tree(parked)) {
                        string suffix = original.Substring(parked.Length);
                        if (!copiedNames.Remove(suffix)) throw new Problem("sourceChanged");
                        string target = dest + suffix;
                        if (Directory.Exists(original) != Directory.Exists(target)) throw new Problem("sourceChanged");
                        if (File.Exists(original)) using (var a = File.OpenRead(original)) using (var b = File.OpenRead(target))
                            if (Files.Hash(a) != Files.Hash(b)) throw new Problem("sourceChanged");
                    }
                    if (copiedNames.Count != 0) throw new Problem("sourceChanged");
                }
            } catch {
                if (Directory.Exists(parked)) Directory.Move(parked,source);
                selectDestination(false);
                Directory.Move(dest,stage); throw;
            }
        } finally { Files.RemoveTree(stage); if (File.Exists(marker)) File.Delete(marker); }
        at("cleanup");
        try { Files.RemoveTree(parked); }
        catch (IOException) { throw new Problem("sourceCleanup"); }
        catch (UnauthorizedAccessException) { throw new Problem("sourceCleanup"); }
        progress(100);
    }
}
}
