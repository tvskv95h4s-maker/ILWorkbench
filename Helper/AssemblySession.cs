using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Reflection.Metadata.Ecma335;
using System.Text;
using System.Text.Json.Nodes;
using dnlib.DotNet;
using dnlib.DotNet.Emit;
using dnlib.DotNet.Writer;
using ICSharpCode.Decompiler;
using ICSharpCode.Decompiler.CSharp;
using ICSharpCode.Decompiler.Metadata;

namespace ILWorkbench.Helper;

/// <summary>
/// One opened assembly: dnlib is the source of truth for structure + IL (and for writing),
/// ICSharpCode.Decompiler (the ILSpy engine) is used only for C# text.
/// </summary>
public sealed class AssemblySession : IDisposable
{
    private readonly DecompilerSettings _settings = new() { ThrowOnAssemblyResolveErrors = false };
    private readonly Dictionary<uint, IMemberDef> _members = new();
    private readonly Dictionary<uint, TypeDef> _types = new();

    private ModuleDefMD _module;
    private CSharpDecompiler _decompiler;
    private string? _previewPath;
    private bool _rowRemoved;

    public string SourcePath { get; private set; }
    public bool Dirty { get; private set; }

    public AssemblySession(string path)
    {
        SourcePath = Path.GetFullPath(path);
        if (!File.Exists(SourcePath))
            throw new FileNotFoundException("assembly not found: " + SourcePath);
        _module = ModuleDefMD.Load(SourcePath);
        _decompiler = CreateDecompiler(SourcePath);
        Index();
    }

    private void Index()
    {
        _members.Clear();
        _types.Clear();
        foreach (var type in _module.GetTypes())
        {
            if (type.IsGlobalModuleType) continue;
            _types[type.MDToken.Raw] = type;
            foreach (var m in type.Methods) _members[m.MDToken.Raw] = m;
            foreach (var f in type.Fields) _members[f.MDToken.Raw] = f;
            foreach (var p in type.Properties) _members[p.MDToken.Raw] = p;
            foreach (var e in type.Events) _members[e.MDToken.Raw] = e;
        }
    }

    public void Reload()
    {
        _module.Dispose();
        _module = ModuleDefMD.Load(SourcePath);
        _decompiler = CreateDecompiler(SourcePath);
        DeletePreview();
        Dirty = false;
        Index();
    }

    /// <summary>
    /// The ILSpy engine only reads assemblies from disk, so it cannot see dnlib's in-memory edits.
    /// After an edit we mirror the modified module to a scratch file and point the decompiler at it,
    /// keeping the resolver anchored on the original location so sibling references still resolve.
    /// </summary>
    private void RefreshPreviewIfNeeded()
    {
        if (!Dirty) return;
        DeletePreview();
        var scratch = Path.Combine(Path.GetTempPath(), $"ilworkbench-preview-{Environment.ProcessId}.dll");
        // Always preserve RIDs in the scratch copy so tokens still address the same members.
        // Junk filler rows don't matter here: this file is never handed to the user.
        WriteModule(scratch, preserveRids: true);
        _previewPath = scratch;
        _decompiler = CreateDecompiler(scratch);
    }

    private CSharpDecompiler CreateDecompiler(string assemblyPath) =>
        new(assemblyPath, new UniversalAssemblyResolver(SourcePath, false, targetFramework: null), _settings);

    private void DeletePreview()
    {
        if (_previewPath == null) return;
        try { File.Delete(_previewPath); } catch { /* scratch file, best effort */ }
        _previewPath = null;
    }

    // ---------- tree ----------

    public JsonObject BuildTree()
    {
        var assemblyNode = new JsonObject
        {
            ["kind"] = "assembly",
            ["name"] = _module.Assembly?.Name?.String ?? System.IO.Path.GetFileName(SourcePath),
            ["detail"] = AssemblyDetail(),
            ["path"] = SourcePath,
            ["token"] = null,
            ["children"] = new JsonArray { ModuleNode() }
        };
        return assemblyNode;
    }

    /// <summary>dnSpy's second level: module -> PE / type refs / assembly refs / resources / namespaces.</summary>
    private JsonObject ModuleNode()
    {
        var children = new JsonArray
        {
            MetadataGroupNode("pe", null),
            // The list groups stay empty here; the client materialises them when expanded.
            MetadataGroupNode("typerefs", _module.GetTypeRefs().Count()),
            MetadataGroupNode("references", _module.GetAssemblyRefs().Count()),
            MetadataGroupNode("resources", _module.Resources.Count)
        };
        foreach (var node in TypeGroupNodes(_module, null)) children.Add(node);

        return new JsonObject
        {
            ["kind"] = "module",
            ["name"] = Path.GetFileName(SourcePath),
            ["detail"] = _module.Name?.String ?? "module",
            ["token"] = null,
            ["children"] = children
        };
    }

    /// <summary>
    /// Group nodes carry an identifier and a count instead of display text: the client renders the
    /// label in its own language.
    /// </summary>
    private static JsonObject MetadataGroupNode(string group, int? count) => new()
    {
        ["kind"] = "group",
        ["group"] = group,
        ["name"] = group,
        ["nameKey"] = "group." + group,
        ["count"] = count,
        ["token"] = null,
        ["children"] = new JsonArray()
    };

