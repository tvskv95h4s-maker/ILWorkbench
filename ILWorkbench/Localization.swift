import AppKit
import Foundation
import SwiftUI

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L.t("settings.theme.system")
        case .light: return L.t("settings.theme.light")
        case .dark: return L.t("settings.theme.dark")
        }
    }
}

enum Language: String, CaseIterable, Identifiable {
    case chinese = "zh"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

/// Tiny string table. Keys are stable identifiers; every user visible string goes through `L.t`.
enum L {
    nonisolated(unsafe) static var language: Language = .chinese

    static func t(_ key: String) -> String {
        let table = language == .chinese ? zh : en
        return table[key] ?? en[key] ?? key
    }

    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    private static let zh: [String: String] = [
        // menu bar
        "menu.file": "文件",
        "menu.open": "打开…",
        "menu.reload": "重新加载",
        "menu.save": "保存",
        "menu.saveAs": "另存为…",
        "menu.removeAssembly": "移除程序集",
        "menu.view": "视图",
        "menu.expandRoot": "只展开根节点",
        "menu.expandToTypes": "展开到类名",
        "menu.expandAll": "全部展开",
        "menu.collapseAll": "全部折叠",
        "menu.hideSynthetic": "隐藏合成成员（<>c、后备字段等）",
        "menu.hideCompilerGenerated": "隐藏 [CompilerGenerated] 类型/成员",
        "menu.showSignature": "显示成员签名",
        "menu.showToken": "显示 metadata token",
        "menu.settings": "设置…",
        "menu.structure": "结构编辑",
        "menu.addField": "添加字段…",
        "menu.addMethod": "添加方法…",
        "menu.addType": "添加类型…",
        "menu.deleteSelected": "删除选中项",
        "menu.deleteType": "删除类型",
        "menu.deleteMember": "删除成员",
        "menu.referenceReadOnly": "引用程序集（只读）",
        "menu.viewOptions": "视图选项",
        // toolbar
        "toolbar.open": "打开",
        "toolbar.openHelp": "打开 .NET 程序集（.dll / .exe）",
        "toolbar.reload": "重新加载",
        "toolbar.reloadHelp": "丢弃未保存的修改并重新读取文件",
        "toolbar.save": "保存",
        "toolbar.saveHelp": "写回原文件",
        "toolbar.saveAs": "另存为",
        "toolbar.saveAsHelp": "保存为新的程序集文件",
        // sidebar / detail
        "sidebar.empty.title": "尚未打开程序集",
        "sidebar.empty.hint": "用工具栏的「打开」选择 .dll / .exe，或把文件拖进来",
        "sidebar.search.prompt": "搜索命名空间 / 类型 / 方法 / 字段",
        "sidebar.noMatch": "没有匹配的成员",
        "detail.pick": "打开一个程序集开始",
        "detail.pickNode": "在左侧选择类型或成员",
        "detail.empty": "没有可显示的内容",
        "detail.ilNeedsMethod.title": "IL 视图需要先选中一个方法",
        "detail.ilNeedsMethod.body": "IL 是按方法显示的：在左侧展开类型，选中具体方法即可看到指令；\n类型、字段、属性、事件本身没有方法体。",
        "detail.ilHasNoBody": "「%@」没有 IL 指令流",
        "detail.noInstructions.title": "这个方法没有 IL 指令",
        "detail.noInstructions.body": "抽象方法 / extern / PInvoke 方法在 metadata 里没有方法体。",
        "detail.view.csharp": "C# 视图",
        "detail.view.il": "IL 视图",
        "detail.unsaved": "● 有未保存的修改",
        // IL editor
        "il.editConstant": "编辑常量…",
        "il.replace": "替换…",
        "il.insertBefore": "之前插入…",
        "il.append": "末尾追加…",
        "il.delete": "删除",
        "il.footer": "maxStack %d · 异常处理 %d 处",
        "il.sheet.opcode": "指令",
        "il.sheet.operand": "操作数",
        "il.sheet.newValue": "把常量替换为：",
        "il.sheet.opcodeHint": "opcode，例如 nop / ldstr / call",
        "il.sheet.operandHint": "可选：字符串、数字、分支目标偏移或成员全名",
        "il.sheet.help": "操作数留空表示无操作数；分支目标填 IL 偏移（如 78）；成员引用填 dnlib 全名。",
        "il.constant.title": "编辑常量 IL_%@",
        "il.replace.title": "替换指令 IL_%@",
        "il.insert.title": "在 IL_%@ 之前插入",
        "il.append.title": "在方法末尾追加指令",
        // structure editing
        "structure.field.title": "在 %@ 上添加字段",
        "structure.method.title": "在 %@ 上添加方法",
        "structure.type.title": "添加类型",
        "structure.type.titleNs": "在 %@ 中添加类型",
        "structure.name": "名称",
        "structure.fieldType": "字段类型",
        "structure.returnType": "返回类型",
        "structure.parameters": "参数",
        "structure.body": "方法体",
        "structure.bodyDefault": "返回默认值",
        "structure.bodyConstant": "返回常量",
        "structure.constant": "常量",
        "structure.namespace": "命名空间",
        "structure.kind": "种类",
        "structure.kindClass": "类",
        "structure.kindInterface": "接口",
        "structure.kindStruct": "结构体",
        "structure.baseType": "基类",
        "structure.static": "static",
        "structure.public": "public（否则 private / internal）",
        "structure.hint.field": "会生成一个无初始值的字段（static 字段默认值为 0/null）。",
        "structure.hint.method": "方法体会写成「返回常量」或「返回默认值」，保证是合法 IL；之后可在 IL 视图里继续改。",
        "structure.hint.type": "新类型会加到程序集末尾；添加后可以先选中它再添加成员。",
        "common.cancel": "取消",
        "common.ok": "确定",
        "common.apply": "应用",
        "common.add": "添加",
        // status
        "status.opening": "正在打开 %@",
        "status.opened": "已打开 %@",
        "status.reloading": "正在重新加载",
        "status.reloaded": "已重新加载",
        "status.saving": "正在保存",
        "status.saved": "已保存到 %@",
        "status.savedRenumbered": "已保存到 %@（删除过成员，metadata token 已重新编号）",
        "status.modified": "已修改：%@（尚未保存）",
        "status.decompiling": "正在反编译 %@…",
        "status.readingIl": "正在读取 %@ 的 IL…",
        "status.readingMeta": "正在读取 %@…",
        "status.closed": "已移除程序集",
        "status.ready": "打开一个 .NET 程序集（.dll / .exe）开始",
        "status.failedOpen": "%@ 不是受管的 .NET 程序集",
        "error.readOnlyReference": "引用程序集是只读的，不能修改",
        "error.tooManyRetries": "操作失败",
        // settings window
        "settings.category.environment": "环境",
        "settings.category.environment.general": "通用设置",
        "settings.category.environment.fonts": "字体",
        "settings.category.editor": "代码编辑器",
        "settings.category.editor.csharp": "C#",
        "settings.category.editor.csharp.general": "通用设置",
        "settings.category.explorer": "程序集资源管理器",
        "settings.theme": "主题",
        "settings.theme.system": "跟随系统",
        "settings.theme.light": "浅色",
        "settings.theme.dark": "深色",
        "settings.font.family": "字体",
        "settings.font.size": "字号",
        "settings.font.preview": "预览",
        "settings.font.previewText": "public static string Secret() { return \"nested-secret-42\"; }",
        "settings.editor.highlight": "启用语法高亮",
        "settings.editor.highlightHint": "关闭后代码与 IL 以纯文本显示（超大文件更快）。",
        "settings.editor.wrap": "自动换行",
        "settings.editor.tabWidth": "Tab 宽度",
        "settings.editor.behaviour": "C# 编辑器",
        "settings.tree.showSignatureHint": "与 dnSpy 一致：默认只显示名称，完整签名放在提示气泡里。",
        "settings.title": "设置",
        "settings.general": "通用",
        "settings.language": "界面语言",
        "settings.editing": "编辑能力",
        "settings.allowEditing": "允许编辑 IL 与类型/成员",
        "settings.allowEditingHint": "关闭后只能查看：IL 编辑按钮与结构编辑菜单会被禁用，避免误改 DLL。",
        "settings.tree": "结构树显示",
        "settings.collapseHint": "展开行为可在「视图」菜单里调整。",
        "settings.about": "关于",
        "settings.version": "版本 %@",
        // failure document
        "failure.title": "无法作为 .NET 程序集打开",
        "failure.file": "文件",
        "failure.kind": "识别结果",
        "failure.reason": "原因",
        "failure.size": "大小",
        "failure.magic": "文件头",
        "failure.machine": "机器",
        "failure.clr": "CLR 头",
        "failure.yes": "有",
        "failure.no": "无",
        "failure.hint": "ILWorkbench 只能查看和编辑 .NET 程序集（托管 DLL/EXE）。原生程序集（C/C++ 等）请用反汇编工具。",
        "kind.directory": "这是一个文件夹，不是文件",
        "kind.missing": "文件不存在或无法读取",
        "kind.machO": "Mach-O 原生可执行文件 / 动态库（macOS，非 .NET）",
        "kind.elf": "ELF 原生可执行文件 / 动态库（Linux，非 .NET）",
        "kind.zip": "ZIP / 压缩包或 NuGet 包，不是程序集",
        "kind.text": "文本文件，不是程序集",
        "kind.native": "原生 Windows DLL/EXE（有 PE 头但没有 CLR 头，通常是 C/C++ 编译）",
        "kind.badPE": "PE 文件已损坏或不是有效的 PE",
        "kind.badManagedImage": "是托管程序集，但 metadata 损坏或版本不受支持",
        "kind.unknown": "无法识别的文件格式",
        // row tooltips
        "group.pe": "PE",
        "group.typerefs": "类型引用",
        "group.references": "引用",
        "group.resources": "资源",
        "group.count": "%d 个",
        "namespace.global": "{}",
        "namespace.typeCount": "%d 个类型",
        "peitem.dos": "DOS 头",
        "peitem.file": "文件头",
        "peitem.optional32": "可选头 (32 位)",
        "peitem.optional64": "可选头 (64 位)",
        "peitem.section": "节 #%d: %@",
        "peitem.cor20": "Cor20 头",
        "peitem.signature": "存储签名",
        "peitem.storageHeader": "存储标题",
        "peitem.stream": "存储流 #%d: %@",
        "kindlabel.assembly": "程序集",
        "kindlabel.module": "模块",
        "kindlabel.namespace": "命名空间",
        "kindlabel.type": "类型",
        "kindlabel.method": "方法",
        "kindlabel.field": "字段",
        "kindlabel.property": "属性",
        "kindlabel.event": "事件",
        "kindlabel.group": "元数据",
        "kindlabel.typeref": "类型引用",
        "kindlabel.assemblyref": "程序集引用",
        "kindlabel.resource": "资源",
        "kindlabel.error": "无法打开",
        "kindlabel.loading": "加载中",
        "kindlabel.peitem": "PE",
        "row.assembly": "程序集",
        "row.module": "模块",
        "row.namespace": "命名空间",
        "row.token": "metadata token",
        "row.loading": "正在加载…",
    ]

