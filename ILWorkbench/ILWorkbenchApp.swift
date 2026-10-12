import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Command line options understood by the app binary itself.
enum LaunchOptions {
    /// `--open <path>`: load an assembly at startup (handy for shell users and for UI smoke tests).
    static var startupAssembly: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// Diagnostic that needs AppKit plus a running main run loop (outline view rendering).
enum DiagnosticMode {
    case treeSnapshot(assembly: String, output: String, expandAll: Bool, expandNames: [String])
    case ilCheck(assembly: String)
    case openTest(paths: [String])
    case settingsShot(pages: [String], directory: String)
    case promoShots(assembly: String, directory: String)
}

/// Carries a diagnostic exit status out of a detached task without an unsafe pointer.
final class ExitStatus: @unchecked Sendable {
    var value: Int32 = 1
}

@main
struct ILWorkbenchApp: App {
    static var diagnostic: DiagnosticMode?

    init() {
        // Restore the persisted theme before any window is created.
        AppSettings.shared.applyTheme()

        // Headless verification path, used by Scripts/verify.sh and CI.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--canceltest"), index + 1 < arguments.count {
            let assembly = arguments[index + 1]
            let semaphore = DispatchSemaphore(value: 0)
            let status = ExitStatus()
            Task.detached {
                status.value = await CancelTest.run(assemblyPath: assembly)
                semaphore.signal()
            }
            semaphore.wait()
            exit(status.value)
        }
        if let index = arguments.firstIndex(of: "--renderpreview"), index + 1 < arguments.count {
            let assembly = arguments[index + 1]
            let output = index + 2 < arguments.count
                ? arguments[index + 2]
                : NSTemporaryDirectory() + "ilworkbench-preview.png"
            let typeName = arguments.firstIndex(of: "--type").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            let semaphore = DispatchSemaphore(value: 0)
            let status = ExitStatus()
            Task.detached {
                status.value = await RenderPreview.run(assemblyPath: assembly, outputPath: output, typeName: typeName)
                semaphore.signal()
            }
            semaphore.wait()
            exit(status.value)
        }
        if let index = arguments.firstIndex(of: "--structuretest"), index + 1 < arguments.count {
            let assembly = arguments[index + 1]
            let output = index + 2 < arguments.count
                ? arguments[index + 2]
                : NSTemporaryDirectory() + "ilworkbench-structure.dll"
            let semaphore = DispatchSemaphore(value: 0)
            let status = ExitStatus()
            Task.detached {
                status.value = await SelfTest.runStructure(assemblyPath: assembly, outputPath: output)
                semaphore.signal()
            }
            semaphore.wait()
            exit(status.value)
        }
        if let index = arguments.firstIndex(of: "--selftest"), index + 1 < arguments.count {
            let assembly = arguments[index + 1]
            let output = index + 2 < arguments.count
                ? arguments[index + 2]
                : NSTemporaryDirectory() + "ilworkbench-selftest.dll"
            // App.init() is main-actor isolated, so a plain Task would be scheduled on the main
            // actor and deadlock against the wait below. Detach it to the global executor.
            let semaphore = DispatchSemaphore(value: 0)
            let status = ExitStatus()
            Task.detached {
                status.value = await SelfTest.run(assemblyPath: assembly, outputPath: output)
                semaphore.signal()
            }
            semaphore.wait()
            exit(status.value)
        }

        if let index = arguments.firstIndex(of: "--promoshots"), index + 2 < arguments.count {
            Self.diagnostic = .promoShots(assembly: arguments[index + 1], directory: arguments[index + 2])
        }

