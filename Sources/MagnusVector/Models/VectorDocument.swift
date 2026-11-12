import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let magnusVector = UTType(exportedAs: "com.builtbymagnus.vector", conformingTo: .json)
}

final class VectorDocument: ReferenceFileDocument {
    typealias Snapshot = VectorProject
    static var readableContentTypes: [UTType] { [.magnusVector] }
    @Published var project: VectorProject {
        didSet { revision &+= 1; cachedHierarchy = nil }
    }
    private(set) var revision: UInt64 = 0
    private var cachedHierarchy: HierarchyIndex?
    /// UI-derived data is invalidated by edits, never by viewport changes.
    var hierarchyIndex: HierarchyIndex {
        if let cachedHierarchy { return cachedHierarchy }
        let index = project.hierarchyIndex
        cachedHierarchy = index
        return index
    }

    init(project: VectorProject = VectorProject()) { self.project = project }
    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        project = try JSONDecoder().decode(VectorProject.self, from: data).validated()
    }
    func snapshot(contentType: UTType) throws -> VectorProject { project }
    func fileWrapper(snapshot: VectorProject, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
    }
}