    /// <summary>
    /// Namespace level, dnSpy style: the global namespace first (labelled "{}"), then one node per
    /// namespace. When <paramref name="referenceIndex"/> is set the nodes belong to a referenced
    /// assembly and carry that index so later requests know which module a token belongs to.
    /// </summary>
    private static IEnumerable<JsonNode> TypeGroupNodes(ModuleDef module, int? referenceIndex)
    {
        var nodes = new List<JsonNode>();
        var topLevel = module.GetTypes().Where(t => !t.IsGlobalModuleType && !t.IsNested).ToList();

        var globalTypes = topLevel.Where(t => string.IsNullOrEmpty(t.Namespace?.String))
            .OrderBy(t => t.Name.String, StringComparer.OrdinalIgnoreCase)
            .Select(t => (JsonNode)TypeNode(t, referenceIndex))
            .ToList();
        nodes.Add(new JsonObject
        {
            ["kind"] = "namespace",
            ["name"] = "{}",
            ["nameKey"] = "namespace.global",
            ["typeCount"] = globalTypes.Count,
            ["token"] = null,
            ["ref"] = referenceIndex,
            ["children"] = new JsonArray(globalTypes.ToArray())
        });

        foreach (var group in topLevel.Where(t => !string.IsNullOrEmpty(t.Namespace?.String))
                     .GroupBy(t => t.Namespace!.String)
                     .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase))
        {
            var typeNodes = new JsonArray();
            foreach (var type in group.OrderBy(t => t.Name.String, StringComparer.OrdinalIgnoreCase))
                typeNodes.Add(TypeNode(type, referenceIndex));

            nodes.Add(new JsonObject
            {
                ["kind"] = "namespace",
                ["name"] = group.Key,
                ["typeCount"] = typeNodes.Count,
                ["token"] = null,
                ["ref"] = referenceIndex,
                ["children"] = typeNodes
            });
        }
        return nodes;
    }

    /// <summary>Lists type definitions of a group; children are materialised lazily by the metadata command.</summary>
    private JsonArray TypeRefNodes()
    {
        var nodes = new JsonArray();
        var index = 0;
        // dnSpy lists type references as "ShortName @tablesRid"; the full name and scope go to the tooltip.
        foreach (var typeRef in _module.GetTypeRefs()
                     .OrderBy(t => DisplayTypeRefName(t), StringComparer.OrdinalIgnoreCase))
        {
            nodes.Add(new JsonObject
            {
                ["kind"] = "typeref",
                ["group"] = "typerefs",
                ["index"] = index++,
                ["name"] = DisplayTypeRefName(typeRef),
                ["detail"] = typeRef.FullName,
                ["token"] = "0x" + typeRef.MDToken.Raw.ToString("X8"),
                ["tokenLabel"] = typeRef.MDToken.Raw.ToString("X8")
            });
        }
        return nodes;
    }

    /// <summary>Short name with generic arity rendered the way dnSpy shows it: Action`2 -> Action&lt;T1, T2&gt;.</summary>
    private static string DisplayTypeRefName(TypeRef typeRef)
    {
        var name = typeRef.Name?.String ?? "?";
        var tick = name.LastIndexOf('`');
        if (tick <= 0 || tick == name.Length - 1) return name;
        if (!int.TryParse(name[(tick + 1)..], out var arity) || arity <= 0) return name;
        var baseName = name[..tick];
        var parameters = arity == 1
            ? "T"
            : string.Join(", ", Enumerable.Range(1, arity).Select(i => "T" + i));
        return $"{baseName}<{parameters}>";
    }

    /// <summary>
    /// PE sub nodes in dnSpy's order: DOS header, file header, optional header, sections,
    /// Cor20 header, metadata signature, storage header and the metadata streams.
    /// Index positions are shared with <see cref="PeItemReport"/> so a click always matches a row.
    /// </summary>
    private JsonArray PeItemNodes()
    {
        var nodes = new JsonArray();
        var index = 0;
        foreach (var item in PeItems())
        {
            var node = new JsonObject
            {
                ["kind"] = "peitem",
                ["group"] = "pe",
                ["index"] = index++,
                ["name"] = item.NameKey,
                ["nameKey"] = item.NameKey,
                ["detail"] = item.Detail,
                ["token"] = null
            };
            if (item.NameIndex.HasValue)
            {
                node["nameIndex"] = item.NameIndex.Value;
                node["nameSuffix"] = item.NameSuffix;
            }
            nodes.Add(node);
        }
        return nodes;
    }

    private sealed record PeItem(string NameKey, string Detail, int? NameIndex = null, string? NameSuffix = null);

    private List<PeItem> PeItems()
    {
        var items = new List<PeItem>();
        var image = _module.Metadata.PEImage;
        var fileHeader = image.ImageNTHeaders.FileHeader;
        var optional = image.ImageNTHeaders.OptionalHeader;
        var streams = _module.Metadata.MetadataHeader.StreamHeaders;

        var magic = (ushort)optional.Magic;
        items.Add(new PeItem("peitem.dos", $"NTHeadersOffset 0x{image.ImageDosHeader.NTHeadersOffset:X8}"));
        items.Add(new PeItem("peitem.file", $"{fileHeader.Machine} · {fileHeader.NumberOfSections} sections"));
        items.Add(new PeItem(magic == 0x20b ? "peitem.optional64" : "peitem.optional32",
            $"EntryPoint 0x{(uint)optional.AddressOfEntryPoint:X8}"));

        var sectionIndex = 0;
        foreach (var section in image.ImageSectionHeaders)
            items.Add(new PeItem("peitem.section", $"VirtualSize {section.VirtualSize:N0}", sectionIndex++, section.DisplayName));

        items.Add(new PeItem("peitem.cor20", Cor20Summary()));
        items.Add(new PeItem("peitem.signature", $"0x{_module.Metadata.MetadataHeader.Signature:X8} · {_module.Metadata.MetadataHeader.VersionString}"));
        items.Add(new PeItem("peitem.storageHeader", $"{streams.Count} streams"));
        var streamIndex = 0;
        foreach (var stream in streams)
            items.Add(new PeItem("peitem.stream", $"{stream.StreamSize:N0} bytes @ 0x{stream.Offset:X8}", streamIndex++, stream.Name));
        return items;
    }

    private string Cor20Summary()
    {
        try
        {
            using var stream = File.OpenRead(SourcePath);
            using var reader = new PEReader(stream);
            var cor = reader.PEHeaders.CorHeader;
            return cor == null ? "(无 CLR 头)" : $"{cor.Flags} · 运行时 {cor.MajorRuntimeVersion}.{cor.MinorRuntimeVersion}";
        }
        catch (Exception ex)
        {
            return "读取失败: " + ex.Message;
        }
    }

    /// <summary>Detail report for one PE sub node.</summary>
    private string PeItemReport(int index)
    {
        var image = _module.Metadata.PEImage;
        var fileHeader = image.ImageNTHeaders.FileHeader;
        var optional = image.ImageNTHeaders.OptionalHeader;
        var metadata = _module.Metadata;
        var header = metadata.MetadataHeader;
        var sections = image.ImageSectionHeaders;
        var streams = header.StreamHeaders;

        var builder = new StringBuilder();
        var item = 0;

        void Section(string title)
        {
            builder.AppendLine("== " + title + " ==");
        }

        if (index == item++)
        {
            Section("DOS 头");
            builder.AppendLine($"NT 头偏移 : 0x{image.ImageDosHeader.NTHeadersOffset:X8}");
            return builder.ToString();
        }

        if (index == item++)
        {
            Section("文件头 (IMAGE_FILE_HEADER)");
            builder.AppendLine($"机器            : {fileHeader.Machine}");
            builder.AppendLine($"节数            : {fileHeader.NumberOfSections}");
            var stamp = fileHeader.TimeDateStamp;
            builder.AppendLine($"时间戳          : 0x{stamp:X8} ({DateTimeOffset.FromUnixTimeSeconds(stamp).ToLocalTime():yyyy-MM-dd HH:mm:ss})");
            builder.AppendLine($"符号表指针      : 0x{fileHeader.PointerToSymbolTable:X8}");
            builder.AppendLine($"符号数          : {fileHeader.NumberOfSymbols}");
            builder.AppendLine($"可选头大小      : {fileHeader.SizeOfOptionalHeader}");
            builder.AppendLine($"特性            : {fileHeader.Characteristics}");
            return builder.ToString();
        }

        if (index == item++)
        {
            var magic = (ushort)optional.Magic;
            Section($"可选头 ({(magic == 0x20b ? "PE32+" : "PE32")})");
            builder.AppendLine($"魔术值            : 0x{magic:X4}");
            builder.AppendLine($"链接器版本        : {optional.MajorLinkerVersion}.{optional.MinorLinkerVersion}");
            builder.AppendLine($"代码大小          : {optional.SizeOfCode:N0}");
            builder.AppendLine($"已初始化数据大小  : {optional.SizeOfInitializedData:N0}");
            builder.AppendLine($"未初始化数据大小  : {optional.SizeOfUninitializedData:N0}");
            builder.AppendLine($"入口点            : 0x{(uint)optional.AddressOfEntryPoint:X8}");
            builder.AppendLine($"代码基址          : 0x{(uint)optional.BaseOfCode:X8}");
            builder.AppendLine($"映像基址          : 0x{optional.ImageBase:X}");
            builder.AppendLine($"节对齐            : 0x{optional.SectionAlignment:X}");
            builder.AppendLine($"文件对齐          : 0x{optional.FileAlignment:X}");
            builder.AppendLine($"操作系统版本      : {optional.MajorOperatingSystemVersion}.{optional.MinorOperatingSystemVersion}");
            builder.AppendLine($"子系统版本        : {optional.MajorSubsystemVersion}.{optional.MinorSubsystemVersion}");
            builder.AppendLine($"映像大小          : {optional.SizeOfImage:N0}");
            builder.AppendLine($"头大小            : {optional.SizeOfHeaders:N0}");
            builder.AppendLine($"校验和            : 0x{optional.CheckSum:X8}");
            return builder.ToString();
        }

        foreach (var section in sections)
        {
            if (index == item++)
            {
                Section("节: " + section.DisplayName);
                builder.AppendLine($"虚拟大小        : {section.VirtualSize:N0}");
                builder.AppendLine($"虚拟地址        : 0x{(uint)section.VirtualAddress:X8}");
                builder.AppendLine($"原始数据大小    : {section.SizeOfRawData:N0}");
                builder.AppendLine($"原始数据指针    : 0x{section.PointerToRawData:X8}");
                builder.AppendLine($"重定位指针      : 0x{section.PointerToRelocations:X8}");
                builder.AppendLine($"重定位数        : {section.NumberOfRelocations}");
                builder.AppendLine($"行号指针        : 0x{section.PointerToLinenumbers:X8}");
                builder.AppendLine($"行号数          : {section.NumberOfLinenumbers}");
                builder.AppendLine($"特性            : 0x{section.Characteristics:X8}");
                return builder.ToString();
            }
        }

        if (index == item++)
            return PeReport();

        if (index == item++)
        {
            Section("存储签名 (STORAGESIGNATURE)");
            builder.AppendLine($"签名        : 0x{header.Signature:X8}");
            builder.AppendLine($"主版本      : {header.MajorVersion}");
            builder.AppendLine($"次版本      : {header.MinorVersion}");
            builder.AppendLine($"保留        : 0x{header.Reserved1:X8}");
            builder.AppendLine($"版本字符串  : {header.VersionString}");
            builder.AppendLine($"长度        : {header.StringLength}");
            return builder.ToString();
        }

        if (index == item++)
        {
            Section("存储标题 (STORAGEHEADER)");
            builder.AppendLine($"标志        : {header.Flags}");
            builder.AppendLine($"保留        : 0x{header.Reserved2:X8}");
            builder.AppendLine($"流数量      : {header.Streams}");
            builder.AppendLine($"位置        : 0x{(uint)header.StorageHeaderOffset:X8}");
            return builder.ToString();
        }

        foreach (var stream in streams)
        {
            if (index == item++)
            {
                Section("存储流: " + stream.Name);
                builder.AppendLine($"名称        : {stream.Name}");
                builder.AppendLine($"偏移        : 0x{stream.Offset:X8}");
                builder.AppendLine($"大小        : {stream.StreamSize:N0} 字节");
                if (string.Equals(stream.Name, "#~", StringComparison.Ordinal) || string.Equals(stream.Name, "#-", StringComparison.Ordinal))
                {
                    builder.AppendLine();
                    builder.AppendLine("== 表行数 ==");
                    AppendTableRowCounts(builder);
                }
                else
                {
                    var heap = metadata.AllStreams.FirstOrDefault(x => x.Name == stream.Name);
                    if (heap != null) builder.AppendLine($"堆长度      : {heap.StreamLength:N0} 字节");
                }
                return builder.ToString();
            }
        }

        return PeReport();
    }

    /// <summary>
    /// The document dnSpy shows when the assembly or module node is selected: a comment header plus
    /// the decompiled module/assembly attributes.
    /// </summary>
    public JsonObject AssemblyInfoReport()
    {
        var builder = new StringBuilder();
        var assembly = _module.Assembly;
        builder.AppendLine("// " + SourcePath);
        if (assembly != null)
        {
            var identity = new StringBuilder(assembly.Name?.String ?? "?");
            identity.Append(", Version=").Append(assembly.Version);
            identity.Append(", Culture=").Append(string.IsNullOrEmpty(assembly.Culture?.String) ? "neutral" : assembly.Culture!.String);
            var key = assembly.PublicKey?.Data;
            identity.Append(", PublicKeyToken=").Append(key is { Length: > 0 } ? Convert.ToHexString(key).ToLowerInvariant() : "null");
            builder.AppendLine("// " + identity);
        }
        builder.AppendLine("// 全局类型: " + (_module.GlobalType?.Name?.String ?? "<Module>"));
        builder.AppendLine("// 架构: " + _module.Metadata.PEImage.ImageNTHeaders.FileHeader.Machine);
        var framework = TargetFramework(assembly ?? (IHasCustomAttribute)_module);
        if (framework != null) builder.AppendLine("// 运行库: " + framework);
        var stamp = _module.Metadata.PEImage.ImageNTHeaders.FileHeader.TimeDateStamp;
        builder.AppendLine($"// 时间戳: {stamp:X8} ({DateTimeOffset.FromUnixTimeSeconds(stamp).ToLocalTime():yyyy/MM/dd HH:mm:ss})");
        builder.AppendLine();

        try
        {
            builder.Append(_decompiler.DecompileModuleAndAssemblyAttributesToString());
        }
        catch (Exception ex)
        {
            builder.AppendLine("// 程序集属性反编译失败: " + ex.Message);
        }

        return new JsonObject { ["text"] = builder.ToString(), ["language"] = "C#" };
    }

    /// <summary>Lists type definitions of a group; children are materialised lazily by the metadata command.</summary>

    private JsonArray AssemblyRefNodes()
    {
        var nodes = new JsonArray();
        var index = 0;
        foreach (var reference in _module.GetAssemblyRefs().OrderBy(r => r.Name?.String, StringComparer.OrdinalIgnoreCase))
        {
            var resolvedPath = ResolveReference(reference);
            nodes.Add(new JsonObject
            {
                ["kind"] = "assemblyref",
                ["group"] = "references",
                ["index"] = index++,
                ["name"] = reference.Name?.String ?? "?",
                ["detail"] = AssemblyRefDetail(reference) + (resolvedPath != null ? " · 已解析" : " · 未找到文件"),
                ["path"] = resolvedPath,
                ["expandable"] = resolvedPath != null,
                ["token"] = null
            });
        }
        return nodes;
    }

    private static string AssemblyRefDetail(AssemblyRef reference)
    {
        var parts = new List<string>();
        if (reference.Version != null) parts.Add(reference.Version.ToString());
        if (!string.IsNullOrEmpty(reference.Culture?.String)) parts.Add(reference.Culture!.String);
        var token = reference.PublicKeyOrToken?.Data;
        if (token is { Length: > 0 })
            parts.Add(Convert.ToHexString(token).ToLowerInvariant());
        return string.Join(" · ", parts);
    }

    private JsonArray ResourceNodes()
    {
        var nodes = new JsonArray();
        var index = 0;
        foreach (var resource in _module.Resources.OrderBy(r => r.Name?.String, StringComparer.OrdinalIgnoreCase))
        {
            nodes.Add(new JsonObject
            {
                ["kind"] = "resource",
                ["group"] = "resources",
                ["index"] = index++,
                ["name"] = resource.Name?.String ?? "?",
                ["detail"] = ResourceDetail(resource),
                ["token"] = null
            });
        }
        return nodes;
    }

    private static string ResourceDetail(dnlib.DotNet.Resource resource)
    {
        var visibility = resource.Attributes.HasFlag(ManifestResourceAttributes.Public) ? "public" : "private";
        return resource switch
        {
            EmbeddedResource embedded => $"{embedded.CreateReader().Length} 字节 · {visibility}",
            AssemblyLinkedResource linked => $"assembly 链接 · {linked.Assembly?.Name?.String} · {visibility}",
            LinkedResource file => $"文件链接 · {file.File?.Name?.String} · {visibility}",
            _ => visibility
        };
    }

    private string PeSummary()
    {
        try
        {
            using var stream = File.OpenRead(SourcePath);
            using var reader = new PEReader(stream);
            var headers = reader.PEHeaders;
            var machine = headers.CoffHeader.Machine.ToString();
            var sections = headers.SectionHeaders.Length;
            var corFlags = headers.CorHeader?.Flags.ToString() ?? "no CLR header";
            return $"{machine} · {sections} 节 · {corFlags}";
        }
        catch (Exception ex)
        {
            return "PE 读取失败: " + ex.Message;
        }
    }

    /// <summary>
    /// Children of a metadata group. Only the types root is sent with the tree; the list groups
    /// (1300+ type references in a WinForms assembly) are materialised when the user expands them.
    /// </summary>
    public JsonObject GroupChildren(string group)
    {
        var children = group switch
        {
            "pe" => PeItemNodes(),
            "typerefs" => TypeRefNodes(),
            "references" => AssemblyRefNodes(),
            "resources" => ResourceNodes(),
            "types" => new JsonArray(TypeGroupNodes(_module, null).ToArray()),
            _ => new JsonArray()
        };
        return new JsonObject { ["group"] = group, ["children"] = children };
    }

    // ---------- referenced assemblies ----------

    private readonly Dictionary<int, ReferencedModule> _referenced = new();

    private sealed class ReferencedModule
    {
        public string Path { get; init; } = string.Empty;
        public ModuleDefMD Module { get; init; } = null!;
        public CSharpDecompiler Decompiler { get; init; } = null!;
        public Dictionary<uint, MethodDef> Methods { get; init; } = new();
    }

    /// <summary>
    /// Looks for a referenced assembly next to the file being inspected (and in the usual
    /// "dllresolve" / "DLLAPP" sub folders). .NET Framework assemblies from the GAC are not
    /// available on macOS, so unresolved references stay as leaves.
    /// </summary>
    private string? ResolveReference(AssemblyRef reference)
    {
        var name = reference.Name?.String;
        if (string.IsNullOrEmpty(name)) return null;

        if (_referenceSearchCache.TryGetValue(name, out var cached)) return cached;

        var baseDirectory = Path.GetDirectoryName(SourcePath) ?? ".";
        var found = SearchDirectory(baseDirectory, name, depth: 3);
        if (found == null)
        {
            // Also look in the standard .NET locations that exist on macOS.
            foreach (var root in new[] { "/usr/local/share/dotnet/shared", "/usr/local/share/dotnet/packs" })
            {
                if (!Directory.Exists(root)) continue;
                found = SearchDirectory(root, name, depth: 3);
                if (found != null) break;
            }
        }

        _referenceSearchCache[name] = found;
        return found;
    }

    private readonly Dictionary<string, string?> _referenceSearchCache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Breadth-first search for &lt;name&gt;.dll, so dependencies that live in a "dllresolve" style
    /// sub folder are found the way dnSpy finds them next to the assembly.
    /// </summary>
    private static string? SearchDirectory(string root, string name, int depth)
    {
        var wanted = new[] { name + ".dll", name + ".exe" };
        var queue = new Queue<(string Directory, int Depth)>();
        queue.Enqueue((root, 0));
        var visited = 0;

        while (queue.Count > 0)
        {
            var (directory, currentDepth) = queue.Dequeue();
            if (++visited > 400) break;   // keep the walk bounded

            foreach (var fileName in wanted)
            {
                var candidate = Path.Combine(directory, fileName);
                if (File.Exists(candidate)) return candidate;
            }

            if (currentDepth >= depth) continue;
            try
            {
                foreach (var child in Directory.EnumerateDirectories(directory))
                {
                    var folder = Path.GetFileName(child);
                    if (folder.StartsWith(".", StringComparison.Ordinal)) continue;
                    queue.Enqueue((child, currentDepth + 1));
                }
            }
            catch (Exception)
            {
                // unreadable folder: skip
            }
        }
        return null;
    }

    private ReferencedModule LoadReference(int index)
    {
        if (_referenced.TryGetValue(index, out var cached)) return cached;

        var references = _module.GetAssemblyRefs()
            .OrderBy(r => r.Name?.String, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (index < 0 || index >= references.Count)
            throw new InvalidOperationException("程序集引用序号越界");

        var reference = references[index];
        var path = ResolveReference(reference)
            ?? throw new InvalidOperationException($"找不到 {reference.Name?.String}.dll（已查找程序集同级目录、dllresolve、DLLAPP、lib）");

        var module = ModuleDefMD.Load(path);
        var methods = new Dictionary<uint, MethodDef>();
        foreach (var type in module.GetTypes())
            foreach (var method in type.Methods)
                methods[method.MDToken.Raw] = method;

        var loaded = new ReferencedModule
        {
            Path = path,
            Module = module,
            Decompiler = CreateDecompiler(path),
            Methods = methods
        };
        _referenced[index] = loaded;
        return loaded;
    }

    /// <summary>Namespaces of a referenced assembly, fetched when the user expands that node.</summary>
    public JsonObject ReferencedChildren(int index)
    {
        var loaded = LoadReference(index);
        var children = new JsonArray(TypeGroupNodes(loaded.Module, index).ToArray());
        return new JsonObject
        {
            ["name"] = loaded.Module.Assembly?.Name?.String ?? Path.GetFileName(loaded.Path),
            ["path"] = loaded.Path,
            ["children"] = children
        };
    }

    public JsonObject DecompileReferenced(int index, uint token)
    {
        var loaded = LoadReference(index);
        var handle = MetadataTokens.EntityHandle(unchecked((int)token));
        try
        {
            return new JsonObject
            {
                ["token"] = Token(token),
                ["language"] = "C#",
                ["text"] = loaded.Decompiler.DecompileAsString(handle),
                ["note"] = "来自引用程序集 " + Path.GetFileName(loaded.Path) + "（只读，不支持编辑）"
            };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return new JsonObject { ["token"] = Token(token), ["language"] = "C#", ["text"] = "// 反编译失败: " + ex.Message };
        }
    }

    public JsonObject GetIlReferenced(int index, uint token)
    {
        var loaded = LoadReference(index);
        if (!loaded.Methods.TryGetValue(token, out var method))
            throw new InvalidOperationException($"引用程序集里没有 token {Token(token)} 对应的方法");
        return IlPayload(method, "来自引用程序集 " + Path.GetFileName(loaded.Path) + "（只读，不支持编辑）");
    }

    // ---------- cancellation ----------

    // Written by the worker thread, read by the request reader thread: volatile for visibility.
    private volatile CancellationTokenSource? _currentWork;

    /// <summary>Cancels whatever the worker thread is decompiling (called from the reader thread).</summary>
    public void CancelCurrentWork()
    {
        var work = _currentWork;
        try { work?.Cancel(); }
        catch (ObjectDisposedException) { /* finished in the meantime */ }
    }

    private CancellationToken BeginWork()
    {
        _currentWork?.Dispose();
        _currentWork = new CancellationTokenSource();
        return _currentWork.Token;
    }

    /// <summary>Text reports for the metadata groups (PE headers, tables, references, resources).</summary>
    public JsonObject MetadataReport(string group, int? index)
    {
        var text = group switch
        {
            "pe" => index is { } peIndex ? PeItemReport(peIndex) : PeReport(),
            "assemblyinfo" => AssemblyInfoReport()["text"]!.GetValue<string>(),
            "typerefs" => TypeRefReport(index),
            "references" => AssemblyRefReport(index),
            "resources" => ResourceReport(index),
            "types" => TypesReport(),
            _ => throw new InvalidOperationException("unknown metadata group: " + group)
        };
        return new JsonObject { ["text"] = text, ["language"] = "text" };
    }

    /// <summary>Table row counts, read through System.Reflection.Metadata (dnlib's heap API is awkward).</summary>
    private void AppendTableRowCounts(StringBuilder builder)
    {
        using var stream = File.OpenRead(SourcePath);
        using var reader = new PEReader(stream);
        var metadata = reader.GetMetadataReader();
        foreach (var table in InterestingTables)
        {
            var rows = metadata.GetTableRowCount(table);
            if (rows > 0) builder.AppendLine($"{table,-24}: {rows:N0}");
        }
    }

    private string PeReport()
    {
        var builder = new StringBuilder();
        var info = new FileInfo(SourcePath);
        builder.AppendLine($"文件      : {SourcePath}");
        builder.AppendLine($"大小      : {info.Length:N0} 字节");
        builder.AppendLine($"修改时间  : {info.LastWriteTime:yyyy-MM-dd HH:mm:ss}");

        using var stream = File.OpenRead(SourcePath);
        using var reader = new PEReader(stream);
        var headers = reader.PEHeaders;
        var metadata = reader.GetMetadataReader();

        builder.AppendLine();
        builder.AppendLine("== COFF 头 ==");
        builder.AppendLine($"机器          : {headers.CoffHeader.Machine}");
        builder.AppendLine($"节数          : {headers.SectionHeaders.Length}");
        var stamp = headers.CoffHeader.TimeDateStamp;
        var when = DateTimeOffset.FromUnixTimeSeconds(stamp).ToLocalTime();
        builder.AppendLine($"时间戳        : 0x{stamp:X8} ({when:yyyy-MM-dd HH:mm:ss})");
        builder.AppendLine($"特性          : {headers.CoffHeader.Characteristics}");

        if (headers.PEHeader is { } pe)
        {
            builder.AppendLine();
            builder.AppendLine("== 可选头 ==");
            builder.AppendLine($"格式          : {pe.Magic}");
            builder.AppendLine($"链接器版本    : {pe.MajorLinkerVersion}.{pe.MinorLinkerVersion}");
            builder.AppendLine($"入口点        : 0x{pe.AddressOfEntryPoint:X8}");
            builder.AppendLine($"映像基址      : 0x{pe.ImageBase:X8}");
            builder.AppendLine($"映像大小      : {pe.SizeOfImage:N0} 字节");
            builder.AppendLine($"子系统        : {pe.Subsystem} {pe.MajorSubsystemVersion}.{pe.MinorSubsystemVersion}");
        }

        if (headers.CorHeader is { } cor)
        {
            builder.AppendLine();
            builder.AppendLine("== CLR 头 ==");
            builder.AppendLine($"标志          : {cor.Flags}");
            builder.AppendLine($"入口点        : {(cor.EntryPointTokenOrRelativeVirtualAddress == 0 ? "(无)" : "0x" + cor.EntryPointTokenOrRelativeVirtualAddress.ToString("X8"))}");
            builder.AppendLine($"运行时版本    : {cor.MajorRuntimeVersion}.{cor.MinorRuntimeVersion}");
            builder.AppendLine($"元数据大小    : {cor.MetadataDirectory.Size:N0} 字节");
        }

        builder.AppendLine();
        builder.AppendLine("== 元数据 ==");
        builder.AppendLine($"版本字符串    : {metadata.MetadataVersion}");

        builder.AppendLine();
        builder.AppendLine("== 表行数 ==");
        foreach (var table in InterestingTables)
        {
            var rows = metadata.GetTableRowCount(table);
            if (rows > 0) builder.AppendLine($"{table,-24}: {rows:N0}");
        }

        builder.AppendLine();
        builder.AppendLine("== 节 ==");
        foreach (var section in headers.SectionHeaders)
            builder.AppendLine($"{section.Name,-10} 虚拟地址 0x{section.VirtualAddress:X8}  虚拟大小 {section.VirtualSize:N0}  原始大小 {section.SizeOfRawData:N0}");

        return builder.ToString();
    }

    private static readonly TableIndex[] InterestingTables =
    {
        TableIndex.Module, TableIndex.TypeRef, TableIndex.TypeDef, TableIndex.Field, TableIndex.MethodDef,
        TableIndex.Param, TableIndex.InterfaceImpl, TableIndex.MemberRef, TableIndex.Constant,
        TableIndex.CustomAttribute, TableIndex.FieldMarshal, TableIndex.DeclSecurity, TableIndex.ClassLayout,
        TableIndex.FieldLayout, TableIndex.StandAloneSig, TableIndex.EventMap, TableIndex.Event,
        TableIndex.PropertyMap, TableIndex.Property, TableIndex.MethodSemantics, TableIndex.MethodImpl,
        TableIndex.ModuleRef, TableIndex.TypeSpec, TableIndex.ImplMap, TableIndex.FieldRva,
        TableIndex.Assembly, TableIndex.AssemblyRef, TableIndex.File, TableIndex.ExportedType,
        TableIndex.ManifestResource, TableIndex.NestedClass, TableIndex.GenericParam,
        TableIndex.MethodSpec, TableIndex.GenericParamConstraint
    };

    private string TypeRefReport(int? index)
    {
        var references = _module.GetTypeRefs().OrderBy(t => t.FullName, StringComparer.OrdinalIgnoreCase).ToList();
        if (index is { } i && i >= 0 && i < references.Count)
        {
            var typeRef = references[i];
            var builder = new StringBuilder();
            builder.AppendLine($"类型引用      : {typeRef.FullName}");
            builder.AppendLine($"解析范围      : {typeRef.ResolutionScope?.Name?.String ?? "(无)"}");
            builder.AppendLine($"解析范围类型  : {typeRef.ResolutionScope?.GetType().Name ?? "(无)"}");
            builder.AppendLine($"metadata token: 0x{typeRef.MDToken.Raw:X8}");
            return builder.ToString();
        }

        var list = new StringBuilder();
        list.AppendLine($"共 {references.Count} 个类型引用");
        list.AppendLine();
        foreach (var typeRef in references)
            list.AppendLine($"{typeRef.ResolutionScope?.Name?.String,-28} {typeRef.FullName}");
        return list.ToString();
    }

    private string AssemblyRefReport(int? index)
    {
        var references = _module.GetAssemblyRefs().OrderBy(r => r.Name?.String, StringComparer.OrdinalIgnoreCase).ToList();
        if (index is { } i && i >= 0 && i < references.Count)
        {
            var reference = references[i];
            var builder = new StringBuilder();
            builder.AppendLine($"程序集        : {reference.Name?.String}");
            builder.AppendLine($"版本          : {reference.Version}");
            builder.AppendLine($"区域          : {(string.IsNullOrEmpty(reference.Culture?.String) ? "neutral" : reference.Culture!.String)}");
            builder.AppendLine($"公钥标记      : {(reference.PublicKeyOrToken?.Data is { Length: > 0 } token ? Convert.ToHexString(token).ToLowerInvariant() : "(无)")}");
            builder.AppendLine($"标志          : {reference.Attributes}");
            builder.AppendLine($"metadata token: 0x{reference.MDToken.Raw:X8}");
            return builder.ToString();
        }

        var list = new StringBuilder();
        list.AppendLine($"共 {references.Count} 个程序集引用");
        list.AppendLine();
        foreach (var reference in references)
            list.AppendLine($"{reference.Name?.String,-45} {AssemblyRefDetail(reference)}");
        return list.ToString();
    }


    private string ResourceReport(int? index)
    {
        var resources = _module.Resources.OrderBy(r => r.Name?.String, StringComparer.OrdinalIgnoreCase).ToList();
        if (index is { } i && i >= 0 && i < resources.Count)
        {
            var resource = resources[i];
            var builder = new StringBuilder();
            builder.AppendLine($"名称          : {resource.Name?.String}");
            builder.AppendLine($"类型          : {resource.GetType().Name}");
            builder.AppendLine($"可见性        : {(resource.Attributes.HasFlag(ManifestResourceAttributes.Public) ? "public" : "private")}");
            builder.AppendLine($"metadata token: 0x{resource.MDToken.Raw:X8}");
            if (resource is EmbeddedResource embedded)
            {
                var reader = embedded.CreateReader();
                builder.AppendLine($"大小          : {reader.Length:N0} 字节");
                var head = reader.ReadBytes((int)Math.Min(32, reader.Length));
                builder.AppendLine($"前 32 字节    : {Convert.ToHexString(head).ToLowerInvariant()}");
            }
            return builder.ToString();
        }

        var report = new StringBuilder();
        report.AppendLine($"共 {resources.Count} 个资源");
        report.AppendLine();
        foreach (var resource in resources)
            report.AppendLine($"{resource.Name?.String,-60} {ResourceDetail(resource)}");
        return report.ToString();
    }

    private string TypesReport()
    {
        var types = _module.GetTypes().Where(t => !t.IsGlobalModuleType).ToList();
        var builder = new StringBuilder();
        builder.AppendLine($"顶层类型 : {types.Count(t => !t.IsNested)}");
        builder.AppendLine($"嵌套类型 : {types.Count(t => t.IsNested)}");
        builder.AppendLine($"字段     : {types.Sum(t => t.Fields.Count)}");
        builder.AppendLine($"方法     : {types.Sum(t => t.Methods.Count)}");
        builder.AppendLine($"属性     : {types.Sum(t => t.Properties.Count)}");
        builder.AppendLine($"事件     : {types.Sum(t => t.Events.Count)}");
        return builder.ToString();
    }

    private string AssemblyDetail()
    {
        var asm = _module.Assembly;
        if (asm == null) return "module (no assembly manifest)";
        var parts = new List<string>();
        if (asm.Version != null) parts.Add("v" + asm.Version);
        var tfm = TargetFramework(asm) ?? TargetFramework(_module);
        if (tfm != null) parts.Add(tfm);
        return string.Join(" · ", parts);
    }

    /// <summary>Reads the single string argument of TargetFrameworkAttribute, if present.</summary>
    private static string? TargetFramework(IHasCustomAttribute owner)
    {
        try
        {
            var attr = owner.CustomAttributes.FirstOrDefault(a =>
                a.TypeFullName == "System.Runtime.Versioning.TargetFrameworkAttribute");
            if (attr == null || attr.ConstructorArguments.Count == 0) return null;
            return attr.ConstructorArguments[0].Value switch
            {
                UTF8String u => u.String,
                string s => s,
                _ => null
            };
        }
        catch { return null; }
    }

    private static JsonObject TypeNode(TypeDef t, int? referenceIndex = null)
    {
        // Members are grouped by kind and sorted by name; nested types come last so the head of a
        // type is its actual data/behaviour rather than a wall of compiler generated helper classes.
        var children = new JsonArray();
        foreach (var f in t.Fields.OrderBy(x => x.Name.String, StringComparer.OrdinalIgnoreCase))
            children.Add(MemberNode("field", f.Name.String, f.MDToken.Raw, FieldDetail(f), referenceIndex, IsSyntheticName(f.Name.String)));
        foreach (var p in t.Properties.OrderBy(x => x.Name.String, StringComparer.OrdinalIgnoreCase))
            children.Add(MemberNode("property", p.Name.String, p.MDToken.Raw, PropertyDetail(p), referenceIndex, IsSyntheticName(p.Name.String)));
        foreach (var e in t.Events.OrderBy(x => x.Name.String, StringComparer.OrdinalIgnoreCase))
            children.Add(MemberNode("event", e.Name.String, e.MDToken.Raw, EventDetail(e), referenceIndex, IsSyntheticName(e.Name.String)));
        foreach (var m in t.Methods.OrderBy(x => x.Name.String, StringComparer.OrdinalIgnoreCase))
            children.Add(MemberNode("method", m.Name.String, m.MDToken.Raw, MethodDetail(m), referenceIndex, IsSyntheticName(m.Name.String)));
        foreach (var n in t.NestedTypes.OrderBy(x => x.Name.String, StringComparer.OrdinalIgnoreCase))
            children.Add(TypeNode(n, referenceIndex));

        return new JsonObject
        {
            ["kind"] = "type",
            ["name"] = t.Name.String,
            ["token"] = Token(t.MDToken.Raw),
            ["ref"] = referenceIndex,
            ["detail"] = TypeDetail(t),
            ["compilerGenerated"] = HasCompilerGeneratedAttribute(t),
            ["synthetic"] = IsSyntheticName(t.Name.String),
            ["children"] = children
        };
    }

    private static JsonObject MemberNode(string kind, string name, uint token, string detail,
        int? referenceIndex = null, bool synthetic = false) => new()
    {
        ["kind"] = kind,
        ["name"] = name,
        ["token"] = Token(token),
        ["detail"] = detail,
        ["ref"] = referenceIndex,
        ["synthetic"] = synthetic
    };

    private static string Token(uint raw) => "0x" + raw.ToString("X8");

    // ---------- member formatting ----------

    private static string SafeTypeName(object? typeSig)
    {
        if (typeSig == null) return "?";
        try { return typeSig.ToString() ?? "?"; }
        catch { return "?"; }
    }

    private static string Access(ITypeDefOrRef t) => t switch
    {
        TypeDef td => td.IsPublic || td.IsNestedPublic ? "public "
            : td.IsNestedFamily || td.IsNestedFamilyOrAssembly ? "protected "
            : td.IsNestedPrivate ? "private " : "internal ",
        _ => string.Empty
    };

    private static string Access(MethodDef m) => m.IsPublic ? "public "
        : m.IsPrivate ? "private "
        : m.IsFamily ? "protected "
        : m.IsFamilyOrAssembly ? "protected internal "
        : "internal ";

    private static string Access(FieldDef f) => f.IsPublic ? "public "
        : f.IsPrivate ? "private "
        : f.IsFamily ? "protected "
        : f.IsFamilyOrAssembly ? "protected internal "
        : "internal ";

    private static string TypeDetail(TypeDef t)
    {
        var kind = t.IsInterface ? "interface"
            : t.IsEnum ? "enum"
            : t.IsValueType ? "struct"
            : (t.IsAbstract && t.IsSealed) ? "static class"
            : "class";
        var sb = new StringBuilder(Access(t)).Append(kind).Append(' ').Append(t.Name.String);
        try
        {
            if (t.BaseType != null && t.BaseType.FullName != "System.Object" && !t.IsEnum && !t.IsValueType)
                sb.Append(" : ").Append(t.BaseType.FullName);
            var ifaces = t.Interfaces.Where(i => i.Interface != null).Select(i => i.Interface!.FullName).ToList();
            if (ifaces.Count > 0)
                sb.Append(t.BaseType != null && t.BaseType.FullName != "System.Object" && !t.IsEnum && !t.IsValueType ? ", " : " : ")
                  .Append(string.Join(", ", ifaces));
        }
        catch { /* ignore malformed metadata */ }
        return sb.ToString();
    }

    private static string MethodDetail(MethodDef m)
    {
        var sb = new StringBuilder(Access(m));
        if (m.IsStatic) sb.Append("static ");
        if (m.IsAbstract) sb.Append("abstract ");
        else if (m.IsVirtual && !m.IsFinal) sb.Append("virtual ");
        var sig = m.MethodSig;
        sb.Append(sig == null ? "?" : SafeTypeName(sig.RetType)).Append(' ').Append(m.Name.String).Append('(');
        if (sig?.Params != null)
            sb.Append(string.Join(", ", sig.Params.Select(p => SafeTypeName(p))));
        return sb.Append(')').ToString();
    }

    private static string FieldDetail(FieldDef f)
    {
        var sb = new StringBuilder(Access(f));
        if (f.IsStatic) sb.Append("static ");
        if (f.IsLiteral) sb.Append("const ");
        else if (f.IsInitOnly) sb.Append("readonly ");
        return sb.Append(SafeTypeName(f.FieldType)).Append(' ').Append(f.Name.String).ToString();
    }

    private static string PropertyDetail(PropertyDef p)
    {
        var sb = new StringBuilder();
        var acc = p.GetMethod != null ? p.GetMethod : p.SetMethod;
        if (acc != null) sb.Append(Access(acc));
        sb.Append(SafeTypeName(p.PropertySig?.RetType)).Append(' ').Append(p.Name.String).Append(" { ");
        if (p.GetMethod != null) sb.Append("get; ");
        if (p.SetMethod != null) sb.Append("set; ");
        return sb.Append('}').ToString();
    }

    private static string EventDetail(EventDef e)
    {
        var sb = new StringBuilder();
        if (e.AddMethod != null) sb.Append(Access(e.AddMethod));
        return sb.Append("event ").Append(SafeTypeName(e.EventType)).Append(' ').Append(e.Name.String).ToString();
    }

    /// <summary>
    /// Name based synthetic detection: closure classes, display classes, anonymous types, backing
    /// fields, array-init helpers and dnlib filler rows. Only these are hidden by default - a
    /// designer generated class such as "Settings" carries [CompilerGenerated] but is a real type
    /// that dnSpy shows, so the attribute alone must not hide anything.
    /// </summary>
    private static bool IsSyntheticName(string name)
    {
        if (name.Length == 0) return true;
        if (name.StartsWith("<", StringComparison.Ordinal)) return true;
        if (name.StartsWith("dummy_ptr", StringComparison.Ordinal)) return true;
        if (name.Contains("__StaticArrayInitTypeSize=", StringComparison.Ordinal)) return true;
        if (name.Contains("k__BackingField", StringComparison.Ordinal)) return true;
        return false;
    }

    private static bool HasCompilerGeneratedAttribute(IHasCustomAttribute member)
    {
        try
        {
            return member.CustomAttributes.Any(a =>
                a.TypeFullName is "System.Runtime.CompilerServices.CompilerGeneratedAttribute"
                    or "System.Runtime.CompilerServices.AsyncStateMachineAttribute");
        }
        catch { return false; }
    }

    // ---------- code / il ----------

    /// <summary>Diagnostic entry point: decompile with an externally supplied cancellation token.</summary>
    public JsonObject DecompileNodeWithToken(uint token, CancellationToken cancellation)
    {
        RefreshPreviewIfNeeded();
        _decompiler.CancellationToken = cancellation;
        try
        {
            var handle = MetadataTokens.EntityHandle(unchecked((int)token));
            return new JsonObject
            {
                ["token"] = Token(token),
                ["language"] = "C#",
                ["text"] = _decompiler.DecompileAsString(handle)
            };
        }
        finally
        {
            _decompiler.CancellationToken = CancellationToken.None;
        }
    }

    public JsonObject DecompileNode(uint token)
    {
        RefreshPreviewIfNeeded();
        var cancellation = BeginWork();
        _decompiler.CancellationToken = cancellation;
        var handle = MetadataTokens.EntityHandle(unchecked((int)token));
        try
        {
            return new JsonObject
            {
                ["token"] = Token(token),
                ["language"] = "C#",
                ["text"] = _decompiler.DecompileAsString(handle)
            };
        }
        catch (OperationCanceledException)
        {
            throw;   // let the protocol report "cancelled" instead of a fake result
        }
        catch (Exception ex)
        {
            // fall back to the declaring type (e.g. handles ILSpy cannot decompile on their own)
            var owner = FindDeclaringType(token);
            if (owner != null)
            {
                try
                {
                    return new JsonObject
                    {
                        ["token"] = Token(owner.MDToken.Raw),
                        ["language"] = "C#",
                        ["text"] = _decompiler.DecompileAsString(MetadataTokens.EntityHandle(unchecked((int)owner.MDToken.Raw))),
                        ["note"] = "decompiled declaring type; direct decompilation failed: " + ex.Message
                    };
                }
                catch { /* fall through */ }
            }
            return new JsonObject
            {
                ["token"] = Token(token),
                ["language"] = "C#",
                ["text"] = "// decompilation failed: " + ex.Message
            };
        }
        finally
        {
            _decompiler.CancellationToken = CancellationToken.None;
        }
    }

    private TypeDef? FindDeclaringType(uint token)
    {
        if (_types.TryGetValue(token, out var t)) return t;
        if (_members.TryGetValue(token, out var m))
        {
            var decl = m.DeclaringType;
            if (decl != null) return decl;
        }
        return null;
    }

    public JsonObject GetIl(uint token)
    {
        if (!_members.TryGetValue(token, out var member))
            throw new InvalidOperationException($"no method with token {Token(token)}");
        if (member is not MethodDef method)
            throw new InvalidOperationException($"{Token(token)} is a {member.GetType().Name}, not a method");
        return IlPayload(method, null);
    }

    /// <summary>Shared IL rendering for the edited module and for read-only referenced assemblies.</summary>
    private static JsonObject IlPayload(MethodDef method, string? note)
    {
        var body = method.Body;
        if (body == null)
            return new JsonObject
            {
                ["token"] = Token(method.MDToken.Raw),
                ["text"] = "// method has no body (abstract / extern / pinvoke)",
                ["instructions"] = new JsonArray(),
                ["editable"] = false,
                ["note"] = note
            };

        var text = new StringBuilder();
        var instructions = new JsonArray();
        foreach (var ins in body.Instructions)
        {
            var operand = FormatOperand(ins.Operand);
            text.Append("IL_").Append(ins.Offset.ToString("X4")).Append(": ").Append(ins.OpCode.Name);
            if (operand.Length > 0) text.Append(' ').Append(operand);
            text.Append('\n');
            instructions.Add(new JsonObject
            {
                // dnlib exposes Offset as uint; the protocol uses Int32 consistently.
                ["offset"] = (int)ins.Offset,
                ["opcode"] = ins.OpCode.Name,
                ["operand"] = operand.Length == 0 ? null : operand
            });
        }

        return new JsonObject
        {
            ["token"] = Token(method.MDToken.Raw),
            ["text"] = text.ToString(),
            ["instructions"] = instructions,
            ["maxStack"] = body.MaxStack,
            ["initLocals"] = body.InitLocals,
            ["editable"] = note == null,
            ["exceptionHandlers"] = body.ExceptionHandlers.Count,
            ["note"] = note
        };
    }

    private static string FormatOperand(object? operand) => operand switch
    {
        null => string.Empty,
        string s => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"",
        Instruction target => "IL_" + target.Offset.ToString("X4"),
        _ => operand.ToString() ?? string.Empty
    };

    // ---------- access for editing ----------

    /// <summary>
    /// Writes the module preserving metadata tokens (RIDs). Without this dnlib renumbers rows,
    /// so a member's token would change on every save and any UI selection would point at the wrong member.
    /// </summary>
    private void WriteModule(string path, bool preserveRids)
    {
        var options = new ModuleWriterOptions(_module);
        if (preserveRids)
        {
            options.MetadataOptions ??= new MetadataOptions();
            options.MetadataOptions.Flags |= MetadataFlags.PreserveRids;
        }
        _module.Write(path, options);
    }

    /// <summary>
    /// Removals leave holes in the metadata tables. RID preservation would fill them with
    /// "dummy_ptr" types, so the next real save drops RID preservation (tokens get renumbered,
    /// which the UI absorbs because every write returns a fresh tree).
    /// </summary>
    public void NoteRowRemoved() => _rowRemoved = true;

    public bool RowsRemoved => _rowRemoved;

    /// <summary>Called after a structural edit so tokens added by the edit resolve immediately.</summary>
    public void StructureChanged()
    {
        MarkDirty();
        Index();
    }

    public TypeDef RequireType(uint token) =>
        _types.TryGetValue(token, out var type)
            ? type
            : throw new InvalidOperationException($"no type with token {Token(token)}");

    public IMemberDef? FindMember(uint token) =>
        _members.TryGetValue(token, out var member) ? member : null;

    public ModuleDefMD Module => _module;
    public MethodDef RequireMethod(uint token) =>
        _members.TryGetValue(token, out var m) && m is MethodDef md
            ? md
            : throw new InvalidOperationException($"no method with token {Token(token)}");

    public void MarkDirty() => Dirty = true;

    /// <summary>True when the previous save had to renumber metadata tokens (a row was deleted).</summary>
    public bool LastSaveRenumbered { get; private set; }

    public string Save(string? targetPath)
    {
        var target = string.IsNullOrEmpty(targetPath) ? SourcePath : Path.GetFullPath(targetPath!);
        var dir = Path.GetDirectoryName(target);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        LastSaveRenumbered = _rowRemoved;
        var temp = Path.Combine(Path.GetTempPath(), "ilworkbench-" + Guid.NewGuid().ToString("N") + ".dll");
        // Preserving RIDs is what keeps tokens stable across saves, but dnlib fills the gaps left by
        // deleted rows with "dummy_ptr" placeholder rows. So only preserve when nothing was removed.
        WriteModule(temp, preserveRids: !_rowRemoved);
        File.Move(temp, target, overwrite: true);
        DeletePreview();
        Dirty = false;
        _rowRemoved = false;

        // Re-read what was actually written so every token the UI holds matches the file.
        SourcePath = target;
        Reload();
        return target;
    }

    public void Dispose()
    {
        DeletePreview();
        _currentWork?.Dispose();
        foreach (var referenced in _referenced.Values) referenced.Module.Dispose();
        _referenced.Clear();
        _module.Dispose();
    }
}
