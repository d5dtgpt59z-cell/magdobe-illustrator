import Foundation
import UniformTypeIdentifiers

enum ArtworkFileFormat: String, CaseIterable, Identifiable {
    case project, svg, pdf, png
    var id: Self { self }
    var title: String { self == .project ? "Editable Project" : rawValue.uppercased() }
    var fileExtension: String { self == .project ? "mvector" : rawValue }
    var contentType: UTType {
        switch self { case .project: .magnusVector; case .svg: .svg; case .pdf: .pdf; case .png: .png }
    }
    var explanation: String {
        switch self {
        case .project: "Keep every object, layer, and editing property. Reopen this project in Magdobe to keep working."
        case .svg: "Editable vector artwork for other design applications. Open in Safari to view it on your Mac."
        case .pdf: "Scalable vector artwork for viewing in Preview, sharing, and printing."
        case .png: "A flat image for Preview, websites, and sharing. Save an editable project to keep working with individual objects."
        }
    }
    var viewerTitle: String {
        switch self { case .project: "Open in Magdobe"; case .svg: "Open in Safari"; case .pdf, .png: "Open in Preview" }
    }
}

enum ArtworkFileWriter {
    /// Writes a value snapshot. Cancellation observed before writing leaves an existing file intact.
    static func write(_ project: VectorProject, format: ArtworkFileFormat, to url: URL,
                      svgOptions: SVGExportOptions = .init(), progress: @escaping (Int, Int) -> Void = { _, _ in }) throws {
        try Task.checkCancellation()
        if format == .svg {
            try SVGExporter.write(project, to: url, options: svgOptions, progress: progress)
            return
        }
        let data: Data
        switch format {
        case .project:
            _ = try project.validated()
            // Compact native JSON keeps dense artwork practical without changing the document format.
            data = try JSONEncoder().encode(project)
        case .pdf: data = try VectorExporter.data(project, format: .pdf)
        case .png: data = try VectorExporter.data(project, format: .png)
        case .svg: return
        }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
