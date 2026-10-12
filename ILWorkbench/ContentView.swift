import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var isOpenPanelPresented = false
    @State private var editMode: IlEditMode?
    @State private var structureEdit: StructureEditMode?
    @State private var didLoadStartupAssembly = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, structureEdit: $structureEdit)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 560)
        } detail: {
            DetailView(model: model, editMode: $editMode)
        }
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $isOpenPanelPresented, allowedContentTypes: assemblyContentTypes) { result in
            switch result {
            case .success(let url):
                Task { await model.open(url: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $editMode) { mode in
            IlEditSheet(mode: mode, model: model)
        }
        .sheet(item: $structureEdit) { mode in
            StructureEditSheet(mode: mode, model: model)
        }
        .onOpenURL { url in
            Task { await model.open(url: url) }
        }
        // Dropping a file onto the window opens it (any file: unreadable ones become error nodes).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await model.open(url: url) }
            }
            return true
        }
        .task {
            guard !didLoadStartupAssembly, let path = LaunchOptions.startupAssembly else { return }
            didLoadStartupAssembly = true
            await model.open(url: URL(fileURLWithPath: path))
        }
        .frame(minWidth: 940, minHeight: 620)
    }

    private var assemblyContentTypes: [UTType] {
        var types: [UTType] = []
        if let dll = UTType(filenameExtension: "dll") { types.append(dll) }
        if let exe = UTType(filenameExtension: "exe") { types.append(exe) }
        types.append(.data)
        return types
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                isOpenPanelPresented = true
            } label: {
                Label(L.t("toolbar.open"), systemImage: "folder")
            }
            .help(L.t("toolbar.openHelp"))

            Button {
                Task { await model.reload() }
            } label: {
                Label(L.t("toolbar.reload"), systemImage: "arrow.clockwise")
            }
            .disabled(model.assemblyPath == nil)
            .help(L.t("toolbar.reloadHelp"))
        }

        ToolbarItemGroup {
            Button {
                Task { await model.save(to: nil) }
            } label: {
                Label(L.t("toolbar.save"), systemImage: "square.and.arrow.down")
            }
            .disabled(model.assemblyPath == nil || !model.isDirty)
            .help(L.t("toolbar.saveHelp"))

            Button {
                saveAs()
            } label: {
                Label(L.t("toolbar.saveAs"), systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(model.assemblyPath == nil)
            .help(L.t("toolbar.saveAsHelp"))

            Menu {
                Button(L.t("menu.addField")) { structureEdit = .addField(selectedType) }
                    .disabled(selectedType == nil)
                Button(L.t("menu.addMethod")) { structureEdit = .addMethod(selectedType) }
                    .disabled(selectedType == nil)
                Button(L.t("menu.addType")) { structureEdit = .addType(selectedNamespaceName) }
                Divider()
                Button(L.t("menu.deleteSelected"), role: .destructive) {
                    guard let node = model.selectedNode, let token = node.token else { return }
                    Task { await model.remove(token: token, isType: node.kind == "type") }
                }
                .disabled(model.selectedNode?.token == nil || model.selectedNode?.kind == "assembly")
            } label: {
                Label(L.t("menu.structure"), systemImage: "plus.square.on.square")
            }
            .disabled(model.assemblyPath == nil
                      || model.selectedNode?.isReference == true
                      || !settings.allowEditing)

            Menu {
                Button(L.t("menu.expandRoot")) { model.expandRootOnly() }
                Button(L.t("menu.expandToTypes")) { model.expandToTypeLevel() }
                Button(L.t("menu.expandAll")) { model.expandAll() }
                Button(L.t("menu.collapseAll")) { model.collapseAll() }
                Divider()
                Toggle(L.t("menu.hideSynthetic"), isOn: $settings.hideSynthetic)
                Toggle(L.t("menu.hideCompilerGenerated"), isOn: $settings.hideCompilerGenerated)
                Toggle(L.t("menu.showSignature"), isOn: $settings.showSignature)
                Toggle(L.t("menu.showToken"), isOn: $settings.showToken)
            } label: {
                Label(L.t("menu.viewOptions"), systemImage: "eye")
            }
        }
    }

    private var selectedType: AssemblyNode? {
        guard let node = model.selectedNode, node.kind == "type", node.token != nil else { return nil }
        return node
    }

    private var assemblyNode: AssemblyNode? {
        guard let tree = model.tree else { return nil }
        return tree
    }

    private var selectedNamespaceName: String {
        guard let node = model.selectedNode, node.kind == "namespace" else { return "" }
        return node.name == "<global>" ? "" : node.name
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.title = L.t("menu.saveAs")
        panel.canCreateDirectories = true
        if let name = model.assemblyName {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            panel.nameFieldStringValue = ext.isEmpty ? base + ".patched" : base + ".patched." + ext
        }
        panel.allowedContentTypes = assemblyContentTypes
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.save(to: url) }
        }
    }
}

