import XCTest
import AppKit
@testable import MagnusVector

final class CanvasRenderingTests: XCTestCase {
    @MainActor func testDocumentCacheInvalidatesOnEditsAndUndoButNotNavigation() {
        let shape = VectorShape(name: "Editable", kind: .rectangle, width: 40, height: 30)
        let document = VectorDocument(project: VectorProject(shapes: [shape]))
        let session = EditorSession(document: document)
        let revision = document.revision
        XCTAssertFalse(document.hierarchyIndex.hidden.contains(shape.id))
        session.zoom = 3; session.pan = CGSize(width: 140, height: -20)
        XCTAssertEqual(document.revision, revision)
        session.edit("Hide") { $0.shapes[0].visible = false }
        XCTAssertGreaterThan(document.revision, revision)
        XCTAssertTrue(document.hierarchyIndex.hidden.contains(shape.id))
        XCTAssertTrue(CanvasArtwork(document.project, hierarchy: document.hierarchyIndex).entries.isEmpty)
        session.undo()
        XCTAssertFalse(document.hierarchyIndex.hidden.contains(shape.id))
        XCTAssertEqual(CanvasArtwork(document.project, hierarchy: document.hierarchyIndex).entries.count, 1)
    }

    func testCachedRenderingMatchesVectorRendererIncludingClippingStrokeAndTransparency() throws {
        let shapes = [
            VectorShape(name: "Background", kind: .rectangle, width: 64, height: 64, fill: .paper),
            VectorShape(name: "Alpha", kind: .ellipse, x: 8, y: 4, width: 50, height: 40, fill: .violet, stroke: .ink, strokeWidth: 7, opacity: 0.4),
            VectorShape(name: "Stroke crosses viewport", kind: .rectangle, x: 65, y: 10, width: 8, height: 35, fill: nil, stroke: .ink, strokeWidth: 12),
            VectorShape(name: "Hidden", kind: .rectangle, width: 60, height: 60, fill: .ink)
        ]
        var project = VectorProject(width: 64, height: 64, shapes: shapes)
        project.version = 2
        project.hierarchy = shapes.dropLast().map { .object($0.id) } + [VectorNode(kind: .layer, visible: false, children: [.object(shapes.last!.id)])]
        let artwork = CanvasArtwork(project, hierarchy: project.hierarchyIndex)
        XCTAssertEqual(artwork.entries.count, 3)
        func pixels(cached: Bool) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if cached { artwork.draw(in: context, viewport: artwork.artboard) }
            else { VectorRenderer.draw(project, in: context) }
            return Data(bytes: try XCTUnwrap(context.data), count: 64 * 256)
        }
        XCTAssertEqual(try pixels(cached: true), try pixels(cached: false))
        let preview = try XCTUnwrap(artwork.navigationPreview())
        XCTAssertLessThanOrEqual(preview.width * preview.height, 8_010_000)
        let viewport = CGRect(x: 8, y: 4, width: 28, height: 24)
        let cropped = try XCTUnwrap(artwork.viewportImage(viewport, pixelsPerUnit: 2))
        let reference = try XCTUnwrap(CGContext(data: nil, width: 56, height: 48, bitsPerComponent: 8, bytesPerRow: cropped.bytesPerRow,
                                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reference.translateBy(x: 0, y: 48); reference.scaleBy(x: 2, y: -2); reference.translateBy(x: -8, y: -4)
        VectorRenderer.draw(project, in: reference)
        let actual = try XCTUnwrap(cropped.dataProvider?.data) as Data
        XCTAssertEqual(actual, Data(bytes: try XCTUnwrap(reference.data), count: cropped.bytesPerRow * 48))
        let svg = try VectorExporter.svg(project)
        XCTAssertFalse(svg.contains("<image"))
    }

    func testSelectionKeepsStackingOrderWithLargeFlatDocument() {
        let shapes = (0..<65_496).map { VectorShape(name: "Shape \($0)", kind: .rectangle, x: Double($0 % 200), y: Double($0 / 200), width: 1, height: 1) }
        let project = VectorProject(shapes: shapes), index = project.hierarchyIndex
        let selected: Set<UUID> = [shapes[65_495].id, shapes[2].id, shapes[900].id]
        XCTAssertEqual(index.roots(in: selected), [shapes[2].id, shapes[900].id, shapes[65_495].id])
        XCTAssertEqual(index.objectIDs(in: selected), selected)
        XCTAssertTrue(index.roots(in: []).isEmpty)
    }
}
