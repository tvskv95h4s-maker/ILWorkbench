import Foundation

/// A node in the assembly tree (assembly / namespace / type / member).
/// `token` is the metadata token, stable across saves because the helper writes with PreserveRids.
struct AssemblyNode: Codable, Identifiable, Hashable {
    let kind: String
    let name: String
    let token: String?
    let detail: String?
    let path: String?
    let compilerGenerated: Bool?
    /// Name based synthetic marker (closure classes, backing fields, dnlib filler rows).
    let synthetic: Bool?
    let children: [AssemblyNode]?
    /// Metadata group ("pe" / "typerefs" / "references" / "resources" / "types") for explorer nodes.
    let group: String?
    /// Position inside a metadata list group.
    let index: Int?
    /// Index of the referenced assembly this node came from (nil = the assembly being edited).
    let ref: Int?
    /// Metadata groups and referenced assemblies load their children on first expansion.
    let expandable: Bool?
    /// Short token text shown next to the name, dnSpy style ("@010003C0").
    let tokenLabel: String?
    /// Language neutral label key (group nodes, PE sub nodes, global namespace).
    let nameKey: String?
    let nameIndex: Int?
    let nameSuffix: String?
    let count: Int?
    let typeCount: Int?

    var id: String {
        // Error nodes must be unique per file, otherwise re-opening another bad file keeps the old document.
        if kind == "error" { return "error:" + (path ?? name) }
        if let token { return token }
        if let group { return "group:" + group + (index.map { "#\($0)" } ?? "") }
        if let ref { return "ref:" + String(ref) + ":" + (token ?? name) }
        return kind + ":" + name + ":" + (detail ?? "")
    }

    var isGroup: Bool { group != nil }
    /// Nodes from a referenced assembly are read-only.
    var isReference: Bool { ref != nil }
    var loadChildrenOnExpand: Bool { (expandable ?? false) || (group != nil && children?.isEmpty != false) }
    /// Group nodes show a text report instead of decompiled code.
    var isMetadata: Bool { group != nil }

    var symbolName: String {
        switch kind {
        case "assembly": return "shippingbox"
        case "namespace": return "folder"
        case "type": return "cube"
        case "method": return "function"
        case "field": return "square.stack.3d.up"
        case "property": return "p.circle"
        case "event": return "bolt"
        case "group": return group == "pe" ? "doc.text.magnifyingglass" : "folder.badge.gearshape"
        case "typeref": return "arrow.turn.down.right"
        case "assemblyref": return "shippingbox.circle"
        case "resource": return "doc.on.doc"
        default: return "questionmark"
        }
    }

    var kindLabel: String {
        L.t("kindlabel." + kind)
    }

    /// Row title in the current language. Names coming from metadata are shown verbatim; structural
    /// nodes (PE, references, global namespace, …) are labelled from the string table.
    var displayTitle: String {
        if let nameKey {
            if let nameIndex { return L.t(nameKey, nameIndex, nameSuffix ?? "") }
            return L.t(nameKey)
        }
        return name
    }

    /// Row subtitle in the current language (counts for structural nodes, signatures for members).
    var displayDetail: String? {
        if let typeCount { return L.t("namespace.typeCount", typeCount) }
        if let count { return L.t("group.count", count) }
        return detail
    }

    var isMethod: Bool { kind == "method" }
    var hasCode: Bool { isMetadata || (token != nil && kind != "namespace" && kind != "assembly") }
}

struct OpenResult: Codable {
    let path: String
    let tree: AssemblyNode
    /// Set when the file is not a readable managed assembly; `tree` is then an error node.
    let failed: Bool?
    let failure: FileFailure?
}

struct FileFailure: Codable {
    let kind: String
    let reason: String
    let size: Int
    let magic: String
    let machine: String
    let hasClrHeader: Bool
}

struct CloseResult: Codable {
    let closed: Bool
}

struct SaveResult: Codable {
    let path: String
    let tree: AssemblyNode
    /// True when the save had to renumber metadata tokens (a member/type was deleted first).
    let renumbered: Bool?
}

struct StructureResult: Codable {
    let text: String
    let tree: AssemblyNode
}

struct GroupChildrenResult: Codable {
    let group: String?
    let name: String?
    let path: String?
    let children: [AssemblyNode]
}

struct MetadataResult: Codable {
    let text: String
    let language: String?
}

struct CodeResult: Codable {
    let token: String
    let language: String?
    let text: String
    let note: String?
}

struct IlInstruction: Codable, Hashable, Identifiable {
    let offset: Int
    let opcode: String
    let operand: String?

    var id: Int { offset }

    var isStringConstant: Bool { opcode == "ldstr" }
    var isNumberConstant: Bool {
        opcode.hasPrefix("ldc.i4") || opcode == "ldc.i8" || opcode == "ldc.r4" || opcode == "ldc.r8"
    }
    /// Constants can be patched straight from the instruction list.
    var isEditableConstant: Bool { isStringConstant || isNumberConstant }

    /// The literal without quotes, ready to be edited in a text field.
    var editableValue: String {
        guard let operand else { return "" }
        if isStringConstant, operand.count >= 2, operand.hasPrefix("\""), operand.hasSuffix("\"") {
            return String(operand.dropFirst().dropLast())
        }
        return operand
    }

    var display: String {
        "IL_" + String(format: "%04X", offset) + ":  " + opcode + (operand.map { " " + $0 } ?? "")
    }
}

struct IlResult: Codable {
    let token: String
    let text: String
    let instructions: [IlInstruction]?
    let maxStack: Int?
    let initLocals: Bool?
    let editable: Bool?
    let exceptionHandlers: Int?
    /// Set for read-only listings (referenced assemblies) and for methods without a body.
    let note: String?
}

struct TextResult: Codable {
    let text: String
}


/// Expansion requests coming from menus; the outline view executes them.
enum ExpansionCommand {
    case rootOnly
    case defaultLevels
    case all
    case none
    /// Expand one node by id (diagnostics and scripted screenshots).
    case node(String)
}
