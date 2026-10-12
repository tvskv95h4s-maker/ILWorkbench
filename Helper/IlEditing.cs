using System.Text.Json;
using dnlib.DotNet;
using dnlib.DotNet.Emit;

namespace ILWorkbench.Helper;

/// <summary>Instruction-level IL edits: the dnSpy-style "edit method body" surface.</summary>
public static class IlEditing
{
    private static readonly Dictionary<string, OpCode> OpCodesByName = BuildOpCodeTable();

    private static Dictionary<string, OpCode> BuildOpCodeTable()
    {
        var map = new Dictionary<string, OpCode>(StringComparer.OrdinalIgnoreCase);
        foreach (var field in typeof(OpCodes).GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static))
        {
            if (field.GetValue(null) is OpCode op)
                map[op.Name] = op;
        }
        return map;
    }

    public static OpCode ResolveOpCode(string name)
    {
        if (OpCodesByName.TryGetValue(name, out var op)) return op;
        throw new InvalidOperationException($"unknown opcode: {name}");
    }

    private static Instruction At(MethodDef method, int offset) =>
        method.Body.Instructions.FirstOrDefault(i => i.Offset == offset)
        ?? throw new InvalidOperationException($"no instruction at IL_{offset:X4}");

    /// <summary>Replace a constant (string / integer / float) carried by an instruction.</summary>
    public static string SetConstant(AssemblySession session, uint token, int offset, JsonElement? value)
    {
        var method = session.RequireMethod(token);
        var ins = At(method, offset);
        switch (ins.OpCode.Code)
        {
            case Code.Ldstr:
                ins.Operand = StringValue(value);
                break;
            case Code.Ldc_I4:
            case Code.Ldc_I4_S:
            case Code.Ldc_I4_0:
            case Code.Ldc_I4_1:
            case Code.Ldc_I4_2:
            case Code.Ldc_I4_3:
            case Code.Ldc_I4_4:
            case Code.Ldc_I4_5:
            case Code.Ldc_I4_6:
            case Code.Ldc_I4_7:
            case Code.Ldc_I4_8:
            case Code.Ldc_I4_M1:
                Swap(method, ins, Instruction.CreateLdcI4(IntValue(value)));
                break;
            case Code.Ldc_I8:
                ins.Operand = LongValue(value);
                break;
            case Code.Ldc_R4:
                ins.Operand = FloatValue(value);
                break;
            case Code.Ldc_R8:
                ins.Operand = DoubleValue(value);
                break;
            default:
                throw new InvalidOperationException($"instruction at IL_{offset:X4} ({ins.OpCode.Name}) does not carry a constant");
        }
        session.MarkDirty();
        method.Body.UpdateInstructionOffsets();
        return Describe(At(method, offset));
    }

    /// <summary>Replace the instruction at <paramref name="offset"/> with a new one.</summary>
    public static string ReplaceInstruction(AssemblySession session, uint token, int offset, string opcodeName, JsonElement? operand)
    {
        var method = session.RequireMethod(token);
        var old = At(method, offset);
        Swap(method, old, Create(method, opcodeName, operand));
        session.MarkDirty();
        method.Body.UpdateInstructionOffsets();
        return Describe(At(method, offset));
    }

    /// <summary>Insert a new instruction before <paramref name="beforeOffset"/>; a negative offset appends at the end.</summary>
    public static string InsertInstruction(AssemblySession session, uint token, int beforeOffset, string opcodeName, JsonElement? operand)
    {
        var method = session.RequireMethod(token);
        var inserted = Create(method, opcodeName, operand);
        if (beforeOffset < 0)
        {
            method.Body.Instructions.Add(inserted);
        }
        else
        {
            var anchor = At(method, beforeOffset);
            method.Body.Instructions.Insert(method.Body.Instructions.IndexOf(anchor), inserted);
        }
        session.MarkDirty();
        method.Body.UpdateInstructionOffsets();
        return Describe(inserted);
    }

    /// <summary>Remove the instruction at <paramref name="offset"/>.</summary>
    public static string RemoveInstruction(AssemblySession session, uint token, int offset)
    {
        var method = session.RequireMethod(token);
        var ins = At(method, offset);
        var text = Describe(ins);
        method.Body.Instructions.Remove(ins);
        session.MarkDirty();
        method.Body.UpdateInstructionOffsets();
        return "removed " + text;
    }

    /// <summary>Swap an instruction in place, keeping branch targets valid.</summary>
    private static void Swap(MethodDef method, Instruction old, Instruction replacement)
    {
        var index = method.Body.Instructions.IndexOf(old);
        method.Body.Instructions[index] = replacement;
        foreach (var ins in method.Body.Instructions)
        {
            if (ReferenceEquals(ins.Operand, old))
                ins.Operand = replacement;
        }
    }

    private static Instruction Create(MethodDef method, string opcodeName, JsonElement? operand)
    {
        var op = ResolveOpCode(opcodeName);
        if (!HasValue(operand))
        {
            if (op.OperandType != OperandType.InlineNone)
                throw new InvalidOperationException($"{op.Name} requires an operand");
            return Instruction.Create(op);
        }

        var value = operand!.Value;
        switch (op.OperandType)
        {
            case OperandType.InlineString:
                return Instruction.Create(op, value.GetString() ?? string.Empty);
            case OperandType.ShortInlineI:
                return Instruction.Create(op, (sbyte)value.GetInt32());
            case OperandType.InlineI:
                return Instruction.Create(op, value.GetInt32());
            case OperandType.InlineI8:
                return Instruction.Create(op, value.GetInt64());
            case OperandType.ShortInlineR:
                return Instruction.Create(op, value.GetSingle());
            case OperandType.InlineR:
                return Instruction.Create(op, value.GetDouble());
            case OperandType.InlineBrTarget:
            case OperandType.ShortInlineBrTarget:
                return Instruction.Create(op, At(method, value.GetInt32()));
            case OperandType.InlineField:
                return Instruction.Create(op, Find<FieldDef>(method, value.GetString()));
            case OperandType.InlineMethod:
                return Instruction.Create(op, Find<MethodDef>(method, value.GetString()));
            case OperandType.InlineType:
                return Instruction.Create(op, Find<TypeDef>(method, value.GetString()));
            case OperandType.InlineTok:
            {
                var name = value.GetString();
                var type = TryFind<TypeDef>(method, name);
                if (type != null) return Instruction.Create(op, type);
                var target = TryFind<MethodDef>(method, name);
                if (target != null) return Instruction.Create(op, target);
                var field = TryFind<FieldDef>(method, name);
                if (field != null) return Instruction.Create(op, field);
                throw new InvalidOperationException($"cannot resolve member reference: {name}");
            }
            default:
                throw new InvalidOperationException($"unsupported operand type for {op.Name}: {op.OperandType}");
        }
    }

    private static bool HasValue(JsonElement? value) =>
        value.HasValue && value.Value.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined);

    private static string StringValue(JsonElement? value) =>
        HasValue(value) ? value!.Value.GetString() ?? string.Empty : string.Empty;

    private static int IntValue(JsonElement? value) =>
        HasValue(value) ? value!.Value.GetInt32() : throw new InvalidOperationException("integer constant expected");

    private static long LongValue(JsonElement? value) =>
        HasValue(value) ? value!.Value.GetInt64() : throw new InvalidOperationException("long constant expected");

    private static float FloatValue(JsonElement? value) =>
        HasValue(value) ? value!.Value.GetSingle() : throw new InvalidOperationException("float constant expected");

    private static double DoubleValue(JsonElement? value) =>
        HasValue(value) ? value!.Value.GetDouble() : throw new InvalidOperationException("double constant expected");

    private static T Find<T>(MethodDef method, string? fullName) where T : class, IMemberRef =>
        TryFind<T>(method, fullName) ?? throw new InvalidOperationException($"cannot resolve member reference: {fullName}");

    /// <summary>Resolves a member by dnlib full name inside the module being edited.</summary>
    private static T? TryFind<T>(MethodDef method, string? fullName) where T : class, IMemberRef
    {
        if (string.IsNullOrEmpty(fullName)) return null;
        foreach (var type in method.Module.GetTypes())
        {
            if (typeof(T) == typeof(TypeDef) && type.FullName == fullName) return type as T;
            if (typeof(T) == typeof(MethodDef))
            {
                foreach (var m in type.Methods)
                    if (m.FullName == fullName) return m as T;
            }
            if (typeof(T) == typeof(FieldDef))
            {
                foreach (var f in type.Fields)
                    if (f.FullName == fullName) return f as T;
            }
        }
        return null;
    }

    private static string Describe(Instruction ins) =>
        $"IL_{ins.Offset:X4}: {ins.OpCode.Name}" + (ins.Operand == null ? string.Empty : " " + ins.Operand);
}
