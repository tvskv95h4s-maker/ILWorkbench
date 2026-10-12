import AppKit
import SwiftUI

/// A working copy of the settings. The options window edits this copy and only writes it back to
/// `AppSettings.shared` when the user presses 确定, so 取消 really cancels.
final class SettingsDraft: ObservableObject {
    @Published var language: Language
    @Published var theme: ThemeChoice
    @Published var allowEditing: Bool
    @Published var hideSynthetic: Bool
    @Published var hideCompilerGenerated: Bool
    @Published var showSignature: Bool
    @Published var showToken: Bool
    @Published var highlightEnabled: Bool
    @Published var wordWrap: Bool
    @Published var tabWidth: Int
    @Published var fontFamily: String
    @Published var fontSize: Double

    init(from settings: AppSettings = .shared) {
        language = settings.language
        theme = settings.theme
        allowEditing = settings.allowEditing
        hideSynthetic = settings.hideSynthetic
        hideCompilerGenerated = settings.hideCompilerGenerated
        showSignature = settings.showSignature
        showToken = settings.showToken
        highlightEnabled = settings.highlightEnabled
        wordWrap = settings.wordWrap
        tabWidth = settings.tabWidth
        fontFamily = settings.fontFamily
        fontSize = settings.fontSize
    }

    /// Re-reads the live settings (used every time the window appears).
    func reset(from settings: AppSettings = .shared) {
        language = settings.language
        theme = settings.theme
        allowEditing = settings.allowEditing
        hideSynthetic = settings.hideSynthetic
        hideCompilerGenerated = settings.hideCompilerGenerated
        showSignature = settings.showSignature
        showToken = settings.showToken
        highlightEnabled = settings.highlightEnabled
        wordWrap = settings.wordWrap
        tabWidth = settings.tabWidth
        fontFamily = settings.fontFamily
        fontSize = settings.fontSize
    }

    /// Writes the draft back; every didSet in AppSettings takes care of persisting and applying.
    func apply(to settings: AppSettings = .shared) {
        settings.language = language
        settings.theme = theme
        settings.allowEditing = allowEditing
        settings.hideSynthetic = hideSynthetic
        settings.hideCompilerGenerated = hideCompilerGenerated
        settings.showSignature = showSignature
        settings.showToken = showToken
        settings.highlightEnabled = highlightEnabled
        settings.wordWrap = wordWrap
        settings.tabWidth = tabWidth
        settings.fontFamily = fontFamily
        settings.fontSize = fontSize
    }
}

/// The ⌘, window: options pages plus 确定 / 取消 in the lower right.
struct SettingsWindow: View {
    @StateObject private var draft = SettingsDraft()
    @State private var initialPage: SettingsPage

    init(initialPage: SettingsPage = .environmentGeneral) {
        _initialPage = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsView(draft: draft, initialPage: initialPage)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button(L.t("common.cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L.t("common.ok")) {
                    draft.apply()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 700, height: 476)
        .onAppear { draft.reset() }
    }

    private func close() {
        NSApp.keyWindow?.close()
    }
}

/// Categories shown in the settings tree (dnSpy-style: left tree, right page).
/// Parent entries are selectable too and open their first page.
enum SettingsPage: Hashable, Identifiable {
    case environment
    case environmentGeneral
    case environmentFonts
    case editor
    case editorCSharp
    case editorCSharpGeneral
    case assemblyExplorer

    var id: Self { self }
}

/// ⌘, — a two pane options window: category tree on the left, the selected page on the right.
struct SettingsView: View {
    @ObservedObject var draft: SettingsDraft
    @State private var selection: SettingsPage?
    @State private var expanded: Set<String>

    init(draft: SettingsDraft, initialPage: SettingsPage = .environmentGeneral) {
        self.draft = draft
        _selection = State(initialValue: initialPage)
        // dnSpy opens its tree fully expanded; do the same.
        _expanded = State(initialValue: ["environment", "editor", "editor.csharp"])
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                parentRow(key: "environment", title: L.t("settings.category.environment"),
                          icon: "gearshape", page: .environment)
                if expanded.contains("environment") {
                    leafRow(.environmentGeneral, L.t("settings.category.environment.general"),
                            "slider.horizontal.3", indent: 1)
                    leafRow(.environmentFonts, L.t("settings.category.environment.fonts"),
                            "textformat", indent: 1)
                }

                parentRow(key: "editor", title: L.t("settings.category.editor"),
                          icon: "chevron.left.forwardslash.chevron.right", page: .editor)
                if expanded.contains("editor") {
                    parentRow(key: "editor.csharp", title: L.t("settings.category.editor.csharp"),
                              icon: "curlybraces", page: .editorCSharp, indent: 1)
                    if expanded.contains("editor.csharp") {
                        leafRow(.editorCSharpGeneral, L.t("settings.category.editor.csharp.general"),
                                "slider.horizontal.3", indent: 2)
                    }
                }

                leafRow(.assemblyExplorer, L.t("settings.category.explorer"),
                        "list.bullet.indent", indent: 0)
            }
            .listStyle(.sidebar)
            .frame(width: 215)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                page
                    .frame(width: 440, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(width: 700, height: 430)
    }

