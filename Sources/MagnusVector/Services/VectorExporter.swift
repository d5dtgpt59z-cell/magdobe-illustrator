import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable {
    case svg, pdf, png
    var contentType: UTType { switch self { case .svg: .svg; case .pdf: .pdf; case .png: .png } }
}

enum VectorRenderer {
    static func draw(_ shape: VectorShape, in context: CGContext) {
        guard shape.visible else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setAlpha(shape.opacity)
        if shape.kind == .text {
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: shape.fontSize, weight: .regular), .foregroundColor: (shape.fill ?? .ink).nsColor, .paragraphStyle: style]
            (shape.text as NSString).draw(in: shape.bounds, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if let fill = shape.fill { context.addPath(shape.cgPath); context.setFillColor(fill.nsColor.cgColor); context.fillPath() }
        if let stroke = shape.stroke, shape.strokeWidth > 0 {
            context.addPath(shape.cgPath); context.setStrokeColor(stroke.nsColor.cgColor); context.setLineWidth(shape.strokeWidth); context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
        }
    }
    static func draw(_ project: VectorProject, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: CGRect(x: 0, y: 0, width: project.width, height: project.height))
        for shape in project.shapes { draw(shape, in: context) }
    }
}

enum VectorExporter {
    static func escaped(_ text: String) -> String { SVGExporter.escape(text) }
    static func number(_ value: Double) -> String { SVGExporter.number(value) }
    static func svg(_ project: VectorProject) throws -> String {
        String(decoding: try SVGExporter.data(project), as: UTF8.self)
    }
    static func pathData(_ shape: VectorShape) -> String { SVGExporter.pathData(shape) }
    static func data(_ project: VectorProject, format: ExportFormat) throws -> Data {
        _ = try project.validated()
        if format == .svg { return try SVGExporter.data(project) }
        let rect = CGRect(x: 0, y: 0, width: project.width, height: project.height)
        if format == .pdf {
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data) else { throw CocoaError(.fileWriteUnknown) }
            var mediaBox = rect
            guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw CocoaError(.fileWriteUnknown) }
            context.beginPDFPage(nil); context.translateBy(x: 0, y: rect.height); context.scaleBy(x: 1, y: -1)
            VectorRenderer.draw(project, in: context); context.endPDFPage(); context.closePDF()
            return data as Data
        }
        guard project.width * project.height <= 64_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(project.width)), pixelsHigh: Int(ceil(project.height)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteOutOfSpace) }
        let context = graphics.cgContext
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh)); context.scaleBy(x: 1, y: -1)
        VectorRenderer.draw(project, in: context)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
