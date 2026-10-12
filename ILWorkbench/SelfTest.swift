import AppKit
import SwiftUI
import Foundation

/// Headless end-to-end check of the app's own helper pipeline:
/// open -> tree -> decompile -> IL -> edit -> save. Run with:
///   ILWorkbench.app/Contents/MacOS/ILWorkbench --selftest /path/to/assembly.dll
enum SelfTest {
    static func run(assemblyPath: String, outputPath: String) async -> Int32 {
        let client = HelperClient()
        do {
            let start = Date()
            let opened = try await client.call("open", ["path": assemblyPath], as: OpenResult.self)
            let openSeconds = Date().timeIntervalSince(start)
            var nodeCount = 0
            func count(_ node: AssemblyNode) {
                nodeCount += 1
                for child in node.children ?? [] { count(child) }
            }
            count(opened.tree)
            print("opened: \(opened.tree.name) (\(opened.tree.detail ?? ""))")
            print(String(format: "open+decode: %.2fs, nodes: %d", openSeconds, nodeCount))

            guard let method = findMethod(opened.tree, named: "Secret"), let token = method.token else {
                print("SELFTEST FAILED: no method named Secret in the tree")
                return 1
            }
            print("target: \(method.detail ?? method.name) [\(token)]")

            let before = try await client.call("decompile", ["token": token], as: CodeResult.self)
            print("C# before:\n\(before.text.trimmingCharacters(in: .whitespacesAndNewlines))")

            let il = try await client.call("il", ["token": token], as: IlResult.self)
            print("IL before: \(il.text.trimmingCharacters(in: .whitespacesAndNewlines))")

            let edited = try await client.call("setConstant", [
                "token": token, "offset": 0, "value": "patched-from-app"
            ], as: TextResult.self)
            print("edit: \(edited.text)")

            let after = try await client.call("decompile", ["token": token], as: CodeResult.self)
            print("C# after:\n\(after.text.trimmingCharacters(in: .whitespacesAndNewlines))")

            let saved = try await client.call("save", ["path": outputPath], as: SaveResult.self)
            print("saved: \(saved.path)")
            print("SELFTEST OK")
            return 0
        } catch {
            print("SELFTEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    /// Structural editing check driven through the app's own client:
    /// add a field + method, add a type with a method, delete a method, then save.
    static func runStructure(assemblyPath: String, outputPath: String) async -> Int32 {
        let client = HelperClient()
        do {
            let opened = try await client.call("open", ["path": assemblyPath], as: OpenResult.self)
            guard let banner = findNode(opened.tree, kind: "type", name: "Banner"), let bannerToken = banner.token else {
                print("STRUCTURE SELFTEST FAILED: SampleLib.Banner not found")
                return 1
            }

            var result = try await client.call("addField", [
                "typeToken": bannerToken, "name": "Version", "fieldType": "System.Int32",
                "isStatic": true, "isPublic": true
            ], as: StructureResult.self)
            print("addField    -> \(result.text)")

            result = try await client.call("addMethod", [
                "typeToken": bannerToken, "name": "Sum", "returnType": "System.Int32",
                "parameters": ["System.Int32", "System.Int32"],
                "isStatic": true, "isPublic": true, "bodyKind": "constant", "constant": "42"
            ], as: StructureResult.self)
            print("addMethod   -> \(result.text)")

            result = try await client.call("addType", [
                "namespace": "SampleLib", "name": "ToolAddedType", "kind": "class", "isPublic": true
            ], as: StructureResult.self)
            print("addType     -> \(result.text)")

            guard let added = findNode(result.tree, kind: "type", name: "ToolAddedType"), let addedToken = added.token else {
                print("STRUCTURE SELFTEST FAILED: added type missing from refreshed tree")
                return 1
            }
            result = try await client.call("addMethod", [
                "typeToken": addedToken, "name": "Ping", "returnType": "System.String", "parameters": [],
                "isStatic": true, "isPublic": true, "bodyKind": "constant", "constant": "tool-added-type"
            ], as: StructureResult.self)
            print("addMethod   -> \(result.text)")

            guard let render = findNode(result.tree, kind: "method", name: "Render"), let renderToken = render.token else {
                print("STRUCTURE SELFTEST FAILED: SampleLib.Banner.Render not found")
                return 1
            }
            result = try await client.call("removeMember", ["token": renderToken], as: StructureResult.self)
            print("removeMember-> \(result.text)")

            let saved = try await client.call("save", ["path": outputPath], as: SaveResult.self)
            print("saved: \(saved.path) (renumbered=\(saved.renumbered ?? false))")

            let hasSum = findNode(saved.tree, kind: "method", name: "Sum") != nil
            let hasPing = findNode(saved.tree, kind: "method", name: "Ping") != nil
            let hasRender = findNode(saved.tree, kind: "method", name: "Render") != nil
            print("tree after save: Sum=\(hasSum) Ping=\(hasPing) Render=\(hasRender)")
            guard hasSum, hasPing, !hasRender else {
                print("STRUCTURE SELFTEST FAILED: refreshed tree does not match the edit")
                return 1
            }
            print("STRUCTURE SELFTEST OK")
            return 0
        } catch {
            print("STRUCTURE SELFTEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    static func findNode(_ node: AssemblyNode, kind: String, name: String) -> AssemblyNode? {
        if node.kind == kind, node.name == name { return node }
        for child in node.children ?? [] {
            if let hit = findNode(child, kind: kind, name: name) { return hit }
        }
        return nil
    }

    private static func findMethod(_ node: AssemblyNode, named name: String) -> AssemblyNode? {
        if node.kind == "method", node.name == name { return node }
        for child in node.children ?? [] {
            if let hit = findMethod(child, named: name) { return hit }
        }
        return nil
    }
}


/// Renders real decompiler output with the production highlighter into a PNG.
/// Used to verify token colours without relying on screen capture permissions.
enum RenderPreview {
    static func run(assemblyPath: String, outputPath: String, typeName: String?) async -> Int32 {
        let client = HelperClient()
        do {
            // Timing of the tokenizer is logged to stderr so large documents can be measured.
            SyntaxHighlighter.timingLogger = { message in
                FileHandle.standardError.write(Data(("[highlight] " + message + "\n").utf8))
            }

            let opened = try await client.call("open", ["path": assemblyPath], as: OpenResult.self)
            var target: AssemblyNode?
            func walk(_ node: AssemblyNode) {
                if node.kind == "type" {
                    if let typeName {
                        if node.name == typeName { target = node }
                    } else if (node.children?.count ?? 0) > (target?.children?.count ?? 0) {
                        target = node
                    }
                }
                for child in node.children ?? [] { walk(child) }
            }
            walk(opened.tree)
            guard let type = target, let token = type.token else {
                print("RENDER FAILED: type not found")
                return 1
            }
            print("type: \(type.name) (\(type.children?.count ?? 0) members)")

            let start = Date()
            let code = try await client.call("decompile", ["token": token], as: CodeResult.self)
            print(String(format: "decompile: %.2fs, %d chars", Date().timeIntervalSince(start), code.text.count))

            let theme = SyntaxTheme.light
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let highlightStart = Date()
            let full = SyntaxHighlighter.highlighted(code.text, language: .csharp, theme: theme, font: font)
            print(String(format: "highlight: %.2fs for %d chars", Date().timeIntervalSince(highlightStart), code.text.count))

            // draw the first screenful of the highlighted text
            let preview = full.attributedSubstring(from: NSRange(location: 0, length: min(full.length, 2600)))
            let size = NSSize(width: 1100, height: 700)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            ("\(type.name) — syntax highlighted" as NSString)
                .draw(at: NSPoint(x: 20, y: size.height - 26),
                      withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.black])
            preview.draw(with: NSRect(x: 20, y: 20, width: size.width - 40, height: size.height - 60),
                         options: NSString.DrawingOptions.usesLineFragmentOrigin)
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                print("RENDER FAILED: png")
                return 1
            }
            try png.write(to: URL(fileURLWithPath: outputPath))
            print("rendered \(outputPath)")
            print("RENDER OK")
            return 0
        } catch {
            print("RENDER FAILED: \(error.localizedDescription)")
            return 1
        }
    }
}

/// Verifies that switching away from a long decompilation actually aborts it, through the app's own
/// client (reader-thread demultiplexing + the helper's cancel command).
enum CancelTest {
    static func run(assemblyPath: String) async -> Int32 {
        let client = HelperClient()
        do {
            let opened = try await client.call("open", ["path": assemblyPath], as: OpenResult.self)
            var biggest: AssemblyNode?
            func walk(_ node: AssemblyNode) {
                if node.kind == "type", (node.children?.count ?? 0) > (biggest?.children?.count ?? 0) { biggest = node }
                for child in node.children ?? [] { walk(child) }
            }
            walk(opened.tree)
            guard let target = biggest, let token = target.token else {
                print("CANCEL TEST FAILED: no type found")
                return 1
            }
            print("target: \(target.name) (\(target.children?.count ?? 0) members)")

            let start = Date()
            let decompile = Task { try await client.call("decompile", ["token": token], as: CodeResult.self) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            client.cancelInFlight()

            do {
                let result = try await decompile.value
                print(String(format: "decompile finished in %.2fs without cancelling (%d chars)",
                             Date().timeIntervalSince(start), result.text.count))
                print("CANCEL TEST FAILED: cancellation had no effect")
                return 1
            } catch {
                print(String(format: "aborted after %.2fs: %@", Date().timeIntervalSince(start), error.localizedDescription))
            }

            print("CANCEL TEST OK")
            return 0
        } catch {
            print("CANCEL TEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }
}


/// Exercises the exact state transitions the IL toggle uses, so "switching to IL does nothing"
/// can be told apart from "the selected node has no IL".
@MainActor
enum IlCheck {
    static func run(assemblyPath: String) async -> Int32 {
        let model = AppModel()
        await model.open(url: URL(fileURLWithPath: assemblyPath))
        guard let root = model.filteredTree else {
            print("IL CHECK FAILED: no tree (\(model.errorMessage ?? "?"))")
            return 1
        }

        var firstMethod: AssemblyNode?
        var firstType: AssemblyNode?
        func walk(_ node: AssemblyNode) {
            if firstMethod == nil, node.kind == "method", node.token != nil { firstMethod = node }
            if firstType == nil, node.kind == "type" { firstType = node }
            for child in node.children ?? [] { walk(child) }
        }
        walk(root)

        guard let method = firstMethod, let type = firstType else {
            print("IL CHECK FAILED: no method/type in tree")
            return 1
        }

        // --- method: C# then IL ---
        model.selectedNodeID = method.id
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        print("method selected: \(method.name), C# chars = \(model.code.count), language = \(model.codeLanguage)")

        model.viewMode = .il
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let il = model.il
        print("after switching to IL: il=\(il == nil ? "nil" : "ok") instructions=\(il?.instructions?.count ?? -1) language=\(model.codeLanguage)")
        let showsIlEditor = model.viewMode == .il && il != nil && model.selectedNode?.isMethod == true
        print("UI would show the IL editor: \(showsIlEditor)")

        // --- type: IL has no meaning, this is what confused the user ---
        model.selectedNodeID = type.id
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        print("type selected: \(type.name), viewMode=\(model.viewMode.rawValue), il=\(model.il == nil ? "nil" : "ok"), language=\(model.codeLanguage)")
        let showsIlEditorForType = model.viewMode == .il && model.il != nil && model.selectedNode?.isMethod == true
        print("UI would show the IL editor for a type: \(showsIlEditorForType)")

        // assembly / module rows show dnSpy's assembly attributes document
        model.selectedNodeID = root.id
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let assemblyInfoOk = model.code.contains("[assembly:") && model.code.contains("using System")
        print("assembly node document: \(assemblyInfoOk ? "ok" : "missing"), \(model.code.count) chars, language=\(model.codeLanguage)")
        if let module = (root.children ?? []).first(where: { $0.kind == "module" }) {
            model.selectedNodeID = module.id
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("module node document: \(model.code.contains("[assembly:") ? "ok" : "missing")")
        }

        guard showsIlEditor, assemblyInfoOk else {
            print("IL CHECK FAILED")
            return 1
        }
        print("IL CHECK OK")
        return 0
    }
}


/// Opens any file through the app model and reports how it degraded: an assembly opens normally,
/// anything else becomes an error node with a document. Also checks remove-assembly and i18n.
@MainActor
enum OpenTest {
    static func run(paths: [String]) async -> Int32 {
        let model = AppModel.shared
        var failures = 0

        for path in paths {
            let url = URL(fileURLWithPath: path)
            await model.open(url: url)
            let root = model.tree
            let failed = model.failedFile != nil
            print("[open] \(url.lastPathComponent): failed=\(failed) root=\(root?.kind ?? "nil") name=\(root?.name ?? "-")")

            if failed {
                model.selectedNodeID = root?.id
                try? await Task.sleep(nanoseconds: 400_000_000)
                let firstLines = model.code.split(separator: "\n").prefix(4).joined(separator: " | ")
                print("        document: \(firstLines)")
                if model.code.isEmpty { print("        ERROR: no error document"); failures += 1 }
            } else {
                var nodes = 0
                func count(_ node: AssemblyNode) { nodes += 1; for child in node.children ?? [] { count(child) } }
                if let root { count(root) }
                print("        tree nodes: \(nodes)")
            }
        }

        // remove assembly
        await model.closeAssembly()
        print("[close] tree=\(model.tree == nil ? "nil" : "still there") path=\(model.assemblyPath ?? "nil")")
        if model.tree != nil || model.assemblyPath != nil { failures += 1 }

        // language switch affects both tables
        let original = L.language
        L.language = .english
        let english = L.t("menu.open")
        L.language = .chinese
        let chinese = L.t("menu.open")
        L.language = original
        print("[i18n] en=\(english) zh=\(chinese)")
        if english != "Open…" || chinese != "打开…" { failures += 1 }

        print(failures == 0 ? "OPEN TEST OK" : "OPEN TEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}

/// Renders real app windows for the README/screenshots. It only ever opens the assembly that is
/// passed in (the repository's own sample), never anything from the developer's machine.
@MainActor
enum PromoShots {
    static func run(assemblyPath: String, outputDirectory: String) async -> Int32 {
        let model = AppModel.shared
        await model.open(url: URL(fileURLWithPath: assemblyPath))
        guard let root = model.tree else {
            print("PROMO FAILED: \(model.errorMessage ?? "no tree")")
            return 1
        }

        var targetType: AssemblyNode?
        var targetMethod: AssemblyNode?
        func walk(_ node: AssemblyNode) {
            if node.kind == "type", targetType == nil, (node.children?.count ?? 0) >= 4 {
                targetType = node
                let methods = (node.children ?? []).filter { $0.kind == "method" && $0.name != ".ctor" }
                let preferred = ["Greet", "Render", "Report", "IsOverLimit"]
                targetMethod = preferred.compactMap { name in methods.first { $0.name == name } }.first
                    ?? methods.first
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(root)
        print("sample: \(root.name)")
        print("type: \(targetType?.name ?? "-"), method: \(targetMethod?.name ?? "-")")

        // One window, reused for every shot: the outline view must be live before expansion
        // commands reach it, and newly revealed rows need a layout pass before being captured.
        let hosting = NSHostingView(rootView: ContentView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))   // keep it off screen
        window.orderFront(nil)
        await settle(window, hosting)

        model.expandToTypeLevel()
        if let type = targetType { model.expandNode(type.id) }
        await settle(window, hosting)

        model.viewMode = .csharp
        model.selectedNodeID = targetMethod?.id ?? targetType?.id
        await settle(window, hosting)
        capture(hosting, to: outputDirectory + "/window-csharp.png")

        if let method = targetMethod {
            model.selectedNodeID = method.id
            model.viewMode = .il
            await settle(window, hosting)
            capture(hosting, to: outputDirectory + "/window-il.png")
        }

        model.viewMode = .csharp
        model.selectedNodeID = root.id
        await settle(window, hosting)
        capture(hosting, to: outputDirectory + "/window-assembly.png")

        window.orderOut(nil)

        // Settings window is a separate view hierarchy.
        let settingsHosting = NSHostingView(rootView: SettingsWindow())
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 476),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        settingsWindow.contentView = settingsHosting
        settingsHosting.frame = NSRect(x: 0, y: 0, width: 700, height: 476)
        settingsWindow.appearance = NSAppearance(named: .aqua)
        settingsWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        settingsWindow.orderFront(nil)
        await settle(settingsWindow, settingsHosting)
        capture(settingsHosting, to: outputDirectory + "/window-settings.png")
        settingsWindow.orderOut(nil)

        print("PROMO OK")
        return 0
    }

    /// Lets SwiftUI/AppKit finish laying out before the pixels are read.
    private static func settle(_ window: NSWindow, _ hosting: NSView) async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    private static func capture(_ hosting: NSView, to path: String) {
        let bounds = NSRect(origin: .zero, size: hosting.bounds.size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            print("PROMO FAILED: no bitmap for \(path)")
            return
        }
        // Note: cacheDisplay draws the toolbar's vibrancy material as black; the compose step
        // crops that strip when it builds the README images.
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("PROMO FAILED: png for \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("rendered \(path)")
    }
}