    /// Preview font built from the draft, so the sample reflects unsaved choices.
    private var draftFont: NSFont {
        NSFont(name: draft.fontFamily, size: draft.fontSize)
            ?? .monospacedSystemFont(ofSize: draft.fontSize, weight: .regular)
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    // MARK: - rows

    /// A selectable parent row with its own disclosure triangle (clicking the row selects,
    /// clicking the triangle expands), so parent nodes are not dead as in a plain DisclosureGroup.
    private func parentRow(key: String, title: String, icon: String,
                           page: SettingsPage, indent: CGFloat = 0) -> some View {
        HStack(spacing: 4) {
            Button {
                toggle(key)
            } label: {
                Image(systemName: expanded.contains(key) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)

            Label(title, systemImage: icon)
                .padding(.leading, indent * 10)
        }
        .tag(page)
        // Double click expands/collapses, like the assembly tree and dnSpy's option tree.
        .simultaneousGesture(TapGesture(count: 2).onEnded { toggle(key) })
    }

    private func leafRow(_ page: SettingsPage, _ title: String, _ icon: String, indent: CGFloat) -> some View {
        Label(title, systemImage: icon)
            .padding(.leading, indent * 10 + 14)
            .tag(page)
    }

    // MARK: - pages

    @ViewBuilder
    private var page: some View {
        switch selection ?? .environmentGeneral {
        case .environment, .environmentGeneral: environmentGeneral
        case .environmentFonts: environmentFonts
        case .editor, .editorCSharp, .editorCSharpGeneral: editorGeneral
        case .assemblyExplorer: assemblyExplorer
        }
    }

    private var environmentGeneral: some View {
        Form {
            LabeledContent(L.t("settings.language")) {
                Picker("", selection: $draft.language) {
                    ForEach(Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            LabeledContent(L.t("settings.theme")) {
                Picker("", selection: $draft.theme) {
                    ForEach(ThemeChoice.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            Divider()

            Toggle(L.t("settings.allowEditing"), isOn: $draft.allowEditing)
            Text(L.t("settings.allowEditingHint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var environmentFonts: some View {
        Form {
            LabeledContent(L.t("settings.font.family")) {
                Picker("", selection: $draft.fontFamily) {
                    ForEach(AppSettings.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }

            LabeledContent(L.t("settings.font.size")) {
                HStack(spacing: 8) {
                    Text("\(Int(draft.fontSize))")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                    Stepper("", value: $draft.fontSize, in: 9...24, step: 1)
                        .labelsHidden()
                }
            }

            Divider()

            Text(L.t("settings.font.preview"))
            Text(L.t("settings.font.previewText"))
                .font(Font(draftFont))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private var editorGeneral: some View {
        Form {
            Toggle(L.t("settings.editor.highlight"), isOn: $draft.highlightEnabled)
            Text(L.t("settings.editor.highlightHint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle(L.t("settings.editor.wrap"), isOn: $draft.wordWrap)

            LabeledContent(L.t("settings.editor.tabWidth")) {
                HStack(spacing: 8) {
                    Text("\(draft.tabWidth)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                    Stepper("", value: $draft.tabWidth, in: 2...8, step: 1)
                        .labelsHidden()
                }
            }
        }
    }

    private var assemblyExplorer: some View {
        Form {
            Toggle(L.t("menu.hideSynthetic"), isOn: $draft.hideSynthetic)
            Toggle(L.t("menu.hideCompilerGenerated"), isOn: $draft.hideCompilerGenerated)
            Toggle(L.t("menu.showSignature"), isOn: $draft.showSignature)
            Text(L.t("settings.tree.showSignatureHint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L.t("menu.showToken"), isOn: $draft.showToken)
        }
    }
}

/// Renders the settings window offscreen so the layout can be checked without screen capture.
@MainActor
enum SettingsShot {
    static func run(pages: [String], outputDirectory: String) async -> Int32 {
        // Draft semantics: nothing may change until 确定 is pressed.
        let live = AppSettings.shared
        let originalSize = live.fontSize
        let draft = SettingsDraft()
        draft.fontSize = originalSize + 3
        draft.wordWrap = !live.wordWrap
        if live.fontSize != originalSize {
            print("SETTINGS SHOT FAILED: draft leaked into the live settings")
            return 1
        }
        print("[draft] 未点确定：live fontSize 仍为 \(live.fontSize) ✓")
        draft.apply()
        if live.fontSize != originalSize + 3 {
            print("SETTINGS SHOT FAILED: 确定 did not apply the draft")
            return 1
        }
        print("[draft] 点确定后：live fontSize = \(live.fontSize) ✓")
        live.fontSize = originalSize          // restore
        live.wordWrap = !live.wordWrap

        for name in pages {
            let page: SettingsPage
            switch name {
            case "fonts": page = .environmentFonts
            case "csharp": page = .editorCSharpGeneral
            case "explorer": page = .assemblyExplorer
            case "environment": page = .environment
            case "editor": page = .editor
            default: page = .environmentGeneral
            }

            let hosting = NSHostingView(rootView: SettingsWindow(initialPage: page))
            hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 430)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .aqua)
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 700_000_000)
            hosting.layoutSubtreeIfNeeded()

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("SETTINGS SHOT FAILED: no bitmap")
                return 1
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("SETTINGS SHOT FAILED: png")
                return 1
            }
            let path = outputDirectory + "/settings-\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("rendered \(path)")
        }
        print("SETTINGS SHOT OK")
        return 0
    }
}
