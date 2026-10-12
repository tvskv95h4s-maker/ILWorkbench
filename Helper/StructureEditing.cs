using dnlib.DotNet;
using dnlib.DotNet.Emit;

namespace ILWorkbench.Helper;

/// <summary>
/// Type and member level edits: add/remove fields, methods, properties, events and types.
/// Bodies created here are deliberately minimal and valid: "return default(T)" or "return constant".
/// </summary>
public static class StructureEditing
{
    // ---------- type name resolution ----------

    /// <summary>Resolves a type name typed by the user: "int", "System.String", "SampleLib.Severity", "System.String[]".</summary>
    public static TypeSig ResolveTypeSig(ModuleDef module, string name)
    {
        var trimmed = (name ?? string.Empty).Trim();
        if (trimmed.Length == 0) throw new InvalidOperationException("类型名不能为空");

        if (trimmed.EndsWith("[]", StringComparison.Ordinal))
            return new SZArraySig(ResolveTypeSig(module, trimmed[..^2]));

        switch (trimmed)
        {
            case "void": case "System.Void": return module.CorLibTypes.Void;
            case "bool": case "System.Boolean": return module.CorLibTypes.Boolean;
            case "char": case "System.Char": return module.CorLibTypes.Char;
            case "sbyte": case "System.SByte": return module.CorLibTypes.SByte;
            case "byte": case "System.Byte": return module.CorLibTypes.Byte;
            case "short": case "System.Int16": return module.CorLibTypes.Int16;
            case "ushort": case "System.UInt16": return module.CorLibTypes.UInt16;
            case "int": case "System.Int32": return module.CorLibTypes.Int32;
            case "uint": case "System.UInt32": return module.CorLibTypes.UInt32;
            case "long": case "System.Int64": return module.CorLibTypes.Int64;
            case "ulong": case "System.UInt64": return module.CorLibTypes.UInt64;
            case "float": case "System.Single": return module.CorLibTypes.Single;
            case "double": case "System.Double": return module.CorLibTypes.Double;
            case "string": case "System.String": return module.CorLibTypes.String;
            case "object": case "System.Object": return module.CorLibTypes.Object;
        }

        // a definition in this module wins, so structs/enums keep their value-type nature
        var existing = module.GetTypes().FirstOrDefault(t => t.FullName == trimmed)
            ?? module.GetTypes().FirstOrDefault(t => t.Name == trimmed);
        if (existing != null) return existing.ToTypeSig();

        var index = trimmed.LastIndexOf('.');
        var ns = index > 0 ? trimmed[..index] : string.Empty;
        var simple = index > 0 ? trimmed[(index + 1)..] : trimmed;
        return new TypeRefUser(module, ns, simple, module.CorLibTypes.AssemblyRef).ToTypeSig();
    }

    private static ITypeDefOrRef ObjectType(ModuleDef module) =>
        module.CorLibTypes.Object.TypeDefOrRef
        ?? throw new InvalidOperationException("模块没有可用的 corlib 引用");

    // ---------- add ----------

    public static string AddField(AssemblySession session, uint typeToken, string name, string fieldType, bool isStatic, bool isPublic)
    {
        var type = session.RequireType(typeToken);
        RequireName(name);
        if (type.Fields.Any(f => f.Name == name))
            throw new InvalidOperationException($"类型 {type.Name} 已经有字段 {name}");

        var attributes = isPublic ? FieldAttributes.Public : FieldAttributes.Private;
        if (isStatic) attributes |= FieldAttributes.Static;

        var field = new FieldDefUser(name, new FieldSig(ResolveTypeSig(session.Module, fieldType)), attributes);
        type.Fields.Add(field);
        // dnlib's collections do not back-fill the owner, and later lookups rely on DeclaringType.
        field.DeclaringType = type;
        session.StructureChanged();
        return $"已添加字段 {fieldType} {type.Name}.{name}";
    }

