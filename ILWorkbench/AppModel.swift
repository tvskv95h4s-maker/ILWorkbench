import Foundation
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case csharp = "C#"
    case il = "IL"
    var id: String { rawValue }
}

/// How the IL editor sheet should apply its result.
enum IlEditMode: Identifiable {
    case constant(IlInstruction)
    case replace(IlInstruction)
    case insertBefore(IlInstruction)
    case appendAtEnd

    var id: String {
        switch self {
        case .constant(let instruction): return "constant-\(instruction.offset)"
        case .replace(let instruction): return "replace-\(instruction.offset)"
        case .insertBefore(let instruction): return "insert-\(instruction.offset)"
        case .appendAtEnd: return "append"
        }
    }

    var title: String {
        switch self {
        case .constant(let instruction): return "编辑常量 IL_\(String(format: "%04X", instruction.offset))"
        case .replace(let instruction): return "替换指令 IL_\(String(format: "%04X", instruction.offset))"
        case .insertBefore(let instruction): return "在 IL_\(String(format: "%04X", instruction.offset)) 之前插入"
        case .appendAtEnd: return "在方法末尾追加指令"
        }
    }

    var target: IlInstruction? {
        switch self {
        case .constant(let instruction), .replace(let instruction), .insertBefore(let instruction): return instruction
        case .appendAtEnd: return nil
        }
    }