    private static let en: [String: String] = [
        "menu.file": "File",
        "menu.open": "Open…",
        "menu.reload": "Reload",
        "menu.save": "Save",
        "menu.saveAs": "Save As…",
        "menu.removeAssembly": "Remove Assembly",
        "menu.view": "View",
        "menu.expandRoot": "Expand Root Only",
        "menu.expandToTypes": "Expand to Types",
        "menu.expandAll": "Expand All",
        "menu.collapseAll": "Collapse All",
        "menu.hideSynthetic": "Hide synthetic members (<>c, backing fields, …)",
        "menu.hideCompilerGenerated": "Hide [CompilerGenerated] types/members",
        "menu.showSignature": "Show member signatures",
        "menu.showToken": "Show metadata tokens",
        "menu.settings": "Settings…",
        "menu.structure": "Structure",
        "menu.addField": "Add Field…",
        "menu.addMethod": "Add Method…",
        "menu.addType": "Add Type…",
        "menu.deleteSelected": "Delete Selection",
        "menu.deleteType": "Delete Type",
        "menu.deleteMember": "Delete Member",
        "menu.referenceReadOnly": "Referenced assembly (read-only)",
        "menu.viewOptions": "View Options",
        "toolbar.open": "Open",
        "toolbar.openHelp": "Open a .NET assembly (.dll / .exe)",
        "toolbar.reload": "Reload",
        "toolbar.reloadHelp": "Discard unsaved edits and re-read the file",
        "toolbar.save": "Save",
        "toolbar.saveHelp": "Write back to the original file",
        "toolbar.saveAs": "Save As",
        "toolbar.saveAsHelp": "Save to a new assembly file",
        "sidebar.empty.title": "No assembly open",
        "sidebar.empty.hint": "Use Open in the toolbar, or drop a file here",
        "sidebar.search.prompt": "Search namespaces / types / methods / fields",
        "sidebar.noMatch": "No matching members",
        "detail.pick": "Open an assembly to start",
        "detail.pickNode": "Select a type or member on the left",
        "detail.empty": "Nothing to show",
        "detail.ilNeedsMethod.title": "Select a method to see IL",
        "detail.ilNeedsMethod.body": "IL is per method: expand a type on the left and pick a method.\nTypes, fields, properties and events have no instruction stream.",
        "detail.ilHasNoBody": "\"%@\" has no IL instruction stream",
        "detail.noInstructions.title": "This method has no IL instructions",
        "detail.noInstructions.body": "Abstract / extern / PInvoke methods have no body in metadata.",
        "detail.view.csharp": "C# view",
        "detail.view.il": "IL view",
        "detail.unsaved": "● Unsaved changes",
        "il.editConstant": "Edit Constant…",
        "il.replace": "Replace…",
        "il.insertBefore": "Insert Before…",
        "il.append": "Append…",
        "il.delete": "Delete",
        "il.footer": "maxStack %d · %d exception handlers",
        "il.sheet.opcode": "Instruction",
        "il.sheet.operand": "Operand",
        "il.sheet.newValue": "Replace the constant with:",
        "il.sheet.opcodeHint": "opcode, e.g. nop / ldstr / call",
        "il.sheet.operandHint": "optional: string, number, branch target offset or member full name",
        "il.sheet.help": "Leave the operand empty when there is none; branch targets use the IL offset; member references use the dnlib full name.",
        "il.constant.title": "Edit constant IL_%@",
        "il.replace.title": "Replace instruction IL_%@",
        "il.insert.title": "Insert before IL_%@",
        "il.append.title": "Append instruction at end of method",
        "structure.field.title": "Add field to %@",
        "structure.method.title": "Add method to %@",
        "structure.type.title": "Add type",
        "structure.type.titleNs": "Add type to %@",
        "structure.name": "Name",
        "structure.fieldType": "Field type",
        "structure.returnType": "Return type",
        "structure.parameters": "Parameters",
        "structure.body": "Body",
        "structure.bodyDefault": "Return default",
        "structure.bodyConstant": "Return constant",
        "structure.constant": "Constant",
        "structure.namespace": "Namespace",
        "structure.kind": "Kind",
        "structure.kindClass": "Class",
        "structure.kindInterface": "Interface",
        "structure.kindStruct": "Struct",
        "structure.baseType": "Base type",
        "structure.static": "static",
        "structure.public": "public (otherwise private / internal)",
        "structure.hint.field": "Creates a field without an initial value (static fields default to 0/null).",
        "structure.hint.method": "The body is emitted as \"return constant\" or \"return default\" so it is always valid IL; refine it later in the IL view.",
        "structure.hint.type": "The new type is appended to the assembly; select it afterwards to add members.",
        "common.cancel": "Cancel",
        "common.ok": "OK",
        "common.apply": "Apply",
        "common.add": "Add",
        "status.opening": "Opening %@",
        "status.opened": "Opened %@",
        "status.reloading": "Reloading",
        "status.reloaded": "Reloaded",
        "status.saving": "Saving",
        "status.saved": "Saved to %@",
        "status.savedRenumbered": "Saved to %@ (metadata tokens were renumbered after deletions)",
        "status.modified": "Modified: %@ (not saved)",
        "status.decompiling": "Decompiling %@…",
        "status.readingIl": "Reading IL of %@…",
        "status.readingMeta": "Reading %@…",
        "status.closed": "Assembly removed",
        "status.ready": "Open a .NET assembly (.dll / .exe) to start",
        "status.failedOpen": "%@ is not a managed .NET assembly",
        "error.readOnlyReference": "Referenced assemblies are read-only",
        "error.tooManyRetries": "The operation failed",
        "settings.category.environment": "Environment",
        "settings.category.environment.general": "General",
        "settings.category.environment.fonts": "Fonts",
        "settings.category.editor": "Code Editor",
        "settings.category.editor.csharp": "C#",
        "settings.category.editor.csharp.general": "General",
        "settings.category.explorer": "Assembly Explorer",
        "settings.theme": "Theme",
        "settings.theme.system": "System",
        "settings.theme.light": "Light",
        "settings.theme.dark": "Dark",
        "settings.font.family": "Font",
        "settings.font.size": "Size",
        "settings.font.preview": "Preview",
        "settings.font.previewText": "public static string Secret() { return \"nested-secret-42\"; }",
        "settings.editor.highlight": "Enable syntax highlighting",
        "settings.editor.highlightHint": "When off, code and IL are shown as plain text (faster for huge files).",
        "settings.editor.wrap": "Word wrap",
        "settings.editor.tabWidth": "Tab width",
        "settings.editor.behaviour": "C# editor",
        "settings.tree.showSignatureHint": "Like dnSpy: only the name is shown by default, the full signature lives in the tooltip.",
        "settings.title": "Settings",
        "settings.general": "General",
        "settings.language": "Interface language",
        "settings.editing": "Editing",
        "settings.allowEditing": "Allow editing IL and types/members",
        "settings.allowEditingHint": "When off the app is read-only: IL edit buttons and structure menus are disabled.",
        "settings.tree": "Assembly tree",
        "settings.collapseHint": "Expansion behaviour lives in the View menu.",
        "settings.about": "About",
        "settings.version": "Version %@",
        "failure.title": "This file cannot be opened as a .NET assembly",
        "failure.file": "File",
        "failure.kind": "Detected",
        "failure.reason": "Reason",
        "failure.size": "Size",
        "failure.magic": "Magic",
        "failure.machine": "Machine",
        "failure.clr": "CLR header",
        "failure.yes": "present",
        "failure.no": "absent",
        "failure.hint": "ILWorkbench only reads and edits .NET assemblies (managed DLL/EXE). For native binaries (C/C++ etc.) use a disassembler.",
        "kind.directory": "This is a folder, not a file",
        "kind.missing": "File is missing or unreadable",
        "kind.machO": "Mach-O native executable / library (macOS, not .NET)",
        "kind.elf": "ELF native executable / library (Linux, not .NET)",
        "kind.zip": "ZIP / archive / NuGet package, not an assembly",
        "kind.text": "Text file, not an assembly",
        "kind.native": "Native Windows DLL/EXE (PE header without a CLR header, usually C/C++)",
        "kind.badPE": "Corrupted or invalid PE file",
        "kind.badManagedImage": "Managed assembly with damaged or unsupported metadata",
        "kind.unknown": "Unrecognised file format",
        "group.pe": "PE",
        "group.typerefs": "Type References",
        "group.references": "References",
        "group.resources": "Resources",
        "group.count": "%d items",
        "namespace.global": "{}",
        "namespace.typeCount": "%d types",
        "peitem.dos": "DOS Header",
        "peitem.file": "File Header",
        "peitem.optional32": "Optional Header (32-bit)",
        "peitem.optional64": "Optional Header (64-bit)",
        "peitem.section": "Section #%d: %@",
        "peitem.cor20": "Cor20 Header",
        "peitem.signature": "Storage Signature",
        "peitem.storageHeader": "Storage Header",
        "peitem.stream": "Stream #%d: %@",
        "kindlabel.assembly": "Assembly",
        "kindlabel.module": "Module",
        "kindlabel.namespace": "Namespace",
        "kindlabel.type": "Type",
        "kindlabel.method": "Method",
        "kindlabel.field": "Field",
        "kindlabel.property": "Property",
        "kindlabel.event": "Event",
        "kindlabel.group": "Metadata",
        "kindlabel.typeref": "Type reference",
        "kindlabel.assemblyref": "Assembly reference",
        "kindlabel.resource": "Resource",
        "kindlabel.error": "Unreadable",
        "kindlabel.loading": "Loading",
        "kindlabel.peitem": "PE",
        "row.assembly": "Assembly",
        "row.module": "Module",
        "row.namespace": "Namespace",
        "row.token": "metadata token",
        "row.loading": "Loading…",
    ]
}

/// User settings, persisted in UserDefaults and observed by the UI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var language: Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            L.language = language
            objectWillChange.send()
        }
    }

    @Published var allowEditing: Bool {
        didSet { UserDefaults.standard.set(allowEditing, forKey: "allowEditing") }
    }

    @Published var hideSynthetic: Bool {
        didSet { UserDefaults.standard.set(hideSynthetic, forKey: "hideSynthetic") }
    }

    @Published var hideCompilerGenerated: Bool {
        didSet { UserDefaults.standard.set(hideCompilerGenerated, forKey: "hideCompilerGenerated") }
    }

    @Published var showSignature: Bool {
        didSet { UserDefaults.standard.set(showSignature, forKey: "showSignature") }
    }

    @Published var showToken: Bool {
        didSet { UserDefaults.standard.set(showToken, forKey: "showToken") }
    }

    @Published var theme: ThemeChoice {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            applyTheme()
        }
    }

    @Published var highlightEnabled: Bool {
        didSet { UserDefaults.standard.set(highlightEnabled, forKey: "highlightEnabled") }
    }

    @Published var wordWrap: Bool {
        didSet { UserDefaults.standard.set(wordWrap, forKey: "wordWrap") }
    }

    @Published var tabWidth: Int {
        didSet { UserDefaults.standard.set(tabWidth, forKey: "tabWidth") }
    }

    @Published var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: "fontFamily") }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }

    /// Font used by the code and IL panes.
    var codeFont: NSFont {
        NSFont(name: fontFamily, size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Fonts offered in Environment ▸ Fonts: the monospaced families installed on this Mac.
    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard let font = NSFont(name: family, size: 12) else { return false }
                return font.isFixedPitch
            }
            .sorted()
    }

    func applyTheme() {
        // NSApplication.shared (not NSApp) because this also runs before the app object exists.
        let application = NSApplication.shared
        switch theme {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        let storedLanguage = defaults.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .chinese
        language = storedLanguage
        allowEditing = defaults.object(forKey: "allowEditing") as? Bool ?? true
        hideSynthetic = defaults.object(forKey: "hideSynthetic") as? Bool ?? true
        hideCompilerGenerated = defaults.object(forKey: "hideCompilerGenerated") as? Bool ?? false
        showSignature = defaults.object(forKey: "showSignature") as? Bool ?? false
        showToken = defaults.object(forKey: "showToken") as? Bool ?? false
        theme = ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        highlightEnabled = defaults.object(forKey: "highlightEnabled") as? Bool ?? true
        wordWrap = defaults.object(forKey: "wordWrap") as? Bool ?? false
        tabWidth = defaults.object(forKey: "tabWidth") as? Int ?? 4
        fontFamily = defaults.string(forKey: "fontFamily") ?? "Menlo"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 12
        L.language = storedLanguage
    }
}
