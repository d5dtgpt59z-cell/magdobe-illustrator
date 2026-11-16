import Foundation

extension EditorSession {
    func applyProductionSpec(_ spec: ProductionSpec, iccProfile: Data? = nil) throws {
        _ = try spec.validated()
        var asset = iccProfile
        if let descriptor = spec.pdf?.iccProfile {
            if asset == nil { asset = document.project.productionICCProfile }
            guard let data = asset else { throw ProductionPDFError.missingProfile }
            _ = try ProductionICCProfile.validate(data, expected: descriptor)
        } else { asset = nil }
        edit("Production Setup") { $0.production = spec; $0.productionICCProfile = asset }
    }
    func setProductionRole(_ role: ProductionRole?) {
        guard let node = selectedNode, document.hierarchyIndex.canEdit(node.id) else { return }
        structuralEdit("Production Role") { project in
            project.updateHierarchy { VectorProject.editNode(node.id, in: &$0) { $0.productionRole = role } }
        }
    }
}
