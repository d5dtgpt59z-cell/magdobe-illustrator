import SwiftUI
import AppKit

struct NativeLayerOutline: NSViewRepresentable {
    @ObservedObject var session: EditorSession
    @ObservedObject var document: VectorDocument
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = LayerOutlineView(session: session)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layers"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.headerView = nil; outline.rowHeight = 26; outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true; outline.allowsEmptySelection = true
        outline.style = .sourceList
        outline.backgroundColor = NSColor(patternImage: PaperTexture.tile)
        outline.delegate = context.coordinator; outline.dataSource = context.coordinator
        outline.target = context.coordinator; outline.doubleAction = #selector(Coordinator.openGroup(_:))
        outline.registerForDraggedTypes([Coordinator.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu(); menu.delegate = context.coordinator; outline.menu = menu
        let scroll = NSScrollView(); scroll.documentView = outline
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        context.coordinator.outline = outline
        context.coordinator.update()
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update() }

    final class Item: NSObject {
        let id: UUID
        var children: [Item] = []
        init(_ id: UUID) { self.id = id }
    }
    struct Presentation: Equatable {
        var id: UUID
        var parent: UUID?
        var kind: VectorNode.Kind
        var name: String
        var symbol: String
        var color: VectorColor
        var visible: Bool
        var locked: Bool
        var effectiveHidden: Bool
        var effectiveLocked: Bool
    }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.builtbymagnus.vector.hierarchy-drag")
        let session: EditorSession
        weak var outline: NSOutlineView?
        var roots: [Item] = []
        var items: [UUID: Item] = [:]
        var presentation: [UUID: Presentation] = [:]
        private var lastRows: [Presentation] = []
        private var updating = false
        private var revision: UInt64?
        private var expanded: Set<UUID> = []
        private var selection: Set<UUID> = []
        init(_ session: EditorSession) { self.session = session }

        func update() {
            guard let outline else { return }
            updating = true; defer { updating = false }
            if let width = outline.enclosingScrollView?.contentSize.width, width > 0 { outline.tableColumns.first?.width = max(80, width - 32) }
            let changed = revision != session.document.revision
            guard changed || expanded != session.expandedNodes || selection != session.selection else { return }
            defer { revision = session.document.revision; expanded = session.expandedNodes; selection = session.selection }
            let project = session.document.project, index = session.document.hierarchyIndex
            if changed {
                let rows = index.order.compactMap { id -> Presentation? in
                    guard let node = index.nodes[id] else { return nil }
                    let shape = index.shapeIndices[id].map { project.shapes[$0] }
                    let symbol: String
                    switch node.kind {
                    case .layer: symbol = "square.3.layers.3d"
                    case .group: symbol = "folder"
                    case .object:
                        switch shape?.kind {
                        case .ellipse: symbol = "circle"
                        case .text: symbol = "textformat"
                        case .path: symbol = "point.topleft.down.to.point.bottomright.curvepath"
                        default: symbol = "rectangle"
                        }
                    }
                    return Presentation(id: id, parent: index.parents[id], kind: node.kind, name: shape?.name ?? node.name, symbol: symbol,
                        color: shape?.fill ?? shape?.stroke ?? .ink, visible: shape?.visible ?? node.visible, locked: shape?.locked ?? node.locked,
                        effectiveHidden: index.hidden.contains(id), effectiveLocked: index.locked.contains(id))
                }
                if rows != lastRows {
                    let oldItems = items
                    items = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, oldItems[$0.id] ?? Item($0.id)) })
                    presentation = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                    func tree(_ nodes: [VectorNode]) -> [Item] { nodes.reversed().compactMap { node in
                        guard let item = items[node.id] else { return nil }
                        item.children = tree(node.children); return item
                    } }
                    roots = tree(project.rootNodes)
                    lastRows = rows
                    let origin = outline.enclosingScrollView?.contentView.bounds.origin
                    outline.reloadData()
                    for id in index.order where session.expandedNodes.contains(id) { if let item = items[id] { outline.expandItem(item) } }
                    if let origin { outline.enclosingScrollView?.contentView.scroll(to: origin) }
                }
            }
            for id in index.order where index.nodes[id]?.kind != .object {
                guard let item = items[id] else { continue }
                if session.expandedNodes.contains(id), !outline.isItemExpanded(item) { outline.expandItem(item) }
                else if !session.expandedNodes.contains(id), outline.isItemExpanded(item) { outline.collapseItem(item) }
            }
            let selected = IndexSet(session.selection.compactMap { id in items[id].flatMap { item in
                let row = outline.row(forItem: item); return row >= 0 ? row : nil
            } })
            if outline.selectedRowIndexes != selected { outline.selectRowIndexes(selected, byExtendingSelection: false) }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Item)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Item)?.children ?? roots)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? Item else { return false }; return presentation[item.id]?.kind != .object
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item, let row = presentation[item.id] else { return nil }
            let key = NSUserInterfaceItemIdentifier("layer-cell")
            let cell = (outlineView.makeView(withIdentifier: key, owner: self) as? LayerCell) ?? LayerCell()
            cell.identifier = key
            cell.name.stringValue = row.name
            cell.name.textColor = row.effectiveHidden ? .secondaryLabelColor : .labelColor
            cell.icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.kind.rawValue)
            cell.icon.contentTintColor = row.kind == .object ? row.color.nsColor : NSColor(PaperTexture.accent)
            cell.lock.nodeID = row.id; cell.eye.nodeID = row.id
            cell.lock.image = NSImage(systemSymbolName: row.effectiveLocked ? "lock.fill" : "lock.open", accessibilityDescription: nil)
            cell.eye.image = NSImage(systemSymbolName: row.effectiveHidden ? "eye.slash" : "eye", accessibilityDescription: nil)
            cell.lock.target = self; cell.lock.action = #selector(toggleLock(_:))
            cell.eye.target = self; cell.eye.action = #selector(toggleVisibility(_:))
            cell.lock.toolTip = "\(row.locked ? "Unlock" : "Lock") \(row.name)\(row.effectiveLocked && !row.locked ? " (also locked by parent)" : "")"
            cell.eye.toolTip = "\(row.visible ? "Hide" : "Show") \(row.name)"
            cell.lock.setAccessibilityLabel(cell.lock.toolTip); cell.eye.setAccessibilityLabel(cell.eye.toolTip)
            cell.toolTip = row.kind == .group ? "Double-click to edit inside \(row.name). Drag to a layer or group to move it." : "Select \(row.name). Rename in Properties. Drag to a layer or group to move it."
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline else { return }
            session.selectFromLayers(Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Item)?.id }))
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !updating, let item = notification.userInfo?["NSObject"] as? Item else { return }
            session.expandedNodes.insert(item.id)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !updating, let item = notification.userInfo?["NSObject"] as? Item else { return }
            session.expandedNodes.remove(item.id)
        }
        @objc func openGroup(_ sender: Any?) {
            guard let outline, let item = outline.item(atRow: outline.clickedRow) as? Item else { return }
            session.enterGroup(item.id)
        }
        @objc func toggleLock(_ sender: LayerButton) { if let id = sender.nodeID { session.toggleNode(id, visibility: false) } }
        @objc func toggleVisibility(_ sender: LayerButton) { if let id = sender.nodeID { session.toggleNode(id, visibility: true) } }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let item = item as? Item else { return nil }
            let payload = NSPasteboardItem()
            payload.setString(session.dragSessionID.uuidString + ":" + item.id.uuidString, forType: Self.dragType)
            return payload
        }
        private func draggedIDs(_ info: NSDraggingInfo) -> Set<UUID>? {
            guard let payloads = info.draggingPasteboard.pasteboardItems, !payloads.isEmpty else { return nil }
            var ids: Set<UUID> = []
            for payload in payloads {
                guard let value = payload.string(forType: Self.dragType) else { return nil }
                let parts = value.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0] == session.dragSessionID.uuidString,
                      let id = UUID(uuidString: String(parts[1])) else { return nil }
                ids.insert(id)
            }
            return ids
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex childIndex: Int) -> NSDragOperation {
            let row = outlineView.row(at: outlineView.convert(info.draggingLocation, from: nil))
            let hovered = row >= 0 ? outlineView.item(atRow: row) as? Item : nil
            let destination = hovered ?? (item as? Item)
            guard let ids = draggedIDs(info), session.canMove(ids, to: destination?.id) else { return [] }
            // Dropping onto a container appends at its front. Front/back commands reorder siblings.
            outlineView.setDropItem(destination, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int) -> Bool {
            guard let ids = draggedIDs(info), session.canMove(ids, to: (item as? Item)?.id) else { return false }
            session.moveNodes(ids, to: (item as? Item)?.id); return true
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, let item = outline.item(atRow: outline.clickedRow) as? Item else { return }
            let index = session.document.hierarchyIndex
            guard let node = index.nodes[item.id] else { return }
            let ids = session.selection.contains(item.id) ? session.selection : [item.id]
            func add(_ title: String, enabled: Bool = true, to target: NSMenu? = nil, action: @escaping () -> Void) {
                let entry = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = LayerMenuAction(action); entry.isEnabled = enabled
                (target ?? menu).addItem(entry)
            }
            menu.autoenablesItems = false
            if node.kind == .group {
                add("Edit Inside Group", enabled: !index.hidden.contains(item.id) && !index.locked.contains(item.id)) { [weak self] in self?.session.enterGroup(item.id) }
                add("Ungroup", enabled: index.canEdit(item.id)) { [weak self] in self?.session.selectFromLayers(ids); self?.session.ungroupSelection() }
            }
            if node.kind == .layer {
                add("New Sublayer", enabled: index.canEdit(item.id)) { [weak self] in self?.session.newLayer(inside: item.id) }
            }
            add("Group Selection", enabled: session.canGroup && session.selection.contains(item.id)) { [weak self] in self?.session.groupSelection() }
            let move = NSMenu(title: "Move to Layer"); move.autoenablesItems = false
            let entry = NSMenuItem(title: "Move to Layer", action: nil, keyEquivalent: ""); entry.submenu = move; menu.addItem(entry)
            add("Document Root", enabled: session.canMove(ids, to: nil), to: move) { [weak self] in self?.session.moveNodes(ids, to: nil) }
            for id in index.order where index.nodes[id]?.kind == .layer {
                add(index.nodes[id]!.name, enabled: session.canMove(ids, to: id), to: move) { [weak self] in self?.session.moveNodes(ids, to: id) }
            }
            menu.addItem(.separator())
            add("Duplicate", enabled: index.canEdit(item.id)) { [weak self] in self?.session.selectFromLayers(ids); self?.session.duplicate() }
            add("Bring to Front", enabled: index.canEdit(item.id)) { [weak self] in self?.session.selectFromLayers(ids); self?.session.reorder(true) }
            add("Send to Back", enabled: index.canEdit(item.id)) { [weak self] in self?.session.selectFromLayers(ids); self?.session.reorder(false) }
            add("Delete", enabled: index.canEdit(item.id)) { [weak self] in self?.session.selectFromLayers(ids); self?.session.deleteSelection() }
        }
        @objc func runMenuAction(_ item: NSMenuItem) { (item.representedObject as? LayerMenuAction)?.run() }
    }
}

