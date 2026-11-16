import Foundation

extension EditorSession {
    func applyProductionSpec(_ spec: ProductionSpec) throws {
        _ = try spec.validated()
        edit("Production Setup") { $0.production = spec }
    }
    func setProductionRole(_ role: ProductionRole?) {
        guard let node = selectedNode, document.hierarchyIndex.canEdit(node.id) else { return }
        structuralEdit("Production Role") { project in
            project.updateHierarchy { VectorProject.editNode(node.id, in: &$0) { $0.productionRole = role } }
        }
    }
}
