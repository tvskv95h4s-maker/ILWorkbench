using System.Reflection.PortableExecutable;
using System.Text;

namespace ILWorkbench.Helper;

/// <summary>
/// Diagnoses files that are not managed assemblies, so the app can show an error node instead of
/// failing with an exception. Everything here is defensive: any IO or parse error becomes a result.
/// </summary>
public static class FileProbe
{
    public sealed record Result(
        string Kind,
        string Reason,
        long Size,
        string Magic,
        string Machine,
        bool HasClrHeader,
        string? TargetFramework);

    public static Result Analyse(string path, Exception error)
    {
        var reason = error.Message;
        try
        {
            if (Directory.Exists(path))
                return new Result("directory", reason, 0, "-", "-", false, null);

            if (!File.Exists(path))
                return new Result("missing", reason, 0, "-", "-", false, null);

            var info = new FileInfo(path);
            var head = new byte[8];
            using (var stream = File.OpenRead(path))
            {
                var read = stream.Read(head, 0, head.Length);
                if (read < head.Length) Array.Resize(ref head, Math.Max(read, 0));
            }

            var magic = Convert.ToHexString(head).ToLowerInvariant();

            // Mach-O (thin and fat) and ELF: native binaries from other toolchains.
            if (head.Length >= 4)
            {
                var be = (uint)((head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3]);
                var le = (uint)(head[0] | (head[1] << 8) | (head[2] << 16) | (head[3] << 24));
                if (le is 0xFEEDFACE or 0xFEEDFACF || be is 0xCAFEBABE or 0xCAFEBABF)
                    return new Result("machO", reason, info.Length, magic, "-", false, null);
                if (head[0] == 0x7F && head[1] == (byte)'E' && head[2] == (byte)'L' && head[3] == (byte)'F')
                    return new Result("elf", reason, info.Length, magic, "-", false, null);
                if (head[0] == (byte)'P' && head[1] == (byte)'K')
                    return new Result("zip", reason, info.Length, magic, "-", false, null);
            }

            // PE but no CLI header -> native (C/C++/Delphi/...) Windows binary.
            if (head.Length >= 2 && head[0] == (byte)'M' && head[1] == (byte)'Z')
            {
                try
                {
                    using var stream = File.OpenRead(path);
                    using var reader = new PEReader(stream);
                    var headers = reader.PEHeaders;
                    var machine = headers.CoffHeader.Machine.ToString();
                    if (headers.CorHeader == null)
                        return new Result("native", reason, info.Length, magic, machine, false, null);
                    return new Result("badManagedImage", reason, info.Length, magic, machine, true, null);
                }
                catch (Exception ex)
                {
                    return new Result("badPE", reason + " / " + ex.Message, info.Length, magic, "-", false, null);
                }
            }

            // Anything printable in the first bytes is treated as text.
            if (head.Length > 0 && head.All(b => b == 9 || b == 10 || b == 13 || (b >= 32 && b < 127)))
                return new Result("text", reason, info.Length, magic, "-", false, null);

            return new Result("unknown", reason, info.Length, magic, "-", false, null);
        }
        catch (Exception ex)
        {
            return new Result("unknown", reason + " / " + ex.Message, 0, "-", "-", false, null);
        }
    }

    /// <summary>Root tree node shown when a file could not be opened.</summary>
    public static System.Text.Json.Nodes.JsonObject ErrorNode(string path, Result result) => new()
    {
        ["kind"] = "error",
        ["name"] = Path.GetFileName(path),
        ["detail"] = result.Kind,
        ["path"] = path,
        ["group"] = "fileerror",
        ["token"] = null,
        ["children"] = new System.Text.Json.Nodes.JsonArray()
    };
}