private final class LayerMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
final class LayerButton: NSButton { var nodeID: UUID? }
private final class LayerCell: NSTableCellView {
    let icon = NSImageView(), name = NSTextField(labelWithString: "")
    let lock = LayerButton(), eye = LayerButton()
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        for button in [lock, eye] { button.isBordered = false; button.bezelStyle = .inline; button.imagePosition = .imageOnly; button.contentTintColor = .secondaryLabelColor; button.setButtonType(.momentaryPushIn) }
        let stack = NSStackView(views: [icon, name, lock, eye]); stack.orientation = .horizontal; stack.distribution = .fill; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            lock.widthAnchor.constraint(equalToConstant: 18), lock.heightAnchor.constraint(equalToConstant: 20),
            eye.widthAnchor.constraint(equalToConstant: 18), eye.heightAnchor.constraint(equalToConstant: 20)
        ])
        textField = name; imageView = icon
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
private final class LayerOutlineView: NSOutlineView {
    let session: EditorSession
    init(session: EditorSession) { self.session = session; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, session.isolatedGroupID != nil { session.exitGroup() }
        else if [51, 117].contains(event.keyCode), !event.modifierFlags.contains(.command) { session.deleteSelection() }
        else { super.keyDown(with: event) }
    }
    override func selectAll(_ sender: Any?) { session.selectAll() }
    @objc func copy(_ sender: Any?) { session.copySelection() }
    @objc func cut(_ sender: Any?) { session.copySelection(); session.deleteSelection() }
    @objc func paste(_ sender: Any?) { session.pasteSelection() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)) { return !session.selection.isEmpty }
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.data(forType: EditorSession.vectorPasteboard) != nil }
        return true
    }
}
