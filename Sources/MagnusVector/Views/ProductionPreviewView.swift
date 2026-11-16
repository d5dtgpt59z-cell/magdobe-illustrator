import AppKit
import SwiftUI

/// A scaled preview of the same uniform placement matrix used by production SVG export.
struct ProductionPreviewView: View {
    let project: VectorProject
    let spec: ProductionSpec
    @State private var thumbnail: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DELIVERY PREVIEW").font(.system(size: 10, weight: .semibold)).tracking(1)
            GeometryReader { proxy in
                if let layout = try? spec.layout(for: project) {
                    let factor = min(proxy.size.width / spec.bleedWidthMM, proxy.size.height / spec.bleedHeightMM)
                    let width = spec.bleedWidthMM * factor, height = spec.bleedHeightMM * factor
                    let pt = ProductionSpec.pointsPerMM
                    ZStack(alignment: .topLeading) {
                        Color.white
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().frame(width: layout.width / pt * factor, height: layout.height / pt * factor)
                                .offset(x: layout.x / pt * factor, y: layout.y / pt * factor)
                        }
                        Rectangle().stroke(.red.opacity(0.8), lineWidth: 1)
                        Rectangle().stroke(.blue, lineWidth: 1).frame(width: spec.trimWidthMM * factor, height: spec.trimHeightMM * factor)
                            .offset(x: spec.bleedMM * factor, y: spec.bleedMM * factor)
                        Rectangle().stroke(.green, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: spec.safeRect.width * factor, height: spec.safeRect.height * factor)
                            .offset(x: spec.safeRect.minX * factor, y: spec.safeRect.minY * factor)
                    }.frame(width: width, height: height).clipped().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Text("Enter valid physical dimensions to preview placement.").font(.caption).foregroundStyle(.secondary) }
            }.frame(height: 300).padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            Text("Red: bleed · Blue: trim · Green: safe inset").font(.caption2).foregroundStyle(.secondary)
            Text("Guides appear only here; they are not printed in the SVG.").font(.caption2).foregroundStyle(.secondary)
            Text("RGB placement preview; the printed CMYK color is not simulated.").font(.caption2).foregroundStyle(.secondary)
        }.task {
            let snapshot = project
            let image = await Task.detached(priority: .utility) { Self.render(snapshot) }.value
            if !Task.isCancelled { thumbnail = image }
        }
    }
    nonisolated private static func render(_ project: VectorProject) -> NSImage? {
        let scale = min(500 / project.width, 500 / project.height)
        let w = max(1, Int(ceil(project.width * scale))), h = max(1, Int(ceil(project.height * scale)))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: Double(h)); context.scaleBy(x: scale, y: -scale)
        VectorRenderer.draw(project, in: context)
        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: project.width, height: project.height)) }
    }
}