    public static string AddMethod(AssemblySession session, uint typeToken, string name, string returnType,
        IReadOnlyList<string> parameterTypes, bool isStatic, bool isPublic, string bodyKind, string? constant)
    {
        var type = session.RequireType(typeToken);
        RequireName(name);
        if (type.Methods.Any(m => m.Name == name && m.MethodSig != null && m.MethodSig.Params.Count == parameterTypes.Count))
            throw new InvalidOperationException($"类型 {type.Name} 已经有同名同参数个数的方法 {name}");

        var module = session.Module;
        var returnSig = ResolveTypeSig(module, returnType);
        var parameterSigs = parameterTypes.Select(p => ResolveTypeSig(module, p)).ToArray();

        var inInterface = type.IsInterface;
        // Interface methods are ordinary instance methods; only an explicit "static" makes them static.
        var sig = isStatic
            ? (parameterSigs.Length == 0 ? MethodSig.CreateStatic(returnSig) : MethodSig.CreateStatic(returnSig, parameterSigs))
            : (parameterSigs.Length == 0 ? MethodSig.CreateInstance(returnSig) : MethodSig.CreateInstance(returnSig, parameterSigs));

        var attributes = isPublic || inInterface ? MethodAttributes.Public : MethodAttributes.Private;
        if (isStatic) attributes |= MethodAttributes.Static;
        // Interface members are abstract and carry no body; HideBySig matches what C# emits.
        if (inInterface) attributes |= MethodAttributes.Abstract | MethodAttributes.Virtual | MethodAttributes.NewSlot | MethodAttributes.HideBySig;

        var method = new MethodDefUser(name, sig, attributes)
        {
            ImplAttributes = MethodImplAttributes.IL | MethodImplAttributes.Managed
        };
        method.Body = inInterface ? null : BuildBody(returnSig, bodyKind, constant);

        type.Methods.Add(method);
        method.DeclaringType = type;
        session.StructureChanged();
        var shape = parameterTypes.Count == 0 ? "()" : "(" + string.Join(", ", parameterTypes) + ")";
        return $"已添加方法 {returnType} {type.Name}.{name}{shape}";
    }

    public static string AddType(AssemblySession session, string ns, string name, string kind, string? baseTypeName, bool isPublic)
    {
        var module = session.Module;
        RequireName(name);
        ns ??= string.Empty;
        if (module.GetTypes().Any(t => t.Namespace == ns && t.Name == name && t.DeclaringType == null))
            throw new InvalidOperationException($"命名空间 {ns} 下已经有类型 {name}");

        var normalized = (kind ?? "class").Trim().ToLowerInvariant();
        var attributes = isPublic ? TypeAttributes.Public : TypeAttributes.NotPublic;
        ITypeDefOrRef? baseType;
        switch (normalized)
        {
            case "interface":
                attributes |= TypeAttributes.Interface | TypeAttributes.Abstract;
                baseType = null;
                break;
            case "struct":
                attributes |= TypeAttributes.Sealed | TypeAttributes.SequentialLayout | TypeAttributes.BeforeFieldInit;
                baseType = new TypeRefUser(module, "System", "ValueType", module.CorLibTypes.AssemblyRef);
                break;
            default:
                attributes |= TypeAttributes.BeforeFieldInit;
                baseType = string.IsNullOrWhiteSpace(baseTypeName)
                    ? ObjectType(module)
                    : ResolveTypeSig(module, baseTypeName!).ToTypeDefOrRef();
                break;
        }

        var type = new TypeDefUser(ns, name, baseType) { Attributes = attributes };
        module.Types.Add(type);
        session.StructureChanged();
        return $"已添加{Describe(normalized)} {type.FullName}";
    }

    private static string Describe(string kind) => kind switch
    {
        "interface" => "接口",
        "struct" => "结构体",
        _ => "类型"
    };

    // ---------- remove ----------

