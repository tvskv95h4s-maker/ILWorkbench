import AppKit
import SwiftUI

/// Reference type wrapper around a tree node: NSOutlineView identifies items by object identity,
/// which also lets us load children lazily without rebuilding the whole tree.
final class OutlineNode {
    let node: AssemblyNode
    var children: [OutlineNode]?
    var isLoading = false

    init(_ node: AssemblyNode) {
        self.node = node
        // The helper sends an empty array for groups whose children are fetched on demand, so an
        // empty list must stay "not loaded yet" - otherwise the node silently never loads.
        if let children = node.children, !children.isEmpty {
            self.children = children.map(OutlineNode.init)
        } else {
            self.children = nil
        }
    }

    var id: String { node.id }
    var isExpandable: Bool {
        if node.kind == "assemblyref" { return node.expandable == true }
        if node.kind == "group" { return true }
        return !(children?.isEmpty ?? true)
    }
}

/// AppKit outline view for the assembly tree.
///
/// SwiftUI's `List` + `DisclosureGroup` re-evaluated the whole tree on every model change and
/// materialised rows eagerly, which made a 20k node assembly stutter on every click. NSOutlineView
/// only asks for the rows on screen, keeps expansion state itself and gives exact control over
/// double-click (no gesture conflicts).
@MainActor
final class AssemblyOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var model: AppModel?
    var onSelect: ((AssemblyNode?) -> Void)?
    var onContextAction: ((OutlineContextAction, AssemblyNode) -> Void)?

    private var rootNodes: [OutlineNode] = []
    private var appliedToken = ""
    private weak var outlineView: NSOutlineView?

    func reloadTree(token: String, in outlineView: NSOutlineView) {
        guard token != appliedToken else { return }
        appliedToken = token
        self.outlineView = outlineView

        let assembly = model?.filteredTree
        rootNodes = assembly.map { [OutlineNode($0)] } ?? []
        outlineView.reloadData()

        let restored = model?.expandedIDs ?? []
        if restored.isEmpty {
            applyDefaultExpansion(in: outlineView)
        } else {
            restoreExpansion(restored, in: outlineView, nodes: rootNodes)
        }
    }

    // MARK: - expansion helpers

    private func applyDefaultExpansion(in outlineView: NSOutlineView) {
        for root in rootNodes {
            outlineView.expandItem(root)
            for module in root.children ?? [] where module.node.kind == "module" {
                outlineView.expandItem(module)
                for child in module.children ?? [] where child.node.kind == "namespace" {
                    outlineView.expandItem(child)
                }
            }
        }
    }

    private func restoreExpansion(_ ids: Set<String>, in outlineView: NSOutlineView, nodes: [OutlineNode]) {
        for node in nodes {
            if ids.contains(node.id) {
                outlineView.expandItem(node)
                restoreExpansion(ids, in: outlineView, nodes: node.children ?? [])
            }
        }
    }

    func requestExpansion(_ command: ExpansionCommand, in outlineView: NSOutlineView) {
        switch command {
        case .rootOnly:
            outlineView.collapseItem(nil, collapseChildren: true)
            for root in rootNodes { outlineView.expandItem(root) }
        case .defaultLevels:
            outlineView.collapseItem(nil, collapseChildren: true)
            applyDefaultExpansion(in: outlineView)
        case .all:
            outlineView.expandItem(nil, expandChildren: true)
        case .none:
            outlineView.collapseItem(nil, collapseChildren: true)
        case .node(let id):
            guard let target = node(for: id) else { return }
            loadChildrenIfNeeded(target)
            outlineView.expandItem(target)
        }
    }

    /// Called after children were loaded on demand.
    func childrenLoaded(for node: OutlineNode, in outlineView: NSOutlineView) {
        outlineView.reloadItem(node, reloadChildren: false)
        // keep the disclosure triangle in sync when a node turned out to be empty
        if (node.children?.isEmpty ?? true) && !node.isExpandable {
            outlineView.reloadItem(node, reloadChildren: false)
        }
    }

    /// Finds a node by display name or raw name (any depth) — used by diagnostics.
    func node(matching name: String) -> OutlineNode? {
        func search(_ nodes: [OutlineNode]) -> OutlineNode? {
            for node in nodes {
                if node.node.name == name
                    || node.node.displayTitle == name
                    || node.node.name.caseInsensitiveCompare(name) == .orderedSame
                    || node.node.displayTitle.caseInsensitiveCompare(name) == .orderedSame {
                    return node
                }
                if let hit = search(node.children ?? []) { return hit }
            }
            return nil
        }
        return search(rootNodes)
    }

    func node(for id: String) -> OutlineNode? {
        func search(_ nodes: [OutlineNode]) -> OutlineNode? {
            for node in nodes {
                if node.id == id { return node }
                if let hit = search(node.children ?? []) { return hit }
            }
            return nil
        }
        return search(rootNodes)
    }

    // MARK: - data source

    nonisolated func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        MainActor.assumeIsolated {
            guard let node = item as? OutlineNode else { return rootNodes.count }
            if let children = node.children { return children.count }
            return node.isExpandable ? 1 : 0     // placeholder row until the real children arrive
        }
    }

    nonisolated func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        MainActor.assumeIsolated {
            guard let node = item as? OutlineNode else { return rootNodes[min(index, max(rootNodes.count - 1, 0))] }
            if let children = node.children, index < children.count { return children[index] }
            loadChildrenIfNeeded(node)
            return OutlineNode(AssemblyNode(
                kind: "loading", name: L.t("row.loading"), token: nil, detail: nil, path: nil,
                compilerGenerated: nil, synthetic: nil, children: [], group: nil, index: nil,
                ref: nil, expandable: nil, tokenLabel: nil, nameKey: nil, nameIndex: nil,
                nameSuffix: nil, count: nil, typeCount: nil))
        }
    }

    nonisolated func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        MainActor.assumeIsolated { (item as? OutlineNode)?.isExpandable ?? false }
    }

    private func loadChildrenIfNeeded(_ node: OutlineNode) {
        guard node.children == nil, !node.isLoading, node.isExpandable else { return }
        node.isLoading = true
        Task { [weak self] in
            guard let self, let model else { return }
            let children = await model.fetchChildren(of: node.node)
            node.children = children.map(OutlineNode.init)
            node.isLoading = false
            if let outlineView { childrenLoaded(for: node, in: outlineView) }
        }
    }

    // MARK: - rows

    nonisolated func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        MainActor.assumeIsolated {
            guard let node = item as? OutlineNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("NodeRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NodeRowView ?? NodeRowView()
            view.identifier = identifier
            view.configure(with: node.node)
            return view
        }
    }

    nonisolated func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        20
    }

    // MARK: - selection / expansion / double click

    nonisolated func outlineViewSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let outlineView = notification.object as? NSOutlineView else { return }
            let row = outlineView.selectedRow
            let node = row >= 0 ? (outlineView.item(atRow: row) as? OutlineNode)?.node : nil
            onSelect?(node?.kind == "loading" ? nil : node)
        }
    }

    nonisolated func outlineViewItemDidExpand(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
            model?.expandedIDs.insert(node.id)
        }
    }

    nonisolated func outlineViewItemDidCollapse(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
            model?.expandedIDs.remove(node.id)
        }
    }

    /// Double click toggles the node, exactly like dnSpy (single click only selects).
    @objc func handleDoubleClick(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let item = sender.item(atRow: row) as? OutlineNode else { return }
        if sender.isItemExpanded(item) {
            sender.collapseItem(item)
        } else {
            loadChildrenIfNeeded(item)
            sender.expandItem(item)
        }
    }

    // MARK: - context menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            guard let outlineView, outlineView.clickedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.clickedRow) as? OutlineNode else { return }
            let target = node.node

            // The root node offers removing the assembly, exactly like dnSpy.
            if target.kind == "assembly" {
                add(L.t("menu.removeAssembly"), .removeAssembly)
                return
            }

            if target.isReference {
                let item = NSMenuItem(title: L.t("menu.referenceReadOnly"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return
            }

            if !AppSettings.shared.allowEditing {
                let item = NSMenuItem(title: L.t("settings.allowEditing"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return
            }

            func add(_ title: String, _ action: OutlineContextAction) {
                let item = NSMenuItem(title: title, action: #selector(performContextAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ContextPayload(action: action, node: target)
                menu.addItem(item)
            }

            switch target.kind {
            case "namespace":
                add(L.t("menu.addType"), .addType)
            case "type":
                add(L.t("menu.addField"), .addField)
                add(L.t("menu.addMethod"), .addMethod)
                menu.addItem(.separator())
                add(L.t("menu.deleteType"), .removeType)
            case "method", "field", "property", "event":
                add(L.t("menu.deleteMember"), .removeMember)
            default:
                break
            }
        }
    }

    @objc private func performContextAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextPayload else { return }
        onContextAction?(payload.action, payload.node)
    }

    private final class ContextPayload: NSObject {
        let action: OutlineContextAction
        let node: AssemblyNode
        init(action: OutlineContextAction, node: AssemblyNode) {
            self.action = action
            self.node = node
        }
    }
}

enum OutlineContextAction {
    case addType, addField, addMethod, removeType, removeMember, removeAssembly
}

/// One outline row: icon, name, signature and metadata token.
final class NodeRowView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let token = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // A stack view skips hidden arranged subviews, so the optional columns never squeeze the
        // name label — with plain constraints a hidden label still collapses the name to 4pt.
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)

        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detail.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        token.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        token.textColor = .tertiaryLabelColor
        token.alignment = .right
        token.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(token)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with node: AssemblyNode) {
        let settings = AppSettings.shared
        icon.image = NSImage(systemSymbolName: node.symbolName, accessibilityDescription: nil)
        icon.contentTintColor = Self.tint(for: node)
        name.stringValue = node.tokenLabel.map { "\(node.displayTitle)  @\($0)" } ?? node.displayTitle
        name.font = node.kind == "namespace" || node.kind == "assembly" || node.kind == "module"
            ? .systemFont(ofSize: 12, weight: .semibold)
            : .systemFont(ofSize: 12)

        // Both columns are optional; the tooltip always carries the full details (dnSpy behaviour).
        detail.isHidden = !settings.showSignature
        detail.stringValue = settings.showSignature ? (node.displayDetail ?? "") : ""
        token.isHidden = !(settings.showToken && node.tokenLabel == nil)
        token.stringValue = settings.showToken ? (node.token.map { String($0.dropFirst(2)) } ?? "") : ""
        toolTip = Self.tooltip(for: node)
    }

    /// Full signature, metadata token and (for references) the resolved file path.
    private static func tooltip(for node: AssemblyNode) -> String {
        var lines: [String] = []
        switch node.kind {
        case "assembly": lines.append(L.t("row.assembly") + " " + node.name)
        case "module": lines.append(L.t("row.module") + " " + node.name)
        case "namespace": lines.append(L.t("row.namespace") + " " + node.name)
        default: break
        }
        if let detail = node.displayDetail, !detail.isEmpty { lines.append(detail) }
        if let token = node.token { lines.append(L.t("row.token") + ": " + token) }
        if let path = node.path { lines.append(path) }
        return lines.joined(separator: "\n")
    }

    private static func tint(for node: AssemblyNode) -> NSColor {
        switch node.kind {
        case "namespace": return .secondaryLabelColor
        case "type": return .systemOrange
        case "method": return .systemBlue
        case "field": return .systemGreen
        case "property": return .systemPurple
        case "event": return .systemPink
        case "group": return .systemTeal
        case "typeref": return .systemIndigo
        case "assemblyref": return .systemBrown
        case "resource": return .systemMint
        case "loading", "error": return .systemGray
        default: return .secondaryLabelColor
        }
    }
}

