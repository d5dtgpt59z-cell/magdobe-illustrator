import Foundation

/// A physical-size delivery copy. Original coordinates, paths and IDs are never rewritten.
enum ProductionSVGExporter {
    static func data(_ project: VectorProject, spec: ProductionSpec, options: SVGExportOptions = .init(), progress: (Int, Int) -> Void = { _, _ in }) throws -> Data {
        var data = Data()
        try serialize(project, spec: spec, options: options, emit: { data.append(contentsOf: $0.utf8) }, progress: progress)
        return data
    }
    static func write(_ project: VectorProject, spec: ProductionSpec, to url: URL, options: SVGExportOptions = .init(), progress: (Int, Int) -> Void = { _, _ in }) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".magdobe-production-\(UUID().uuidString).svg.tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try FileHandle(forWritingTo: temp)
        do {
            try serialize(project, spec: spec, options: options, emit: { try file.write(contentsOf: Data($0.utf8)) }, progress: progress)
            try Task.checkCancellation(); try file.synchronize(); try file.close()
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) }
            else { try FileManager.default.moveItem(at: temp, to: url) }
        } catch { try? file.close(); throw error }
    }
    private static func serialize(_ project: VectorProject, spec: ProductionSpec, options: SVGExportOptions, emit: (String) throws -> Void, progress: (Int, Int) -> Void) throws {
        let layout = try spec.layout(for: project)
        let job = try spec.jobData(), pt = ProductionSpec.pointsPerMM
        let n = SVGExporter.number
        let width = spec.bleedWidthMM * pt, height = spec.bleedHeightMM * pt
        try emit("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        try emit("<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(n(spec.bleedWidthMM))mm\" height=\"\(n(spec.bleedHeightMM))mm\" viewBox=\"0 0 \(n(width)) \(n(height))\" overflow=\"hidden\" data-production-placement=\"\(spec.placement.rawValue)\">\n")
        try emit("<title>\(SVGExporter.escape(spec.name))</title>\n")
        try emit("<desc>Physical-size RGB vector artwork. Printer requirements are metadata, not PDF/X certification, CMYK conversion or manufacturing approval.</desc>\n")
        try emit("<metadata id=\"magdobe-production-job\">\(SVGExporter.escape(String(decoding: job, as: UTF8.self)))</metadata>\n")
        try emit("<defs><clipPath id=\"magdobe_production_bleed_clip\" clipPathUnits=\"userSpaceOnUse\"><rect x=\"0\" y=\"0\" width=\"\(n(width))\" height=\"\(n(height))\"/></clipPath></defs>\n")
        try emit("<g id=\"magdobe_production_placement\" clip-path=\"url(#magdobe_production_bleed_clip)\"><g transform=\"matrix(\(n(layout.scale)) 0 0 \(n(layout.scale)) \(n(layout.x)) \(n(layout.y)))\">\n")
        var editable = options
        editable.entireArtboard = true
        try SVGExporter.serialize(project, options: editable, embedded: true, emit: emit, progress: progress)
        try emit("</g></g></svg>\n")
    }
}
