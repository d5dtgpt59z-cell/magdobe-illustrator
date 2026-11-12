import AppKit

/// Immutable display data, rebuilt only when the document changes. Exports never use this cache.
final class CanvasArtwork: @unchecked Sendable {
    struct Entry {
        let shape: VectorShape
        let path: CGPath
        let bounds: CGRect
    }
    let entries: [Entry]
    let artboard: CGRect

    init(_ project: VectorProject, hierarchy: HierarchyIndex) {
        artboard = CGRect(x: 0, y: 0, width: project.width, height: project.height)
        entries = project.shapes.compactMap { shape in
            guard shape.visible, !hierarchy.hidden.contains(shape.id) else { return nil }
            let path = shape.cgPath
            let padding = (shape.stroke == nil ? 0 : shape.strokeWidth / 2) + 1
            let bounds = (shape.kind == .text ? shape.bounds : path.boundingBoxOfPath).insetBy(dx: -padding, dy: -padding)
            return Entry(shape: shape, path: path, bounds: bounds)
        }
    }

    func draw(in context: CGContext, viewport: CGRect) {
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: artboard)
        for entry in entries where entry.bounds.intersects(viewport) {
            if Task.isCancelled { return }
            VectorRenderer.draw(entry.shape, in: context, path: entry.path)
        }
    }

    func viewportImage(_ viewport: CGRect, pixelsPerUnit: Double) -> CGImage? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let scale = min(pixelsPerUnit, sqrt(16_000_000 / (viewport.width * viewport.height)))
        let width = max(1, Int(ceil(viewport.width * scale))), height = max(1, Int(ceil(viewport.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: CGFloat(width) / viewport.width, y: -CGFloat(height) / viewport.height)
        context.translateBy(x: -viewport.minX, y: -viewport.minY)
        draw(in: context, viewport: viewport)
        return Task.isCancelled ? nil : context.makeImage()
    }

    /// A bounded navigation preview only. At rest the canvas draws the original paths.
    func navigationPreview() -> CGImage? {
        let scale = min(2, sqrt(8_000_000 / (artboard.width * artboard.height)), 4096 / max(artboard.width, artboard.height))
        let width = max(1, Int(ceil(artboard.width * scale))), height = max(1, Int(ceil(artboard.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        context.clip(to: artboard)
        for entry in entries {
            if Task.isCancelled { return nil }
            VectorRenderer.draw(entry.shape, in: context, path: entry.path)
        }
        return context.makeImage()
    }
}