/// SwiftUI wrapper. It reloads only when the tree token changes, so unrelated model updates
/// (busy state, code text, status line) never touch the outline view.
struct AssemblyOutlineView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let token: String
    let onContextAction: (OutlineContextAction, AssemblyNode) -> Void

    func makeCoordinator() -> AssemblyOutlineCoordinator {
        let coordinator = AssemblyOutlineCoordinator()
        coordinator.model = model
        coordinator.onSelect = { [weak model] node in
            model?.selectedNodeID = node?.id
        }
        coordinator.onContextAction = onContextAction
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.style = .sourceList
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(AssemblyOutlineCoordinator.handleDoubleClick(_:))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        model.expansionHandler = { [weak outlineView] command in
            guard let outlineView else { return }
            context.coordinator.requestExpansion(command, in: outlineView)
        }
        context.coordinator.reloadTree(token: token, in: outlineView)
        outlineView.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? NSOutlineView else { return }
        context.coordinator.model = model
        context.coordinator.onContextAction = onContextAction
        context.coordinator.reloadTree(token: token, in: outlineView)
    }
}


/// Renders the outline view offscreen into a PNG, so the tree that ships can be inspected
/// (and compared against dnSpy) without relying on screen capture permissions.
@MainActor
enum TreeSnapshot {
    private static func step(_ message: String) {
        FileHandle.standardError.write(Data(("[snapshot] " + message + "\n").utf8))
    }