// MARK: - sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @Binding var structureEdit: StructureEditMode?

    /// Changes whenever the visible tree changes; the outline view reloads only then.
    private var token: String {
        "\(model.treeRevision)|\(settings.hideSynthetic)|\(settings.hideCompilerGenerated)|\(settings.showSignature)|\(settings.showToken)|\(model.searchText)"
    }

    var body: some View {
        Group {
            if model.filteredTree != nil {
                AssemblyOutlineView(model: model, token: token) { action, node in
                    switch action {
                    case .removeAssembly:
                        Task { await model.closeAssembly() }
                    case .addField: structureEdit = .addField(node)
                    case .addMethod: structureEdit = .addMethod(node)
                    case .addType: structureEdit = .addType(node.name == "<global>" || node.name == "{}" ? "" : node.name)
                    case .removeType:
                        if let token = node.token { Task { await model.remove(token: token, isType: true) } }
                    case .removeMember:
                        if let token = node.token { Task { await model.remove(token: token, isType: false) } }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text(model.assemblyPath == nil ? L.t("sidebar.empty.title") : L.t("sidebar.noMatch"))
                        .foregroundStyle(.secondary)
                    if model.assemblyPath == nil {
                        Text(L.t("sidebar.empty.hint"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: L.t("sidebar.search.prompt"))
    }
}

// MARK: - detail

struct DetailView: View {
    @ObservedObject var model: AppModel
    @Binding var editMode: IlEditMode?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let node = model.selectedNode {
                Image(systemName: node.symbolName).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayTitle).font(.headline).lineLimit(1)
                    Text([node.kindLabel, node.displayDetail, node.token].compactMap { $0 }.joined(separator: "   ·   "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(model.assemblyPath == nil ? L.t("detail.pick") : L.t("detail.pickNode"))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.assemblyPath != nil {
                Picker("", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.busyMessage {
            VStack(spacing: 10) {
                ProgressView()
                Text(message).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.viewMode == .il, let il = model.il, model.selectedNode?.isMethod == true {
            IlEditorView(il: il, model: model, editMode: $editMode)
        } else if model.viewMode == .il, model.selectedNode?.isMethod != true {
            // IL is per method: say so instead of silently keeping the C# pane visible.
            VStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(model.selectedNode == nil
                     ? L.t("detail.ilNeedsMethod.title")
                     : L.t("detail.ilHasNoBody", model.selectedNode!.displayTitle))
                    .foregroundStyle(.secondary)
                Text(L.t("detail.ilNeedsMethod.body"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.code.isEmpty {
            VStack(spacing: 6) {
                if model.isBusy {
                    ProgressView()
                } else {
                    Text(L.t("detail.empty")).foregroundStyle(.secondary)
                    if let note = model.codeNote {
                        Text(note).font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CodeTextView(text: model.code, language: model.codeLanguage)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(model.errorMessage ?? model.status)
                .font(.system(size: 11))
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(1)
            Spacer()
            Text(model.viewMode == .il ? L.t("detail.view.il") : L.t("detail.view.csharp"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            if model.isDirty {
                Text(L.t("detail.unsaved"))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - IL instruction editor

struct IlEditorView: View {
    let il: IlResult
    @ObservedObject var model: AppModel
    @Binding var editMode: IlEditMode?
    @State private var selectedOffset: Int?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SyntaxTheme { SyntaxTheme.forScheme(colorScheme) }

    /// Token colour for an IL operand, matching what the text view would use.
    private func operandColour(_ operand: String) -> Color {
        if operand.hasPrefix("\"") { return Color(nsColor: theme.string) }
        if let first = operand.first, first.isNumber || first == "-" { return Color(nsColor: theme.number) }
        return Color(nsColor: theme.member)
    }

    private var selected: IlInstruction? {
        (il.instructions ?? []).first { $0.offset == selectedOffset }
    }

    var body: some View {
        VStack(spacing: 0) {
            if (il.instructions ?? []).isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.alignleft").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(L.t("detail.noInstructions.title"))
                        .foregroundStyle(.secondary)
                    Text(il.note ?? L.t("detail.noInstructions.body"))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List(selection: $selectedOffset) {
                ForEach(il.instructions ?? []) { instruction in
                    HStack(spacing: 10) {
                        Text(String(format: "IL_%04X", instruction.offset))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(nsColor: theme.offset))
                        Text(instruction.opcode)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(nsColor: theme.opcode))
                        if let operand = instruction.operand {
                            Text(operand)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(operandColour(operand))
                                .textSelection(.enabled)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .tag(instruction.offset)
                }
            }
            .listStyle(.plain)

            Divider()

            HStack(spacing: 8) {
                Button(L.t("il.editConstant")) {
                    if let selected { editMode = .constant(selected) }
                }
                .disabled(selected?.isEditableConstant != true || model.selectedNode?.isReference == true)

                Button(L.t("il.replace")) {
                    if let selected { editMode = .replace(selected) }
                }
                .disabled(selected == nil || model.selectedNode?.isReference == true)

                Button(L.t("il.insertBefore")) {
                    if let selected { editMode = .insertBefore(selected) }
                }
                .disabled(selected == nil || model.selectedNode?.isReference == true)

                Button(L.t("il.append")) {
                    editMode = .appendAtEnd
                }
                .disabled(model.selectedNode?.isReference == true)

                Button(L.t("il.delete")) {
                    if let selected {
                        Task { await model.removeInstruction(offset: selected.offset) }
                    }
                }
                .disabled(selected == nil || model.selectedNode?.isReference == true)

                Spacer()

                Text(L.t("il.footer", il.maxStack ?? 0, il.exceptionHandlers ?? 0))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            }
        }
    }
}

struct IlEditSheet: View {
    let mode: IlEditMode
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var opcode: String
    @State private var operand: String

    init(mode: IlEditMode, model: AppModel) {
        self.mode = mode
        self.model = model
        _opcode = State(initialValue: mode.target?.opcode ?? "nop")
        _operand = State(initialValue: mode.isConstant ? (mode.target?.editableValue ?? "") : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.headline)

            if mode.isConstant {
                Text(L.t("il.sheet.newValue")).font(.footnote).foregroundStyle(.secondary)
                TextField(L.t("il.sheet.newValue"), text: $operand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text(L.t("il.sheet.opcode")).gridColumnAlignment(.trailing)
                        TextField(L.t("il.sheet.opcodeHint"), text: $opcode)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    GridRow {
                        Text(L.t("il.sheet.operand")).gridColumnAlignment(.trailing)
                        TextField(L.t("il.sheet.operandHint"), text: $operand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                Text(L.t("il.sheet.help"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L.t("common.cancel")) { dismiss() }
                Button(L.t("common.apply")) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!mode.isConstant && opcode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func apply() {
        switch mode {
        case .constant(let instruction):
            Task { await model.setConstant(offset: instruction.offset, value: operand, isString: instruction.isStringConstant) }
        case .replace(let instruction):
            Task { await model.replaceInstruction(offset: instruction.offset, opcode: opcode, operand: operand) }
        case .insertBefore(let instruction):
            Task { await model.insertInstruction(beforeOffset: instruction.offset, opcode: opcode, operand: operand) }
        case .appendAtEnd:
            Task { await model.insertInstruction(beforeOffset: nil, opcode: opcode, operand: operand) }
        }
        dismiss()
    }
}


// MARK: - structure editing (add/remove types, fields, methods)

enum StructureEditMode: Identifiable {
    case addField(AssemblyNode?)
    case addMethod(AssemblyNode?)
    case addType(String)

    var id: String {
        switch self {
        case .addField(let node): return "addField-\(node?.id ?? "none")"
        case .addMethod(let node): return "addMethod-\(node?.id ?? "none")"
        case .addType(let namespace): return "addType-\(namespace)"
        }
    }

    var title: String {
        switch self {
        case .addField(let node): return L.t("structure.field.title", node?.name ?? "?")
        case .addMethod(let node): return L.t("structure.method.title", node?.name ?? "?")
        case .addType(let namespace): return namespace.isEmpty ? L.t("structure.type.title") : L.t("structure.type.titleNs", namespace)
        }
    }

    var targetType: AssemblyNode? {
        switch self {
        case .addField(let node), .addMethod(let node): return node
        case .addType: return nil
        }
    }
}

struct StructureEditSheet: View {
    let mode: StructureEditMode
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var fieldType = "System.Int32"
    @State private var returnType = "System.Void"
    @State private var parameters = ""
    @State private var isStatic = true
    @State private var isPublic = true
    @State private var bodyKind = "default"
    @State private var constant = ""
    @State private var kind = "class"
    @State private var baseType = ""
    @State private var namespace = ""

    init(mode: StructureEditMode, model: AppModel) {
        self.mode = mode
        self.model = model
        if case .addType(let existing) = mode {
            _namespace = State(initialValue: existing)
        }
        if case .addMethod = mode {
            _bodyKind = State(initialValue: "constant")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(L.t("structure.name")).gridColumnAlignment(.trailing)
                    TextField("新成员名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                switch mode {
                case .addField:
                    GridRow {
                        Text(L.t("structure.fieldType")).gridColumnAlignment(.trailing)
                        TextField("System.Int32", text: $fieldType)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                case .addMethod:
                    GridRow {
                        Text(L.t("structure.returnType")).gridColumnAlignment(.trailing)
                        TextField("System.Void", text: $returnType)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    GridRow {
                        Text(L.t("structure.parameters")).gridColumnAlignment(.trailing)
                        TextField("System.Int32 a, System.String b", text: $parameters)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    GridRow {
                        Text(L.t("structure.body")).gridColumnAlignment(.trailing)
                        Picker("", selection: $bodyKind) {
                            Text(L.t("structure.bodyDefault")).tag("default")
                            Text(L.t("structure.bodyConstant")).tag("constant")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if bodyKind == "constant" {
                        GridRow {
                            Text(L.t("structure.constant")).gridColumnAlignment(.trailing)
                            TextField("例如 42 或一段文本", text: $constant)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                case .addType:
                    GridRow {
                        Text(L.t("structure.namespace")).gridColumnAlignment(.trailing)
                        TextField("留空表示全局命名空间", text: $namespace)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    GridRow {
                        Text(L.t("structure.kind")).gridColumnAlignment(.trailing)
                        Picker("", selection: $kind) {
                            Text(L.t("structure.kindClass")).tag("class")
                            Text(L.t("structure.kindInterface")).tag("interface")
                            Text(L.t("structure.kindStruct")).tag("struct")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if kind == "class" {
                        GridRow {
                            Text(L.t("structure.baseType")).gridColumnAlignment(.trailing)
                            TextField("留空表示 System.Object", text: $baseType)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }

            Toggle(L.t("structure.static"), isOn: $isStatic)
                .disabled(isStaticUnavailable)
            Toggle(L.t("structure.public"), isOn: $isPublic)

            Text(hint)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(L.t("common.add")) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 540)
    }

    private var isStaticUnavailable: Bool {
        if case .addType = mode { return true }
        if case .addField = mode { return false }
        if case .addMethod = mode { return false }
        return true
    }

    private var hint: String {
        switch mode {
        case .addField:
            return L.t("structure.hint.field")
        case .addMethod:
            return L.t("structure.hint.method")
        case .addType:
            return L.t("structure.hint.type")
        }
    }

    private func apply() {
        let parameterTypes = parameters
            .split(separator: ",")
            .map { part -> String in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                return String(trimmed.split(separator: " ").first ?? "")
            }
            .filter { !$0.isEmpty }

        switch mode {
        case .addField(let type):
            Task {
                await model.addField(typeToken: type?.token ?? "", name: name, fieldType: fieldType,
                                     isStatic: isStatic, isPublic: isPublic)
            }
        case .addMethod(let type):
            Task {
                await model.addMethod(typeToken: type?.token ?? "", name: name, returnType: returnType,
                                      parameters: parameterTypes, isStatic: isStatic, isPublic: isPublic,
                                      bodyKind: bodyKind, constant: bodyKind == "constant" ? constant : nil)
            }
        case .addType:
            Task {
                await model.addType(namespace: namespace, name: name, kind: kind,
                                    baseType: baseType, isPublic: isPublic)
            }
        }
        dismiss()
    }
}
