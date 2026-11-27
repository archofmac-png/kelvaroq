using System;
using System.IO;

namespace Kelvaroq {
/// Size-capped rotation for append-only logs (crashes.log, session logs), so a long tail of
/// removals cannot fill the disk.
internal static class LogRotation {
    /// A log at or above this size is rotated. 8 MiB holds tens of thousands of one-line removal
    /// events, far more than the three-in-a-row stop rule in docs/RUNBOOK.md ever needs.
    internal const long MaxBytes = 8L * 1024 * 1024;
    /// Rotated generations kept as <log>.1 (newest) to <log>.N (oldest). Worst case disk use is
    /// (Keep + 1) * MaxBytes = 48 MiB per log.
    internal const int Keep = 5;

    internal static bool Rotate(string path) { return Rotate(path,MaxBytes,Keep,null); }

    /// Rotates path to path.1 when its length is at least maxBytes, shifting older generations up
    /// and dropping any beyond keep. Returns whether it rotated. Zero-byte and missing files never
    /// rotate. The file named by current (this session's log) is never rotated. A file a writer
    /// holds open cannot be moved; it is left whole and this returns false. Nothing is deleted
    /// until the live file has been moved aside successfully.
    internal static bool Rotate(string path, long maxBytes, int keep, string current) {
        if (maxBytes < 1) throw new ArgumentOutOfRangeException("maxBytes");
        if (keep < 1) throw new ArgumentOutOfRangeException("keep");
        if (current != null && Files.Names.Equals(Path.GetFullPath(current),Path.GetFullPath(path))) return false;
        var info = new FileInfo(path);
        if (!info.Exists || info.Length < maxBytes) return false;
        string aside = path + ".rotating-" + Guid.NewGuid().ToString("N");
        try { File.Move(path,aside); }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        // From here the live path is free; every failure below still leaves the data on disk under some name.
        for (int n = keep; File.Exists(path + "." + n) || File.Exists(path + "." + (n + 1)); n++) File.Delete(path + "." + n);
        for (int n = keep - 1; n >= 1; n--)
            if (File.Exists(path + "." + n)) File.Move(path + "." + n,path + "." + (n + 1));
        File.Move(aside,path + ".1");
        return true;
    }
}
}