    public static string RemoveMember(AssemblySession session, uint token)
    {
        var member = session.FindMember(token)
            ?? throw new InvalidOperationException($"token 0x{token:X8} 不是类型成员（方法/字段/属性/事件）");

        switch (member)
        {
            case MethodDef method:
            {
                var owner = FindAccessorOwner(method);
                if (owner != null)
                    throw new InvalidOperationException($"{method.Name} 是 {owner} 的访问器，请改用删除该属性/事件");
                // The type and name must be captured before detaching: dnlib clears DeclaringType on Remove.
                var type = RequireDeclaringType(method);
                var label = $"{type.Name}.{method.Name}";
                type.Methods.Remove(method);
                session.NoteRowRemoved();
                session.StructureChanged();
                return $"已删除方法 {label}";
            }
            case FieldDef field:
            {
                var type = RequireDeclaringType(field);
                var label = $"{type.Name}.{field.Name}";
                type.Fields.Remove(field);
                session.NoteRowRemoved();
                session.StructureChanged();
                return $"已删除字段 {label}";
            }
            case PropertyDef property:
            {
                var type = RequireDeclaringType(property);
                var label = $"{type.Name}.{property.Name}";
                if (property.GetMethod != null) type.Methods.Remove(property.GetMethod);
                if (property.SetMethod != null) type.Methods.Remove(property.SetMethod);
                if (property.OtherMethods != null)
                    foreach (var other in property.OtherMethods.ToList()) type.Methods.Remove(other);
                type.Properties.Remove(property);
                session.NoteRowRemoved();
                session.StructureChanged();
                return $"已删除属性 {label}（含访问器）";
            }
            case EventDef @event:
            {
                var type = RequireDeclaringType(@event);
                var label = $"{type.Name}.{@event.Name}";
                if (@event.AddMethod != null) type.Methods.Remove(@event.AddMethod);
                if (@event.RemoveMethod != null) type.Methods.Remove(@event.RemoveMethod);
                if (@event.InvokeMethod != null) type.Methods.Remove(@event.InvokeMethod);
                if (@event.OtherMethods != null)
                    foreach (var other in @event.OtherMethods.ToList()) type.Methods.Remove(other);
                type.Events.Remove(@event);
                session.NoteRowRemoved();
                session.StructureChanged();
                return $"已删除事件 {label}（含访问器）";
            }
            default:
                throw new InvalidOperationException($"不支持删除 {member.GetType().Name}");
        }
    }

    private static TypeDef RequireDeclaringType(IMemberDef member) =>
        member.DeclaringType ?? throw new InvalidOperationException($"无法定位 {member.Name} 的声明类型");

    public static string RemoveType(AssemblySession session, uint token)
    {
        var type = session.RequireType(token);
        if (type.IsGlobalModuleType)
            throw new InvalidOperationException("不能删除 <Module> 类型");

        var fullName = type.FullName;
        if (type.DeclaringType != null)
            type.DeclaringType.NestedTypes.Remove(type);
        else
            session.Module.Types.Remove(type);

        session.NoteRowRemoved();
        session.StructureChanged();
        return $"已删除类型 {fullName}（若其它代码仍引用它，保存后的程序集会在运行时报错）";
    }

    private static string? FindAccessorOwner(MethodDef method)
    {
        var type = method.DeclaringType;
        if (type == null) return null;
        foreach (var property in type.Properties)
        {
            if (ReferenceEquals(property.GetMethod, method) || ReferenceEquals(property.SetMethod, method))
                return "属性 " + property.Name;
        }
        foreach (var @event in type.Events)
        {
            if (ReferenceEquals(@event.AddMethod, method) || ReferenceEquals(@event.RemoveMethod, method) || ReferenceEquals(@event.InvokeMethod, method))
                return "事件 " + @event.Name;
        }
        return null;
    }

    private static void RequireName(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new InvalidOperationException("名称不能为空");
    }

    // ---------- method bodies ----------

