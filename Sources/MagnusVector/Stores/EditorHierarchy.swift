import AppKit

extension EditorSession {
    var selectedNode: VectorNode? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return document.project.hierarchyIndex.nodes[id]
    }
    var editableRoots: [UUID] {
        let index = document.project.hierarchyIndex
        return index.roots(in: selection).filter { index.canEdit($0) }
    }
    var editableShapeIDs: Set<UUID> {
        let index = document.project.hierarchyIndex
        return index.objectIDs(in: Set(index.roots(in: selection).filter { index.canEdit($0) }))
    }
    var canGroup: Bool {
        let index = document.project.hierarchyIndex, roots = index.roots(in: selection)
        guard roots.count >= 2, let first = roots.first else { return false }
        return roots.allSatisfy { index.canEdit($0) && index.nodes[$0]?.kind != .layer && index.parents[$0] == index.parents[first] }
    }
    var canUngroup: Bool {
        let index = document.project.hierarchyIndex
        return index.roots(in: selection).contains { index.nodes[$0]?.kind == .group && index.canEdit($0) }
    }
    func bounds(of ids: Set<UUID>) -> CGRect? {
        document.project.shapes.filter { ids.contains($0.id) }.reduce(nil) { r, s in r.map { $0.union(s.bounds) } ?? s.bounds }
    }
    func reconcileHierarchyState() {
        let index = document.project.hierarchyIndex
        selection.formIntersection(index.nodes.keys)
        if let id = isolatedGroupID, index.nodes[id]?.kind != .group || index.hidden.contains(id) || index.locked.contains(id) { isolatedGroupID = nil }
        if let id = activeLayerID, index.nodes[id]?.kind != .layer { activeLayerID = nil }
        if let scope = isolatedGroupID {
            selection = selection.filter { index.ancestors(of: $0).contains(scope) }
        }
    }
    @discardableResult func structuralEdit(_ name: String, _ mutation: (inout VectorProject) -> Void) -> Bool {
        finishPath()
        var candidate = document.project
        mutation(&candidate)
        do { try candidate.validateHierarchy() }
        catch { self.error = "This change would exceed the supported layer nesting depth or create an invalid hierarchy."; return false }
        edit(name) { $0 = candidate }
        reconcileHierarchyState()
        return true
    }
    func groupSelection() {
        finishPath()
        guard canGroup else { return }
        let index = document.project.hierarchyIndex, roots = index.roots(in: selection)
        let ids = Set(roots), parent = index.parents[roots[0]]
        let group = VectorNode(kind: .group, name: "Group", children: roots.compactMap { index.nodes[$0] })
        structuralEdit("Group") { p in
            p.updateHierarchy { nodes in
                VectorProject.editChildren(in: &nodes, of: parent) { siblings in
                    // Group at the frontmost selected item's slot; selected siblings retain their order.
                    guard let last = siblings.lastIndex(where: { ids.contains($0.id) }) else { return }
                    let insertion = siblings.prefix(last).filter { !ids.contains($0.id) }.count
                    siblings.removeAll { ids.contains($0.id) }; siblings.insert(group, at: insertion)
                }
            }
        }
        if document.project.hierarchyIndex.nodes[group.id] != nil { selection = [group.id]; expandedNodes.insert(group.id) }
    }
    func ungroupSelection() {
        let index = document.project.hierarchyIndex
        let roots = index.roots(in: selection).filter { index.nodes[$0]?.kind == .group && index.canEdit($0) }
        guard !roots.isEmpty else { return }
        let ids = Set(roots)
        let children = Set(roots.flatMap { index.nodes[$0]?.children.map(\.id) ?? [] })
        structuralEdit("Ungroup") { p in
            p.updateHierarchy { nodes in
                func dissolve(_ items: inout [VectorNode]) {
                    for i in items.indices { dissolve(&items[i].children) }
                    items = items.flatMap { ids.contains($0.id) ? $0.children : [$0] }
                }
                dissolve(&nodes)
            }
        }
        selection.subtract(ids); selection.formUnion(children); reconcileHierarchyState()
    }
    func newLayer(inside parent: UUID? = nil) {
        let index = document.project.hierarchyIndex
        if let parent, index.nodes[parent]?.kind != .layer || !index.canEdit(parent) { return }
        let count = index.nodes.values.filter { $0.kind == .layer }.count
        let layer = VectorNode(kind: .layer, name: "Layer \(count + 1)")
        structuralEdit("New Layer") { p in p.updateHierarchy { nodes in
            VectorProject.editChildren(in: &nodes, of: parent) { $0.append(layer) }
        } }
        if document.project.hierarchyIndex.nodes[layer.id] != nil {
            selection = [layer.id]; activeLayerID = layer.id; isolatedGroupID = nil
            expandedNodes.insert(layer.id); if let parent { expandedNodes.insert(parent) }
        }
    }
    func renameSelection(_ name: String) {
        guard let node = selectedNode else { return }
        if node.kind == .object { modifySelection("Rename") { $0.name = name }; return }
        edit("Rename") { p in p.updateHierarchy { VectorProject.editNode(node.id, in: &$0) { $0.name = name } } }
    }
    func toggleNode(_ id: UUID, visibility: Bool) {
        finishPath()
        let index = document.project.hierarchyIndex
        guard let node = index.nodes[id] else { return }
        edit(visibility ? "Toggle Visibility" : "Toggle Lock") { p in
            if node.kind == .object, let i = index.shapeIndices[id] {
                if visibility { p.shapes[i].visible.toggle() } else { p.shapes[i].locked.toggle() }
            } else { p.updateHierarchy { VectorProject.editNode(id, in: &$0) {
                if visibility { $0.visible.toggle() } else { $0.locked.toggle() }
            } } }
        }
        let updated = document.project.hierarchyIndex
        selection = selection.filter { !updated.locked.contains($0) && !updated.hidden.contains($0) }
        reconcileHierarchyState()
    }
    func enterGroup(_ id: UUID) {
        let index = document.project.hierarchyIndex
        guard index.nodes[id]?.kind == .group, !index.locked.contains(id), !index.hidden.contains(id) else { return }
        finishPath(); isolatedGroupID = id; selection = []; selectedAnchor = nil; expandedNodes.insert(id)
    }
    func exitGroup() {
        guard let id = isolatedGroupID else { return }
        finishPath()
        isolatedGroupID = document.project.hierarchyIndex.ancestors(of: id).first { document.project.hierarchyIndex.nodes[$0]?.kind == .group }
        selection = [id]; selectedAnchor = nil
    }
    func selectAll() {
        finishPath()
        let index = document.project.hierarchyIndex
        selection = Set(document.project.shapes.compactMap { index.canvasTarget(for: $0.id, inside: isolatedGroupID) })
    }
    func selectFromLayers(_ ids: Set<UUID>) {
        finishPath(); selection = ids; selectedAnchor = nil
        let index = document.project.hierarchyIndex
        if let scope = isolatedGroupID, ids.contains(where: { $0 == scope || !index.ancestors(of: $0).contains(scope) }) { isolatedGroupID = nil }
        if ids.count == 1, let id = ids.first {
            activeLayerID = ([id] + index.ancestors(of: id)).first { index.nodes[$0]?.kind == .layer }
        }
    }
    struct Destination { var parent: UUID? }
    func insertionDestination() -> Destination? {
        let parent = isolatedGroupID ?? activeLayerID
        if let parent {
            let index = document.project.hierarchyIndex
            guard index.ancestors(of: parent).count < 64 else {
                error = "This container is at the maximum supported nesting depth. Select a shallower layer before drawing."; return nil
            }
            guard index.nodes[parent] != nil, !index.hidden.contains(parent), !index.locked.contains(parent) else {
                error = "The active layer is hidden or locked. Show or unlock it, or select another layer before drawing."; return nil
            }
        }
        return Destination(parent: parent)
    }
    func reorderSelection(_ front: Bool) {
        let ids = Set(editableRoots)
        guard !ids.isEmpty else { return }
        structuralEdit(front ? "Bring to Front" : "Send to Back") { p in p.updateHierarchy { nodes in
            func reorder(_ items: inout [VectorNode]) {
                let chosen = items.filter { ids.contains($0.id) }
                items.removeAll { ids.contains($0.id) }
                items.insert(contentsOf: chosen, at: front ? items.count : 0)
                for i in items.indices { reorder(&items[i].children) }
            }
            reorder(&nodes)
        } }
    }
    func canMove(_ ids: Set<UUID>, to parent: UUID?) -> Bool {
        let index = document.project.hierarchyIndex, roots = index.roots(in: ids)
        guard !roots.isEmpty, roots.allSatisfy({ index.canEdit($0) }) else { return false }
        if let parent {
            guard let target = index.nodes[parent], target.kind != .object, !index.locked.contains(parent), !index.hidden.contains(parent),
                  !roots.contains(parent), !index.ancestors(of: parent).contains(where: roots.contains) else { return false }
            if target.kind == .group, roots.contains(where: { index.nodes[$0]?.kind == .layer }) { return false }
        }
        return true
    }
    func moveNodes(_ ids: Set<UUID>, to parent: UUID?) {
        guard canMove(ids, to: parent) else { return }
        let index = document.project.hierarchyIndex, roots = index.roots(in: ids)
        let moved = roots.compactMap { index.nodes[$0] }
        structuralEdit("Move to Layer or Group") { p in p.updateHierarchy { nodes in
            VectorProject.remove(Set(roots), from: &nodes)
            VectorProject.editChildren(in: &nodes, of: parent) { $0.append(contentsOf: moved) }
        } }
        if let parent { expandedNodes.insert(parent) }
        if let scope = isolatedGroupID, roots.contains(scope) { isolatedGroupID = nil }
    }
    func selectionProject(_ ids: Set<UUID>? = nil) -> VectorProject? {
        let index = document.project.hierarchyIndex, roots = index.roots(in: ids ?? selection)
        guard !roots.isEmpty else { return nil }
        var nodes = roots.compactMap { index.nodes[$0] }
        // Preserve effective visibility/locking when copying a child out of its ancestors.
        let included = Set(nodes.flatMap(\.objectIDs))
        var shapes = document.project.shapes.filter { included.contains($0.id) }
        let rootObjects = Set(nodes.filter { $0.kind == .object }.map(\.id))
        for i in shapes.indices where rootObjects.contains(shapes[i].id) {
            shapes[i].visible = !index.hidden.contains(shapes[i].id)
            shapes[i].locked = index.locked.contains(shapes[i].id)
        }
        for i in nodes.indices where nodes[i].kind != .object {
            nodes[i].visible = !index.hidden.contains(nodes[i].id)
            nodes[i].locked = index.locked.contains(nodes[i].id)
        }
        return VectorProject(version: 2, width: document.project.width, height: document.project.height, shapes: shapes, hierarchy: nodes)
    }
    func remapped(_ source: VectorProject, offset: CGSize, suffix: String) -> VectorProject {
        var result = source
        let ids = Dictionary(uniqueKeysWithValues: source.hierarchyIndex.order.map { ($0, UUID()) })
        for i in result.shapes.indices {
            result.shapes[i].id = ids[result.shapes[i].id]!
            result.shapes[i].translate(offset)
            result.shapes[i].contours = result.shapes[i].contours.map { $0.map { a in var a = a; a.id = UUID(); return a } }
        }
        if let hierarchy = source.hierarchy {
            func clone(_ nodes: [VectorNode]) -> [VectorNode] { nodes.map { n in
                var n = n; n.id = ids[n.id]!; n.children = clone(n.children); return n
            } }
            result.hierarchy = clone(hierarchy)
        }
        for node in result.rootNodes {
            if node.kind == .object, let i = result.shapes.firstIndex(where: { $0.id == node.id }) { result.shapes[i].name += suffix }
            else if result.hierarchy != nil { VectorProject.editNode(node.id, in: &result.hierarchy!) { $0.name += suffix } }
        }
        return result
    }
    func merge(_ incoming: VectorProject, into project: inout VectorProject, parent: UUID?) {
        if incoming.hierarchy == nil { project.appendShapes(incoming.shapes, to: parent); return }
        let roots = project.rootNodes
        project.shapes.append(contentsOf: incoming.shapes); project.hierarchy = roots
        project.updateHierarchy { VectorProject.editChildren(in: &$0, of: parent) { $0.append(contentsOf: incoming.rootNodes) } }
    }
    func pasteProject(_ source: VectorProject) {
        guard (try? source.validated()) != nil, let destination = insertionDestination() else { return }
        let copy = remapped(source, offset: CGSize(width: 20, height: 20), suffix: "")
        // A layer may only be pasted into the document or another layer.
        if let parent = destination.parent, document.project.hierarchyIndex.nodes[parent]?.kind == .group,
           copy.rootNodes.contains(where: { $0.kind == .layer }) { error = "Layers cannot be placed inside a group. Exit the group before pasting a layer."; return }
        if structuralEdit("Paste", { merge(copy, into: &$0, parent: destination.parent) }) {
            selection = Set(copy.rootNodes.map(\.id)); reconcileHierarchyState()
        }
    }
    func duplicateSelection() {
        let roots = editableRoots
        guard let source = selectionProject(Set(roots)) else { return }
        let copy = remapped(source, offset: CGSize(width: 20, height: 20), suffix: " copy")
        let copies = Dictionary(uniqueKeysWithValues: zip(roots, copy.rootNodes))
        if structuralEdit("Duplicate", { p in
            let oldRoots = p.rootNodes
            p.shapes.append(contentsOf: copy.shapes); p.hierarchy = oldRoots
            p.updateHierarchy { nodes in
                func insertCopies(_ items: inout [VectorNode]) {
                    for i in items.indices { insertCopies(&items[i].children) }
                    items = items.flatMap { node in copies[node.id].map { [node, $0] } ?? [node] }
                }
                insertCopies(&nodes)
            }
        }) {
            selection = Set(copy.rootNodes.map(\.id)); reconcileHierarchyState()
        }
    }
}