    static func run(assemblyPath: String, outputPath: String, expandAll: Bool, expandNames: [String] = []) async -> Int32 {
        step("creating app object")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        step("opening assembly")
        let model = AppModel()
        await model.open(url: URL(fileURLWithPath: assemblyPath))
        step("tree loaded: \(model.filteredTree == nil ? "nil" : "ok")")
        guard model.filteredTree != nil else {
            print("SNAPSHOT FAILED: \(model.errorMessage ?? "no tree")")
            return 1
        }

        let width: CGFloat = 460
        let height: CGFloat = expandAll ? 1400 : 900

        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 12
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = width - 20
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let coordinator = AssemblyOutlineCoordinator()
        coordinator.model = model
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scrollView
        window.appearance = NSAppearance(named: .aqua)

        step("reloading outline")
        coordinator.reloadTree(token: "snapshot-\(model.treeRevision)-\(expandAll)", in: outlineView)
        if expandAll { outlineView.expandItem(nil, expandChildren: true) }
        // Each name is expanded in turn: containers such as 引用 only exist after their parent loaded.
        for name in expandNames {
            guard let target = coordinator.node(matching: name) else {
                step("NOT FOUND: \(name)")
                continue
            }
            outlineView.expandItem(target)
            let deadline = Date().addingTimeInterval(30)
            while target.children == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            outlineView.reloadItem(target, reloadChildren: true)
            outlineView.expandItem(target)
            step("\(name): \(target.children?.count ?? -1) children")
        }
        step("rows=\(outlineView.numberOfRows), laying out")
        window.layoutIfNeeded()
        outlineView.reloadData()
        outlineView.layoutSubtreeIfNeeded()
        step("rendering")

        guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else {
            print("SNAPSHOT FAILED: no bitmap rep")
            return 1
        }
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("SNAPSHOT FAILED: png encoding")
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            print("SNAPSHOT FAILED: \(error.localizedDescription)")
            return 1
        }
        print("rendered \(outputPath) (\(outlineView.numberOfRows) rows)")
        print("SNAPSHOT OK")
        return 0
    }
}
