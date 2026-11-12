import Foundation

/// Geometry stays in `shapes`; nodes reference each object exactly once, in back-to-front order.
/// A nil hierarchy is the original v1 flat document. The first structural edit upgrades to v2.
struct VectorNode: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case object, group, layer }
    var id: UUID = UUID()
    var kind: Kind
    var name: String = ""
    var visible = true
    var locked = false
    var children: [VectorNode] = []

    static func object(_ id: UUID) -> VectorNode { VectorNode(id: id, kind: .object) }
    var objectIDs: [UUID] { kind == .object ? [id] : children.flatMap(\.objectIDs) }
}

/// One linear traversal supplies ancestry, inherited state, and ordering without copying geometry.
struct HierarchyIndex {
    var nodes: [UUID: VectorNode] = [:]
    var parents: [UUID: UUID] = [:]
    var order: [UUID] = []
    private var positions: [UUID: Int] = [:]
    var hidden: Set<UUID> = []
    var locked: Set<UUID> = []
    var blockedContainers: Set<UUID> = []
    var shapeIndices: [UUID: Int] = [:]

    init(_ project: VectorProject) {
        for (i, shape) in project.shapes.enumerated() { shapeIndices[shape.id] = i }
        func visit(_ items: [VectorNode], parent: UUID?, hiddenAncestor: Bool, lockedAncestor: Bool) {
            for node in items {
                nodes[node.id] = node; parents[node.id] = parent; positions[node.id] = order.count; order.append(node.id)
                let shape = shapeIndices[node.id].map { project.shapes[$0] }
                let isHidden = hiddenAncestor || !(shape?.visible ?? node.visible)
                let isLocked = lockedAncestor || (shape?.locked ?? node.locked)
                if isHidden { hidden.insert(node.id) }
                if isLocked { locked.insert(node.id) }
                visit(node.children, parent: node.id, hiddenAncestor: isHidden, lockedAncestor: isLocked)
            }
        }
        visit(project.rootNodes, parent: nil, hiddenAncestor: false, lockedAncestor: false)
        for id in locked { blockedContainers.formUnion(ancestors(of: id)) }
    }
    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = [], next = parents[id]
        while let parent = next { result.append(parent); next = parents[parent] }
        return result
    }
    func roots(in selection: Set<UUID>) -> [UUID] {
        selection.filter { nodes[$0] != nil && !ancestors(of: $0).contains(where: selection.contains) }
            .sorted { positions[$0, default: 0] < positions[$1, default: 0] }
    }
    func objectIDs(in selection: Set<UUID>) -> Set<UUID> {
        Set(roots(in: selection).flatMap { nodes[$0]?.objectIDs ?? [] })
    }
    func canEdit(_ id: UUID) -> Bool {
        guard nodes[id] != nil, !locked.contains(id), !hidden.contains(id) else { return false }
        // Never partially transform/delete a container around a locked descendant.
        return !blockedContainers.contains(id)
    }
    func canvasTarget(for id: UUID, inside scope: UUID?) -> UUID? {
        guard !hidden.contains(id), !locked.contains(id) else { return nil }
        let chain = ancestors(of: id)
        if let scope, !chain.contains(scope) { return nil }
        let local = Array(chain.prefix { $0 != scope })
        return local.reversed().first { nodes[$0]?.kind == .group } ?? id
    }
}

extension VectorProject {
    var rootNodes: [VectorNode] { hierarchy ?? shapes.map { .object($0.id) } }
    var hierarchyIndex: HierarchyIndex { HierarchyIndex(self) }

    /// Structural mutations must use this entry point, keeping the established renderer order intact.
    mutating func updateHierarchy(_ mutation: (inout [VectorNode]) -> Void) {
        var roots = rootNodes
        mutation(&roots)
        hierarchy = roots; version = 2
        let lookup = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, $0) })
        shapes = roots.flatMap(\.objectIDs).compactMap { lookup[$0] }
    }
    mutating func appendShapes(_ incoming: [VectorShape], to parent: UUID? = nil) {
        guard !incoming.isEmpty else { return }
        if hierarchy == nil, parent == nil { shapes.append(contentsOf: incoming); return }
        let roots = rootNodes
        shapes.append(contentsOf: incoming)
        hierarchy = roots
        updateHierarchy { nodes in
            Self.editChildren(in: &nodes, of: parent) { $0.append(contentsOf: incoming.map { .object($0.id) }) }
        }
    }
    mutating func removeNodes(_ ids: Set<UUID>) {
        if hierarchy == nil { shapes.removeAll { ids.contains($0.id) }; return }
        updateHierarchy { Self.remove(ids, from: &$0) }
    }
    static func editChildren(in nodes: inout [VectorNode], of parent: UUID?, _ edit: (inout [VectorNode]) -> Void) {
        guard let parent else { edit(&nodes); return }
        for i in nodes.indices {
            if nodes[i].id == parent { edit(&nodes[i].children); return }
            editChildren(in: &nodes[i].children, of: parent, edit)
        }
    }
    static func editNode(_ id: UUID, in nodes: inout [VectorNode], _ edit: (inout VectorNode) -> Void) {
        for i in nodes.indices {
            if nodes[i].id == id { edit(&nodes[i]); return }
            editNode(id, in: &nodes[i].children, edit)
        }
    }
    static func remove(_ ids: Set<UUID>, from nodes: inout [VectorNode]) {
        nodes.removeAll { ids.contains($0.id) }
        for i in nodes.indices { remove(ids, from: &nodes[i].children) }
    }
    func validateHierarchy() throws {
        guard let hierarchy else {
            guard version == 1 else { throw ValidationError.invalidHierarchy }
            return
        }
        guard version == 2 else { throw ValidationError.invalidHierarchy }
        let objects = Set(shapes.map(\.id))
        var seen: Set<UUID> = [], ordered: [UUID] = []
        func visit(_ nodes: [VectorNode], depth: Int, inGroup: Bool) throws {
            guard depth <= 64 else { throw ValidationError.invalidHierarchy }
            for node in nodes {
                guard seen.insert(node.id).inserted, seen.count <= 200_000 else { throw ValidationError.invalidHierarchy }
                if node.kind == .object {
                    guard objects.contains(node.id), node.children.isEmpty, node.visible, !node.locked else { throw ValidationError.invalidHierarchy }
                    ordered.append(node.id)
                } else {
                    guard !objects.contains(node.id), !(inGroup && node.kind == .layer) else { throw ValidationError.invalidHierarchy }
                    try visit(node.children, depth: depth + 1, inGroup: inGroup || node.kind == .group)
                }
            }
        }
        try visit(hierarchy, depth: 0, inGroup: false)
        guard ordered == shapes.map(\.id) else { throw ValidationError.invalidHierarchy }
    }
}
