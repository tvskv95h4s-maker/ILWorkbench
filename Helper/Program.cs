using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using ILWorkbench.Helper;

namespace ILWorkbench.Helper;

internal static class Program
{
    private const string Version = "0.2.0";

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false
    };

    private static volatile AssemblySession? _session;
    private static readonly object OutputLock = new();

    private static int Main(string[] args)
    {
        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = false };
        Console.SetOut(stdout);
        try
        {
            if (args.Length == 0) return Serve(Console.In, Console.Out);
            if (args[0] == "--listen" && args.Length > 1) return Listen(args[1]);
            return RunCli(args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
        finally
        {
            stdout.Flush();
        }
    }

    // ---------- JSON-RPC over stdio: one JSON request per line, one JSON response per line ----------

    /// <summary>
    /// Serves the protocol on 127.0.0.1 over TCP. The macOS client uses this instead of piping
    /// stdio, because Foundation's Pipe transport proved unreliable for request/response traffic.
    /// The chosen port is published in <paramref name="handshakePath"/> once the listener is up.
    /// </summary>
    private static int Listen(string handshakePath)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        File.WriteAllText(handshakePath, $"{{\"port\":{port},\"pid\":{Environment.ProcessId}}}");

        using var client = listener.AcceptTcpClient();
        client.NoDelay = true;
        using var stream = client.GetStream();
        using var reader = new StreamReader(stream, new UTF8Encoding(false));
        using var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true };
        return Serve(reader, writer);
    }

    private static int Serve(TextReader input, TextWriter output)
    {
        // Requests run on a worker thread; the reader thread stays responsive so a "cancel" message
        // can abort a long decompilation instead of queueing behind it.
        using var queue = new BlockingCollection<JsonObject>();
        var worker = new Thread(() =>
        {
            foreach (var request in queue.GetConsumingEnumerable())
                Write(output, Handle(request));
        })
        { IsBackground = true, Name = "ilworkbench-worker" };
        worker.Start();

        string? line;
        while ((line = input.ReadLine()) != null)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;

            JsonObject request;
            try
            {
                request = JsonNode.Parse(line)!.AsObject();
            }
            catch (Exception ex)
            {
                Write(output, new JsonObject { ["id"] = 0, ["ok"] = false, ["error"] = "bad request: " + ex.Message });
                continue;
            }

            if (request["cmd"]?.GetValue<string>() == "cancel")
            {
                _session?.CancelCurrentWork();
                Write(output, new JsonObject
                {
                    ["id"] = request["id"]?.GetValue<long>() ?? 0,
                    ["ok"] = true,
                    ["data"] = new JsonObject { ["cancelled"] = true }
                });
                continue;
            }

            queue.Add(request);
        }

        queue.CompleteAdding();
        worker.Join();
        return 0;
    }

    private static void Write(TextWriter output, JsonObject response)
    {
        lock (OutputLock)
        {
            output.WriteLine(response.ToJsonString(JsonOpts));
            output.Flush();
        }
    }

    private static JsonObject Handle(JsonObject request)
    {
        var id = request["id"]?.GetValue<long>() ?? 0;
        try
        {
            var cmd = request["cmd"]?.GetValue<string>() ?? throw new InvalidOperationException("missing cmd");
            return new JsonObject { ["id"] = id, ["ok"] = true, ["data"] = Dispatch(cmd, request) };
        }
        catch (OperationCanceledException)
        {
            return new JsonObject { ["id"] = id, ["ok"] = false, ["error"] = "cancelled" };
        }
        catch (Exception ex)
        {
            return new JsonObject { ["id"] = id, ["ok"] = false, ["error"] = ex.Message };
        }
    }

    private static JsonNode? Dispatch(string cmd, JsonObject req) => cmd switch
    {
        "ping" => new JsonObject { ["pong"] = true, ["version"] = Version, ["runtime"] = Environment.Version.ToString() },
        "open" => Open(Str(req, "path")),
        "reload" => Reload(),
        "close" => Close(),
        "tree" => Session().BuildTree(),
        "children" => Session().GroupChildren(Str(req, "group")),
        "assembly" => Session().ReferencedChildren(Int(req, "index")),
        "metadata" => Session().MetadataReport(Str(req, "group"), OptionalInt(req, "index")),
        "decompile" => OptionalInt(req, "ref") is { } reference
            ? Session().DecompileReferenced(reference, Token(req))
            : Session().DecompileNode(Token(req)),
        "il" => OptionalInt(req, "ref") is { } ilReference
            ? Session().GetIlReferenced(ilReference, Token(req))
            : Session().GetIl(Token(req)),
        "setConstant" => Text(IlEditing.SetConstant(Session(), Token(req), Int(req, "offset"), Element(req, "value"))),
        "replaceInstruction" => Text(IlEditing.ReplaceInstruction(Session(), Token(req), Int(req, "offset"), Str(req, "opcode"), Element(req, "operand"))),
        "insertInstruction" => Text(IlEditing.InsertInstruction(Session(), Token(req), Int(req, "beforeOffset"), Str(req, "opcode"), Element(req, "operand"))),
        "removeInstruction" => Text(IlEditing.RemoveInstruction(Session(), Token(req), Int(req, "offset"))),
        "addField" => Structure(StructureEditing.AddField(Session(), Token(req, "typeToken"), Str(req, "name"), Str(req, "fieldType"), Bool(req, "isStatic"), Bool(req, "isPublic", true))),
        "addMethod" => Structure(StructureEditing.AddMethod(Session(), Token(req, "typeToken"), Str(req, "name"), Str(req, "returnType"),
            Strings(req, "parameters"), Bool(req, "isStatic"), Bool(req, "isPublic", true), Str(req, "bodyKind", "default"), OptionalString(req, "constant"))),
        "addType" => Structure(StructureEditing.AddType(Session(), Str(req, "namespace", string.Empty), Str(req, "name"), Str(req, "kind", "class"), OptionalString(req, "baseType"), Bool(req, "isPublic", true))),
        "removeMember" => Structure(StructureEditing.RemoveMember(Session(), Token(req))),
        "removeType" => Structure(StructureEditing.RemoveType(Session(), Token(req))),
        "save" => Save(OptionalString(req, "path")),
        _ => throw new InvalidOperationException("unknown cmd: " + cmd)
    };

    /// <summary>
    /// Opens an assembly. Files that are not managed assemblies (native DLLs, Mach-O, text, folders)
    /// do not throw: they come back as a failed open with a diagnosis and an error root node.
    /// </summary>
    private static JsonNode Open(string path)
    {
        _session?.Dispose();
        _session = null;
        _failure = null;

        var fullPath = System.IO.Path.GetFullPath(path);
        try
        {
            _session = new AssemblySession(fullPath);
            return new JsonObject
            {
                ["path"] = _session.SourcePath,
                ["failed"] = false,
                ["tree"] = _session.BuildTree()
            };
        }
        catch (Exception ex)
        {
            var probe = FileProbe.Analyse(fullPath, ex);
            _failure = new FailedOpen(fullPath, probe);
            return new JsonObject
            {
                ["path"] = fullPath,
                ["failed"] = true,
                ["tree"] = FileProbe.ErrorNode(fullPath, probe),
                ["failure"] = FailureJson(probe)
            };
        }
    }

    private sealed record FailedOpen(string Path, FileProbe.Result Probe);

    private static FailedOpen? _failure;

    private static JsonObject FailureJson(FileProbe.Result probe) => new()
    {
        ["kind"] = probe.Kind,
        ["reason"] = probe.Reason,
        ["size"] = probe.Size,
        ["magic"] = probe.Magic,
        ["machine"] = probe.Machine,
        ["hasClrHeader"] = probe.HasClrHeader
    };

    private static JsonNode Close()
    {
        _session?.Dispose();
        _session = null;
        _failure = null;
        return new JsonObject { ["closed"] = true };
    }

    private static JsonNode Reload()
    {
        if (_failure != null) return Open(_failure.Path);
        var session = Session();
        session.Reload();
        return new JsonObject { ["path"] = session.SourcePath, ["tree"] = session.BuildTree() };
    }

    private static JsonNode Save(string? path)
    {
        var session = Session();
        var saved = session.Save(path);
        return new JsonObject
        {
            ["path"] = saved,
            ["tree"] = session.BuildTree(),
            ["renumbered"] = session.LastSaveRenumbered
        };
    }

    private static AssemblySession Session()
    {
        if (_failure != null)
            throw new InvalidOperationException("file is not a managed assembly: " + _failure.Path);
        return _session ?? throw new InvalidOperationException("no assembly open");
    }

    private static JsonObject Text(string value) => new() { ["text"] = value };

    /// <summary>Structural edits return the refreshed tree, because adding/removing rows changes it.</summary>
    private static JsonObject Structure(string message)
    {
        var session = Session();
        return new JsonObject { ["text"] = message, ["tree"] = session.BuildTree() };
    }

    private static JsonNode? Prop(JsonObject req, string name) =>
        req.TryGetPropertyValue(name, out var node) ? node : null;

    private static string Str(JsonObject req, string name) =>
        Prop(req, name)?.GetValue<string>() ?? throw new InvalidOperationException($"missing {name}");

    private static string Str(JsonObject req, string name, string fallback) =>
        Prop(req, name)?.GetValue<string>() ?? fallback;

    private static string? OptionalString(JsonObject req, string name) =>
        Prop(req, name)?.GetValue<string>();

    private static int Int(JsonObject req, string name) =>
        Prop(req, name)?.GetValue<int>() ?? throw new InvalidOperationException($"missing {name}");

    private static int? OptionalInt(JsonObject req, string name) =>
        TryNumber(Prop(req, name), out var value) ? (int)value : null;

    /// <summary>Converts a protocol node to a JsonElement for the IL editing API.</summary>
    private static JsonElement? Element(JsonObject req, string name)
    {
        var node = Prop(req, name);
        return node == null ? null : JsonSerializer.SerializeToElement(node);
    }

    /// <summary>True when the node holds a JSON number (JsonNode has no GetValueKind on .NET 7).</summary>
    private static bool TryNumber(JsonNode? node, out long value)
    {
        value = 0;
        if (node is not JsonValue) return false;
        try
        {
            value = node.GetValue<long>();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool Bool(JsonObject req, string name, bool fallback = false) =>
        Prop(req, name)?.GetValue<bool>() ?? fallback;

    /// <summary>Reads a JSON array of strings, tolerating a null/missing value.</summary>
    private static List<string> Strings(JsonObject req, string name)
    {
        if (Prop(req, name) is not JsonArray array) return new List<string>();
        return array
            .Select(item => item?.GetValue<string>() ?? string.Empty)
            .Where(item => item.Length > 0)
            .ToList();
    }

    /// <summary>Accepts "0x06000001" or 100663297.</summary>
    private static uint Token(JsonObject req, string name = "token")
    {
        var node = Prop(req, name) ?? throw new InvalidOperationException($"missing {name}");
        return TryNumber(node, out var numeric) ? (uint)numeric : ParseToken(node.GetValue<string>());
    }

    // ---------- one-shot CLI mode: used by build scripts and smoke tests ----------

    private static int RunCli(string[] args)
    {
        switch (args[0])
        {
            case "--canceltest":
            {
                // Probe whether the ILSpy engine honours CSharpDecompiler.CancellationToken.
                using var session = new AssemblySession(args[1]);
                var token = ParseToken(args[2]);
                using var cts = new CancellationTokenSource();
                var started = DateTime.UtcNow;
                var cancelTask = Task.Run(async () =>
                {
                    await Task.Delay(500);
                    cts.Cancel();
                    Console.Error.WriteLine("cancelled after 500ms");
                });
                try
                {
                    var result = session.DecompileNodeWithToken(token, cts.Token);
                    var text = result["text"]!.GetValue<string>();
                    Console.WriteLine($"completed in {(DateTime.UtcNow - started).TotalSeconds:F2}s, {text.Length} chars (cancellation NOT honoured)");
                }
                catch (OperationCanceledException)
                {
                    Console.WriteLine($"aborted after {(DateTime.UtcNow - started).TotalSeconds:F2}s (cancellation honoured)");
                }
                return 0;
            }

            case "--listen":
                return Listen(args[1]);

            case "--ping":
                Console.WriteLine($"{{\"ok\":true,\"version\":\"{Version}\",\"runtime\":\"{Environment.Version}\"}}");
                return 0;

            case "--tree":
                using (var session = new AssemblySession(args[1]))
                    Console.WriteLine(session.BuildTree().ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                return 0;

            case "--decompile":
                using (var session = new AssemblySession(args[1]))
                    Console.WriteLine(session.DecompileNode(ParseToken(args[2]))["text"]);
                return 0;

            case "--il":
                using (var session = new AssemblySession(args[1]))
                    Console.WriteLine(session.GetIl(ParseToken(args[2]))["text"]);
                return 0;

            case "--structure-demo":
                RunStructureDemo(args[1], args.Length > 2 ? args[2] : null);
                return 0;

            case "--patch-demo":
                RunPatchDemo(args[1], args.Length > 2 ? args[2] : null);
                return 0;

            default:
                Console.Error.WriteLine($"unknown option: {args[0]}");
                return 2;
        }
    }

    /// <summary>End-to-end structural editing proof: add a field/method/type, remove members, then save.</summary>
    private static void RunStructureDemo(string path, string? outPath)
    {
        using var session = new AssemblySession(path);
        var before = TokenMap(session.BuildTree());

        var banner = FindNode(session.BuildTree(), "type", "Banner")
            ?? throw new InvalidOperationException("示例类型 SampleLib.Banner 不存在");
        var bannerToken = ParseToken(banner["token"]!.GetValue<string>());

        Console.WriteLine("1) " + StructureEditing.AddField(session, bannerToken, "Version", "System.Int32", isStatic: true, isPublic: true));
        Console.WriteLine("2) " + StructureEditing.AddMethod(session, bannerToken, "Sum", "System.Int32",
            new[] { "System.Int32", "System.Int32" }, isStatic: true, isPublic: true, bodyKind: "constant", constant: "42"));

        Console.WriteLine("3) " + StructureEditing.AddType(session, "SampleLib", "ToolAddedType", "class", null, isPublic: true));
        var addedType = FindNode(session.BuildTree(), "type", "ToolAddedType")
            ?? throw new InvalidOperationException("刚添加的类型没有出现在结构树里");
        var addedToken = ParseToken(addedType["token"]!.GetValue<string>());
        Console.WriteLine("4) " + StructureEditing.AddMethod(session, addedToken, "Ping", "System.String",
            Array.Empty<string>(), isStatic: true, isPublic: true, bodyKind: "constant", constant: "tool-added-type"));

        var render = FindNode(session.BuildTree(), "method", "Render")
            ?? throw new InvalidOperationException("示例方法 SampleLib.Banner.Render 不存在");
        Console.WriteLine("5) " + StructureEditing.RemoveMember(session, ParseToken(render["token"]!.GetValue<string>())));

        Console.WriteLine("6) " + StructureEditing.AddType(session, "SampleLib", "Throwaway", "class", null, isPublic: false));
        var throwaway = FindNode(session.BuildTree(), "type", "Throwaway")!.AsObject();
        Console.WriteLine("7) " + StructureEditing.RemoveType(session, ParseToken(throwaway["token"]!.GetValue<string>())));

        var saved = session.Save(outPath);
        Console.WriteLine("8) saved -> " + saved);

        var after = TokenMap(session.BuildTree());
        var drifted = before.Where(pair => !after.TryGetValue(pair.Key, out var name) || name != pair.Value).ToList();
        Console.WriteLine($"9) token 稳定性：原有成员 {before.Count} 个，保存后漂移 {drifted.Count} 个");
        foreach (var pair in drifted.Take(5))
            Console.WriteLine($"   {pair.Key} {pair.Value} -> {(after.TryGetValue(pair.Key, out var now) ? now : "<缺失>")}");

        Console.WriteLine("10) 保存后的 Banner 子树：");
        var bannerAfter = FindNode(session.BuildTree(), "type", "Banner")!.AsObject();
        foreach (var child in bannerAfter["children"]!.AsArray())
            Console.WriteLine($"    {child!["kind"]!.GetValue<string>(),-8} {child["name"]!.GetValue<string>(),-12} {child["detail"]?.GetValue<string>()}");
    }

    /// <summary>Maps metadata token -> "kind:name" so token drift can be detected after a write.</summary>
    private static Dictionary<string, string> TokenMap(JsonNode root)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        void Walk(JsonNode node)
        {
            var token = node["token"]?.GetValue<string>();
            if (token != null)
                map[token] = node["kind"]!.GetValue<string>() + ":" + node["name"]!.GetValue<string>();
            if (node["children"] is JsonArray children)
                foreach (var child in children)
                    if (child != null) Walk(child);
        }
        Walk(root);
        return map;
    }

    /// <summary>Depth-first search by node kind and exact name.</summary>
    private static JsonNode? FindNode(JsonNode node, string kind, string name)
    {
        if (node["kind"]?.GetValue<string>() == kind && node["name"]?.GetValue<string>() == name)
            return node;
        if (node["children"] is not JsonArray children) return null;
        foreach (var child in children)
        {
            if (child != null && FindNode(child, kind, name) is { } hit) return hit;
        }
        return null;
    }

    /// <summary>Depth-first search for a method node whose name contains <paramref name="namePart"/>.</summary>
    private static JsonNode? FindMethod(JsonNode node, string namePart)
    {
        if (node["kind"]?.GetValue<string>() == "method"
            && node["name"]?.GetValue<string>().Contains(namePart, StringComparison.Ordinal) == true)
            return node;
        if (node["children"] is not JsonArray children) return null;
        foreach (var child in children)
        {
            if (child != null && FindMethod(child, namePart) is { } hit) return hit;
        }
        return null;
    }

    private static uint ParseToken(string raw) =>
        raw.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? Convert.ToUInt32(raw[2..], 16) : uint.Parse(raw);

    /// <summary>End-to-end IL edit proof: rewrite a string constant, then save a patched copy.</summary>
    private static void RunPatchDemo(string path, string? outPath)
    {
        using var session = new AssemblySession(path);
        var target = FindMethod(session.BuildTree(), "Secret")
            ?? throw new InvalidOperationException("patch demo target method not found");

        var token = ParseToken(target["token"]!.GetValue<string>());
        var offset = session.GetIl(token)["instructions"]!.AsArray()[0]!["offset"]!.GetValue<int>();
        Console.WriteLine("edit -> " + IlEditing.SetConstant(session, token, offset, JsonDocument.Parse("\"patched-by-ilworkbench\"").RootElement));
        Console.WriteLine("saved -> " + session.Save(outPath));
    }
}