        if let index = arguments.firstIndex(of: "--settingshot") {
            let directory = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--")
                ? arguments[index + 1]
                : NSTemporaryDirectory()
            var pages: [String] = []
            var cursor = index + 1
            while cursor + 1 < arguments.count {
                if arguments[cursor] == "--page" {
                    pages.append(arguments[cursor + 1])
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            Self.diagnostic = .settingsShot(pages: pages.isEmpty ? ["general", "fonts", "csharp"] : pages,
                                            directory: directory)
        }

        if let index = arguments.firstIndex(of: "--opentest") {
            Self.diagnostic = .openTest(paths: Array(arguments.dropFirst(index + 1)))
        }

        if let index = arguments.firstIndex(of: "--ilcheck"), index + 1 < arguments.count {
            Self.diagnostic = .ilCheck(assembly: arguments[index + 1])
        }

        // Rendered after launch, because TreeSnapshot is main-actor bound and needs the run loop.
        let arguments2 = CommandLine.arguments
        if let index = arguments2.firstIndex(of: "--treesnapshot"), index + 1 < arguments2.count {
            let output = index + 2 < arguments2.count && !arguments2[index + 2].hasPrefix("--")
                ? arguments2[index + 2]
                : NSTemporaryDirectory() + "ilworkbench-tree.png"
            var expandNames: [String] = []
            var cursor = index + 2
            while cursor + 1 < arguments2.count {
                if arguments2[cursor] == "--expand" {
                    expandNames.append(arguments2[cursor + 1])
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            Self.diagnostic = .treeSnapshot(assembly: arguments2[index + 1],
                                            output: output,
                                            expandAll: arguments2.contains("--expand-all"),
                                            expandNames: expandNames)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let diagnostic = Self.diagnostic {
                DiagnosticRunner(mode: diagnostic)
            } else {
                ContentView()
                    .frame(minWidth: 940, minHeight: 620)
            }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L.t("menu.open")) { openDocument() }
                    .keyboardShortcut("o")
                Button(L.t("menu.reload")) { Task { await AppModel.shared.reload() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(replacing: .saveItem) {
                Button(L.t("menu.save")) { Task { await AppModel.shared.save(to: nil) } }
                    .keyboardShortcut("s")
                Button(L.t("menu.saveAs")) { saveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button(L.t("menu.removeAssembly")) { Task { await AppModel.shared.closeAssembly() } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu(L.t("menu.view")) {
                Button(L.t("menu.expandRoot")) { AppModel.shared.expandRootOnly() }
                Button(L.t("menu.expandToTypes")) { AppModel.shared.expandToTypeLevel() }
                Button(L.t("menu.expandAll")) { AppModel.shared.expandAll() }
                Button(L.t("menu.collapseAll")) { AppModel.shared.collapseAll() }
            }
        }
        Settings {
            SettingsWindow()
        }
    }

    @MainActor private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = assemblyContentTypes
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await AppModel.shared.open(url: url) }
        }
    }

    @MainActor private func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if let name = AppModel.shared.assemblyName {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            panel.nameFieldStringValue = ext.isEmpty ? base + ".patched" : base + ".patched." + ext
        }
        panel.allowedContentTypes = assemblyContentTypes
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await AppModel.shared.save(to: url) }
        }
    }

    private var assemblyContentTypes: [UTType] {
        var types: [UTType] = []
        if let dll = UTType(filenameExtension: "dll") { types.append(dll) }
        if let exe = UTType(filenameExtension: "exe") { types.append(exe) }
        types.append(.data)
        return types
    }
}

/// Runs a diagnostic once the app is live, then exits with its status.
struct DiagnosticRunner: View {
    let mode: DiagnosticMode

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                switch mode {
                case .treeSnapshot(let assembly, let output, let expandAll, let expandNames):
                    exit(await TreeSnapshot.run(assemblyPath: assembly, outputPath: output, expandAll: expandAll, expandNames: expandNames))
                case .ilCheck(let assembly):
                    exit(await IlCheck.run(assemblyPath: assembly))
                case .openTest(let paths):
                    exit(await OpenTest.run(paths: paths))
                case .settingsShot(let pages, let directory):
                    exit(await SettingsShot.run(pages: pages, outputDirectory: directory))
                case .promoShots(let assembly, let directory):
                    exit(await PromoShots.run(assemblyPath: assembly, outputDirectory: directory))
                }
            }
    }
}
