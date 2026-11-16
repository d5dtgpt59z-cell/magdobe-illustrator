import AppKit

struct ProductionPDFDraft {
    var data: Data
    var includedObjectIDs: [UUID]
    var omittedObjectIDs: [UUID]
}

/// A physically sized RGB vector draft. The bundled finalizer performs ICC conversion exactly once.
enum ProductionPDFDraftExporter {
    static func draft(_ project: VectorProject, spec: ProductionSpec, progress: (Int, Int) -> Void = { _, _ in }) throws -> ProductionPDFDraft {
        _ = try project.validated(); _ = try spec.validated()
        let layout = try spec.layout(for: project), pt = ProductionSpec.pointsPerMM
        let index = project.hierarchyIndex
        var included: [UUID] = [], omitted: [UUID] = []
        for shape in project.shapes {
            let role = index.productionRoles[shape.id]
            if !index.hidden.contains(shape.id), role == nil || role == .artwork || role == .barcode { included.append(shape.id) }
            else { omitted.append(shape.id) }
        }
        guard !included.isEmpty else { throw ProductionPDFError.noArtwork }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw CocoaError(.fileWriteUnknown) }
        var media = CGRect(x: 0, y: 0, width: spec.bleedWidthMM * pt, height: spec.bleedHeightMM * pt)
        var trim = CGRect(x: spec.bleedMM * pt, y: spec.bleedMM * pt, width: spec.trimWidthMM * pt, height: spec.trimHeightMM * pt)
        let boxes: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size),
            kCGPDFContextBleedBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size),
            kCGPDFContextTrimBox: Data(bytes: &trim, count: MemoryLayout<CGRect>.size)]
        guard let context = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextTitle: spec.name, kCGPDFContextCreator: "Magdobe Illustrator"] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(boxes as CFDictionary)
        context.translateBy(x: 0, y: media.height); context.scaleBy(x: 1, y: -1)
        context.clip(to: media)
        context.translateBy(x: layout.x, y: layout.y); context.scaleBy(x: layout.scale, y: layout.scale)
        context.clip(to: CGRect(x: 0, y: 0, width: project.width, height: project.height))
        let ids = Set(included)
        progress(0, project.shapes.count)
        for (offset, shape) in project.shapes.enumerated() {
            try Task.checkCancellation()
            if ids.contains(shape.id) {
                if shape.kind == .text {
                    let outline: CGPath
                    do { outline = try SVGTextLayout(shape).outline() }
                    catch SVGExportError.glyphHasNoOutline(let text) {
                        throw ProductionPDFError.settings("A glyph in “\(text.prefix(60))” has no vector outline. Replace that character (for example, a color emoji) before exporting Production PDF. No artwork was rasterized.")
                    }
                    context.saveGState(); context.clip(to: shape.bounds); context.setAlpha(shape.opacity)
                    context.setFillColor((shape.fill ?? .ink).nsColor.cgColor)
                    context.addPath(outline); context.fillPath(); context.restoreGState()
                } else { VectorRenderer.draw(shape, in: context) }
            }
            if offset % 32 == 0 || offset + 1 == project.shapes.count { progress(offset + 1, project.shapes.count) }
        }
        context.endPDFPage(); context.closePDF()
        return ProductionPDFDraft(data: data as Data, includedObjectIDs: included, omittedObjectIDs: omitted)
    }
}