    var isConstant: Bool {
        if case .constant = self { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// One model per app so menu bar commands can drive the same session as the window.
    static let shared = AppModel()

    @Published var tree: AssemblyNode?
    @Published var assemblyPath: String?
    @Published var code: String = ""
    @Published var codeNote: String?
    @Published var il: IlResult?
    @Published var status = "打开一个 .NET 程序集（.dll / .exe）开始"
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var isDirty = false

    @Published var searchText = ""

    /// Nodes whose children are visible. A large assembly has tens of thousands of nodes, so only
    /// the first level is expanded on open; expanding everything eagerly freezes the outline.
    @Published var expandedIDs: Set<String> = []

    @Published var busyMessage: String?

    @Published var selectedNodeID: String? {
        didSet {
            guard oldValue != selectedNodeID else { return }
            selectionTask?.cancel()
            selectionTask = Task { [weak self] in await self?.loadSelected() }
        }
    }

    @Published var viewMode: ViewMode = .csharp {
        didSet {
            guard oldValue != viewMode else { return }
            selectionTask?.cancel()
            selectionTask = Task { [weak self] in await self?.loadSelected() }
        }
    }

    let settings = AppSettings.shared
    private let client = HelperClient()
    /// Kept so the error document can be rendered locally in the current language.
    private(set) var failedFile: FileFailure?
    private var nodesByID: [String: AssemblyNode] = [:]
    private var selectionTask: Task<Void, Never>?
    private var codeCache: [String: CodeResult] = [:]
    private var metadataCache: [String: String] = [:]
    private var ilCache: [String: IlResult] = [:]
    /// Children of the metadata list groups (type references, assembly references, resources),
    /// fetched the first time such a node is expanded so opening stays fast.
    @Published var groupChildren: [String: [AssemblyNode]] = [:]
    /// Namespaces of referenced assemblies, loaded when such a node is expanded.
    @Published var referencedChildren: [Int: [AssemblyNode]] = [:]
    private static let listGroups: Set<String> = ["pe", "typerefs", "references", "resources"]

    /// Set by the outline view: it performs the actual expand/collapse on its own items.
    var expansionHandler: ((ExpansionCommand) -> Void)?
    private var cachedTree: AssemblyNode?
    private var cachedTreeKey = ""
    /// Bumped whenever the tree is replaced; the outline view reloads on change.
    private(set) var treeRevision = 0

    /// Which tokenizer the code pane should use for the current selection.
    var codeLanguage: SourceLanguage {
        if selectedNode?.isMetadata == true { return .plain }
        if viewMode == .il && selectedNode?.isMethod == true { return .il }
        return selectedNode == nil ? .plain : .csharp
    }

    var selectedNode: AssemblyNode? {
        guard let selectedNodeID else { return nil }
        return nodesByID[selectedNodeID]
    }

    var assemblyName: String? {
        assemblyPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Tree after applying the search filter and the "hide compiler generated" toggle.
    /// Cached: rebuilding a 20k node tree on every view update was the main source of UI lag.
    var filteredTree: AssemblyNode? {
        guard let tree else { return nil }
        let key = "\(treeRevision)|\(settings.hideSynthetic)|\(settings.hideCompilerGenerated)|\(searchText)"
        if key == cachedTreeKey, let cachedTree { return cachedTree }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let result = filter(tree, query: query)
        cachedTree = result
        cachedTreeKey = key
        return result
    }

    // MARK: - tree expansion

    /// Children for the outline view. Metadata list groups and referenced assemblies are fetched
    /// the first time they are expanded; failures become a visible placeholder row instead of silence.
    func fetchChildren(of node: AssemblyNode) async -> [AssemblyNode] {
        if let children = node.children, !children.isEmpty { return children }

        // Item nodes inside the reference list carry group == "references" too, so they must be
        // handled before the generic metadata-group branch.
        if node.kind == "assemblyref", node.expandable == true, let index = node.index {
            if let cached = referencedChildren[index] { return cached }
            do {
                let result = try await client.call("assembly", ["index": index], as: GroupChildrenResult.self)
                referencedChildren[index] = result.children
                return result.children
            } catch {
                return [Self.placeholder("无法加载：" + error.localizedDescription)]
            }
        }

        // Only container nodes load a group's children; items inside those lists are leaves.
        if node.kind == "group", let group = node.group, Self.listGroups.contains(group) {
            if let cached = groupChildren[group] { return cached }
            do {
                let result = try await client.call("children", ["group": group], as: GroupChildrenResult.self)
                groupChildren[group] = result.children
                return result.children
            } catch {
                return [Self.placeholder("读取失败：" + error.localizedDescription)]
            }
        }

        return node.children ?? []
    }

    /// The document shown when the opened file is not a managed assembly.
    private func failureDocument(for node: AssemblyNode) -> String {
        var lines: [String] = []
        lines.append("// " + L.t("failure.title"))
        lines.append("// " + String(repeating: "─", count: 60))
        lines.append("")
        lines.append(L.t("failure.file") + "     : " + (assemblyPath ?? node.name))
        if let failure = failedFile {
            lines.append(L.t("failure.kind") + "     : " + L.t("kind." + failure.kind))
            lines.append(L.t("failure.size") + "     : " + ByteCountFormatter.string(fromByteCount: Int64(failure.size), countStyle: .file))
            lines.append(L.t("failure.magic") + "    : 0x" + failure.magic)
            if failure.machine != "-" { lines.append(L.t("failure.machine") + "  : " + failure.machine) }
            lines.append(L.t("failure.clr") + "      : " + (failure.hasClrHeader ? L.t("failure.yes") : L.t("failure.no")))
            lines.append("")
            lines.append(L.t("failure.reason") + "   : " + failure.reason)
        }
        lines.append("")
        lines.append("// " + L.t("failure.hint"))
        return lines.joined(separator: "\n")
    }

    private static func placeholder(_ message: String) -> AssemblyNode {
        AssemblyNode(kind: "error", name: message, token: nil, detail: nil, path: nil,
                     compilerGenerated: nil, synthetic: nil, children: [], group: nil, index: nil,
                     ref: nil, expandable: nil, tokenLabel: nil, nameKey: nil, nameIndex: nil,
                     nameSuffix: nil, count: nil, typeCount: nil)
    }

    // MARK: - expansion (delegated to the outline view, which owns the expansion state)

    func requestExpansion(_ command: ExpansionCommand) {
        expansionHandler?(command)
    }

    func expandRootOnly() { requestExpansion(.rootOnly) }

    /// Expands a single node (used by the screenshot scripts).
    func expandNode(_ id: String) {
        expandedIDs.insert(id)
        requestExpansion(.node(id))
    }
    func expandToTypeLevel() { requestExpansion(.defaultLevels) }
    func expandAll() { requestExpansion(.all) }
    func collapseAll() { requestExpansion(.none) }

    // MARK: - commands

    func open(url: URL) async {
        let name = url.lastPathComponent
        await run(L.t("status.opening", name)) {
            let result = try await self.client.call("open", ["path": url.path], as: OpenResult.self)
            self.failedFile = result.failure
            self.apply(tree: result.tree, path: result.path, resetExpansion: true)
            if result.failed == true {
                self.status = L.t("status.failedOpen", name)
                self.selectedNodeID = result.tree.id
                await self.loadSelected()   // refresh even when the id did not change
            } else {
                self.status = L.t("status.opened", name)
            }
        }
    }

    /// Removes the currently open assembly (dnSpy's "Remove Assembly" on the root node).
    func closeAssembly() async {
        guard assemblyPath != nil else { return }
        _ = try? await client.call("close", [:], as: CloseResult.self)
        reset()
        status = L.t("status.closed")
    }

    private func reset() {
        tree = nil
        assemblyPath = nil
        failedFile = nil
        code = ""
        codeNote = nil
        il = nil
        selectedNodeID = nil
        nodesByID = [:]
        expandedIDs = []
        groupChildren = [:]
        referencedChildren = [:]
        metadataCache.removeAll()
        codeCache.removeAll()
        ilCache.removeAll()
        treeRevision += 1
        cachedTree = nil
        cachedTreeKey = ""
        isDirty = false
    }

    func reload() async {
        guard assemblyPath != nil else { return }
        let keepSelection = selectedNodeID
        await run("正在重新加载") {
            let result = try await self.client.call("reload", [:], as: OpenResult.self)
            self.failedFile = result.failure
            self.apply(tree: result.tree, path: result.path)
            self.selectedNodeID = keepSelection
            self.status = L.t("status.reloaded")
        }
    }

    func loadSelected() async {
        guard let node = selectedNode else {
            code = ""
            codeNote = nil
            il = nil
            busyMessage = nil
            return
        }

        if node.kind == "error" {
            code = failureDocument(for: node)
            codeNote = nil
            il = nil
            return
        }

        // Metadata nodes must be handled before the token check: PE / reference / resource rows and
        // the assembly and module rows have no metadata token but still show a document.
        let metadataGroup = node.group ?? ((node.kind == "assembly" || node.kind == "module") ? "assemblyinfo" : nil)
        if let group = metadataGroup {
            // Metadata nodes (PE headers, reference tables, resources) render a text report.
            if let cached = metadataCache[node.id] {
                code = cached
                codeNote = nil
                il = nil
                return
            }
            isBusy = true
            busyMessage = L.t("status.readingMeta", node.name)
            defer {
                isBusy = false
                busyMessage = nil
            }
            do {
                var params: [String: Any] = ["group": group]
                if let index = node.index { params["index"] = index }
                let result = try await client.call("metadata", params, as: MetadataResult.self)
                if Task.isCancelled { return }
                metadataCache[node.id] = result.text
                code = result.text
                codeNote = nil
                il = nil
            } catch {
                if Task.isCancelled { return }
                errorMessage = error.localizedDescription
            }
            return
        }

        guard let token = node.token else {
            code = ""
            codeNote = nil
            il = nil
            busyMessage = nil
            return
        }

        let wantsIl = viewMode == .il && node.isMethod

        // Re-selecting a node that was already loaded is instant.
        if wantsIl, let cached = ilCache[token] {
            il = cached
            code = cached.text
            codeNote = cached.editable == false ? "该方法没有方法体（abstract / extern / pinvoke）" : nil
            return
        }
        if !wantsIl, let cached = codeCache[token] {
            code = cached.text
            codeNote = cached.note
            il = nil
            return
        }

        // Short debounce so scrubbing the outline with the arrow keys does not fire one RPC per row.
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }

        isBusy = true
        // A long decompilation started for the previous selection must not delay this one.
        if isBusy { client.cancelInFlight() }

        isBusy = true
        busyMessage = wantsIl ? L.t("status.readingIl", node.name) : L.t("status.decompiling", node.name)
        codeNote = nil
        defer {
            isBusy = false
            busyMessage = nil
        }

        var request: [String: Any] = ["token": token]
        if let reference = node.ref { request["ref"] = reference }

        do {
            if wantsIl {
                let result = try await client.call("il", request, as: IlResult.self)
                if Task.isCancelled { return }
                ilCache[token] = result
                il = result
                code = result.text
                codeNote = result.editable == false ? "该方法没有方法体（abstract / extern / pinvoke）" : nil
            } else {
                let result = try await client.call("decompile", request, as: CodeResult.self)
                if Task.isCancelled { return }
                codeCache[token] = result
                code = result.text
                codeNote = result.note
                il = nil
            }
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            if case HelperError.rpc(let message) = error, message == "cancelled" { return }
            errorMessage = error.localizedDescription
        }
    }

    func save(to url: URL?) async {
        guard assemblyPath != nil else { return }
        var params: [String: Any] = [:]
        if let url { params["path"] = url.path }
        await run(L.t("status.saving")) {
            let result = try await self.client.call("save", params, as: SaveResult.self)
            let selection = self.selectedNodeID
            self.apply(tree: result.tree, path: result.path)
            if let selection, self.nodesByID[selection] != nil {
                self.selectedNodeID = selection
            }
            self.status = result.renumbered == true
                ? L.t("status.savedRenumbered", result.path)
                : L.t("status.saved", result.path)
            self.isDirty = false
            await self.loadSelected()
        }
    }

    // MARK: - type / member edits

    func addField(typeToken: String, name: String, fieldType: String, isStatic: Bool, isPublic: Bool) async {
        await structureEdit("addField", [
            "typeToken": typeToken,
            "name": name,
            "fieldType": fieldType,
            "isStatic": isStatic,
            "isPublic": isPublic
        ])
    }

    func addMethod(typeToken: String, name: String, returnType: String, parameters: [String],
                   isStatic: Bool, isPublic: Bool, bodyKind: String, constant: String?) async {
        var params: [String: Any] = [
            "typeToken": typeToken,
            "name": name,
            "returnType": returnType,
            "parameters": parameters,
            "isStatic": isStatic,
            "isPublic": isPublic,
            "bodyKind": bodyKind
        ]
        if let constant, !constant.isEmpty { params["constant"] = constant }
        await structureEdit("addMethod", params)
    }

    func addType(namespace: String, name: String, kind: String, baseType: String, isPublic: Bool) async {
        var params: [String: Any] = ["namespace": namespace, "name": name, "kind": kind, "isPublic": isPublic]
        if !baseType.isEmpty { params["baseType"] = baseType }
        await structureEdit("addType", params)
    }

    func remove(token: String, isType: Bool) async {
        guard selectedNode?.isReference != true else {
            errorMessage = L.t("error.readOnlyReference")
            return
        }
        await structureEdit(isType ? "removeType" : "removeMember", ["token": token])
    }

    private func structureEdit(_ command: String, _ params: [String: Any]) async {
        await run(nil) {
            let result = try await self.client.call(command, params, as: StructureResult.self)
            let selection = self.selectedNodeID
            self.apply(tree: result.tree, path: self.assemblyPath ?? "")
            // tokens are stable for additions, but deletions renumber the table, so re-select defensively
            if let selection, self.nodesByID[selection] != nil {
                self.selectedNodeID = selection
            } else {
                self.selectedNodeID = nil
            }
            self.isDirty = true
            self.status = L.t("status.modified", result.text)
            await self.loadSelected()
        }
    }

    // MARK: - IL edits

    func setConstant(offset: Int, value: String, isString: Bool) async {
        guard let token = selectedNode?.token else { return }
        let payload: Any = isString ? value : (Int(value) ?? 0)
        await applyEdit("setConstant", [
            "token": token,
            "offset": offset,
            "value": payload
        ])
    }

    func replaceInstruction(offset: Int, opcode: String, operand: String) async {
        guard let token = selectedNode?.token else { return }
        var params: [String: Any] = ["token": token, "offset": offset, "opcode": opcode]
        if let value = operandPayload(opcode: opcode, text: operand) { params["operand"] = value }
        await applyEdit("replaceInstruction", params)
    }

    func insertInstruction(beforeOffset: Int?, opcode: String, operand: String) async {
        guard let token = selectedNode?.token else { return }
        var params: [String: Any] = [
            "token": token,
            "beforeOffset": beforeOffset ?? -1,
            "opcode": opcode
        ]
        if let value = operandPayload(opcode: opcode, text: operand) { params["operand"] = value }
        await applyEdit("insertInstruction", params)
    }

    func removeInstruction(offset: Int) async {
        guard let token = selectedNode?.token else { return }
        await applyEdit("removeInstruction", ["token": token, "offset": offset])
    }

    private func applyEdit(_ command: String, _ params: [String: Any]) async {
        await run(nil) {
            let result = try await self.client.call(command, params, as: TextResult.self)
            self.isDirty = true
            self.status = "已修改：\(result.text)（尚未保存）"
            await self.loadSelected()
        }
    }

    /// The helper decides the operand kind from the opcode, so numbers must arrive as numbers.
    private func operandPayload(opcode: String, text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if opcode == "ldstr" { return trimmed }
        if let integer = Int(trimmed) { return integer }
        if let double = Double(trimmed) { return double }
        return trimmed
    }

    // MARK: - helpers

    private func apply(tree: AssemblyNode, path: String, resetExpansion: Bool = false) {
        self.tree = tree
        self.assemblyPath = path
        nodesByID = [:]
        index(tree)
        treeRevision += 1
        cachedTree = nil
        cachedTreeKey = ""
        codeCache.removeAll()
        ilCache.removeAll()
        metadataCache.removeAll()
        groupChildren.removeAll()
        referencedChildren.removeAll()

        if let selectedNodeID, nodesByID[selectedNodeID] == nil {
            self.selectedNodeID = nil
        }
        if resetExpansion {
            expandedIDs = []
        } else {
            expandedIDs = expandedIDs.filter { nodesByID[$0] != nil }
        }
    }

    private func index(_ node: AssemblyNode) {
        nodesByID[node.id] = node
        for child in node.children ?? [] { index(child) }
    }

    private func filter(_ node: AssemblyNode, query: String) -> AssemblyNode? {
        // Name-synthetic nodes (<>c, backing fields) and optionally attribute-marked ones.
        if settings.hideSynthetic, node.synthetic == true { return nil }
        if settings.hideCompilerGenerated, node.compilerGenerated == true { return nil }

        var children: [AssemblyNode] = []
        for child in node.children ?? [] {
            if let kept = filter(child, query: query) { children.append(kept) }
        }

        let selfMatches = query.isEmpty || node.name.lowercased().contains(query)
        if !selfMatches && children.isEmpty { return nil }

        return AssemblyNode(
            kind: node.kind,
            name: node.name,
            token: node.token,
            detail: node.detail,
            path: node.path,
            compilerGenerated: node.compilerGenerated,
            synthetic: node.synthetic,
            children: children,
            group: node.group,
            index: node.index,
            ref: node.ref,
            expandable: node.expandable,
            tokenLabel: node.tokenLabel,
            nameKey: node.nameKey,
            nameIndex: node.nameIndex,
            nameSuffix: node.nameSuffix,
            count: node.count,
            typeCount: node.typeCount
        )
    }

    private func run(_ busyMessage: String?, _ body: @escaping () async throws -> Void) async {
        if let busyMessage { status = busyMessage }
        isBusy = true
        defer { isBusy = false }
        do {
            try await body()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