    /// <summary>Builds a valid minimal body: `return default;` or `return &lt;constant&gt;;`.</summary>
    private static CilBody BuildBody(TypeSig returnType, string bodyKind, string? constant)
    {
        var body = new CilBody { InitLocals = true };
        var instructions = body.Instructions;
        var useConstant = string.Equals(bodyKind, "constant", StringComparison.OrdinalIgnoreCase);

        if (returnType.ElementType == ElementType.Void)
        {
            instructions.Add(Instruction.Create(OpCodes.Ret));
            return body;
        }

        if (useConstant && TryEmitConstant(instructions, returnType, constant))
        {
            instructions.Add(Instruction.Create(OpCodes.Ret));
            body.UpdateInstructionOffsets();
            return body;
        }

        EmitDefaultValue(body, returnType);
        instructions.Add(Instruction.Create(OpCodes.Ret));
        body.UpdateInstructionOffsets();
        return body;
    }

    private static bool TryEmitConstant(IList<Instruction> instructions, TypeSig returnType, string? constant)
    {
        if (constant == null) return false;
        switch (returnType.ElementType)
        {
            case ElementType.String:
                instructions.Add(Instruction.Create(OpCodes.Ldstr, constant));
                return true;
            case ElementType.Boolean:
                instructions.Add(Instruction.CreateLdcI4(constant is "true" or "1" ? 1 : 0));
                return true;
            case ElementType.Char:
                instructions.Add(Instruction.CreateLdcI4(constant.Length > 0 ? constant[0] : 0));
                return true;
            case ElementType.I1: case ElementType.U1: case ElementType.I2: case ElementType.U2:
            case ElementType.I4: case ElementType.U4:
                if (!int.TryParse(constant, out var intValue)) throw new InvalidOperationException($"常量 '{constant}' 不是合法整数");
                instructions.Add(Instruction.CreateLdcI4(intValue));
                return true;
            case ElementType.I8: case ElementType.U8:
                if (!long.TryParse(constant, out var longValue)) throw new InvalidOperationException($"常量 '{constant}' 不是合法长整数");
                instructions.Add(Instruction.Create(OpCodes.Ldc_I8, longValue));
                return true;
            case ElementType.R4:
                if (!float.TryParse(constant, out var floatValue)) throw new InvalidOperationException($"常量 '{constant}' 不是合法浮点数");
                instructions.Add(Instruction.Create(OpCodes.Ldc_R4, floatValue));
                return true;
            case ElementType.R8:
                if (!double.TryParse(constant, out var doubleValue)) throw new InvalidOperationException($"常量 '{constant}' 不是合法浮点数");
                instructions.Add(Instruction.Create(OpCodes.Ldc_R8, doubleValue));
                return true;
            default:
                return false;
        }
    }

    private static void EmitDefaultValue(CilBody body, TypeSig returnType)
    {
        var instructions = body.Instructions;
        switch (returnType.ElementType)
        {
            case ElementType.Boolean: case ElementType.Char:
            case ElementType.I1: case ElementType.U1: case ElementType.I2: case ElementType.U2:
            case ElementType.I4: case ElementType.U4:
                instructions.Add(Instruction.CreateLdcI4(0));
                break;
            case ElementType.I8: case ElementType.U8:
                instructions.Add(Instruction.CreateLdcI4(0));
                instructions.Add(Instruction.Create(OpCodes.Conv_I8));
                break;
            case ElementType.R4:
                instructions.Add(Instruction.Create(OpCodes.Ldc_R4, 0f));
                break;
            case ElementType.R8:
                instructions.Add(Instruction.Create(OpCodes.Ldc_R8, 0d));
                break;
            case ElementType.ValueType:
            {
                // default(SomeStruct): initialise a local and load it back
                if (returnType is not TypeDefOrRefSig { TypeDefOrRef: { } definition })
                    throw new InvalidOperationException("无法为未知值类型生成默认返回值，请在 IL 视图里手工补全方法体");
                var local = new Local(returnType);
                body.Variables.Add(local);
                instructions.Add(Instruction.Create(OpCodes.Ldloca_S, local));
                instructions.Add(Instruction.Create(OpCodes.Initobj, definition));
                instructions.Add(Instruction.Create(OpCodes.Ldloc, local));
                break;
            }
            default:
                instructions.Add(Instruction.Create(OpCodes.Ldnull));
                break;
        }
    }
}
