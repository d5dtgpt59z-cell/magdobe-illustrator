import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let magnusVector = UTType(exportedAs: "com.builtbymagnus.vector", conformingTo: .json)
}

final class VectorDocument: ReferenceFileDocument {
    typealias Snapshot = VectorProject
    static var readableContentTypes: [UTType] { [.magnusVector] }
    @Published var project: VectorProject

    init(project: VectorProject = VectorProject()) { self.project = project }
    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        project = try JSONDecoder().decode(VectorProject.self, from: data).validated()
    }
    func snapshot(contentType: UTType) throws -> VectorProject { project }
    func fileWrapper(snapshot: VectorProject, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
    }
}
