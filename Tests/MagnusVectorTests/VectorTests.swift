import XCTest
import AppKit
@testable import MagnusVector

final class VectorTests: XCTestCase {
    func testArtworkInsertionAdoptsBlankArtboardAndUndoesTogether() {
        let doc = VectorDocument(project: VectorProject(width: 640, height: 480))
        let original = doc.project
        let session = EditorSession(document: doc)
        var shape = VectorShape(name: "Generated path", kind: .rectangle, width: 120, height: 160)
        shape.convertToPath()
        let artwork = VectorProject(width: 120, height: 160, shapes: [shape])
        session.insertArtwork(artwork)
        XCTAssertEqual(doc.project.width, 120)
        XCTAssertEqual(doc.project.height, 160)
        XCTAssertEqual(doc.project.shapes[0].bounds, shape.bounds)
        XCTAssertNotEqual(doc.project.shapes[0].id, shape.id)
        XCTAssertNotEqual(doc.project.shapes[0].anchors[0].id, shape.anchors[0].id)
        if session.history.groupingLevel > 0 { session.history.endUndoGrouping() }
        session.undo()
        XCTAssertEqual(doc.project, original)
        session.redo()
        XCTAssertEqual(doc.project.shapes.count, 1)
        XCTAssertEqual(doc.project.width, 120)
    }
    func testArtworkInsertionPreservesExistingObjectsAndFitsAllContours() throws {
        let existing = VectorShape(name: "Existing", kind: .rectangle, width: 15, height: 20)
        let doc = VectorDocument(project: VectorProject(width: 200, height: 100, shapes: [existing]))
        let session = EditorSession(document: doc)
        var ring = VectorShape(name: "Ring", kind: .path, fill: .ink, stroke: .ink, strokeWidth: 2)
        ring.closed = true
        ring.anchors = [Anchor(CGPoint(x: 0, y: 0)), Anchor(CGPoint(x: 100, y: 0)), Anchor(CGPoint(x: 100, y: 100)), Anchor(CGPoint(x: 0, y: 100))]
        ring.subpaths = [[Anchor(CGPoint(x: 25, y: 25)), Anchor(CGPoint(x: 25, y: 75)), Anchor(CGPoint(x: 75, y: 75)), Anchor(CGPoint(x: 75, y: 25))]]
        let artwork = VectorProject(width: 100, height: 100, shapes: [ring])
        session.insertArtwork(artwork)
        let placed = doc.project.shapes[1]
        XCTAssertEqual(doc.project.shapes[0], existing)
        XCTAssertEqual(placed.bounds, CGRect(x: 57.5, y: 7.5, width: 85, height: 85))
        XCTAssertEqual(placed.strokeWidth, 1.7, accuracy: 0.001)
        XCTAssertFalse(placed.cgPath.contains(CGPoint(x: 100, y: 50)))
        XCTAssertEqual(placed.subpaths?[0][0].point, VectorPoint(78.75, 28.75))
        session.insertArtwork(artwork)
        XCTAssertNoThrow(try doc.project.validated())
        XCTAssertNotEqual(doc.project.shapes[1].id, doc.project.shapes[2].id)
    }
    func testCompoundPathPreservesHolesAndTransformsAllContours() throws {
        var shape = VectorShape(name: "Ring", kind: .path, fill: .ink, stroke: nil)
        shape.closed = true
        shape.anchors = [Anchor(CGPoint(x: 0, y: 0)), Anchor(CGPoint(x: 100, y: 0)), Anchor(CGPoint(x: 100, y: 100)), Anchor(CGPoint(x: 0, y: 100))]
        shape.subpaths = [[Anchor(CGPoint(x: 25, y: 25)), Anchor(CGPoint(x: 25, y: 75)), Anchor(CGPoint(x: 75, y: 75)), Anchor(CGPoint(x: 75, y: 25))]]
        XCTAssertTrue(shape.cgPath.contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(shape.cgPath.contains(CGPoint(x: 50, y: 50)))
        shape.resize(to: CGRect(x: 10, y: 20, width: 200, height: 300))
        shape.translate(CGSize(width: 5, height: 6))
        XCTAssertEqual(shape.subpaths?[0][0].point, VectorPoint(65, 101))
        XCTAssertFalse(shape.cgPath.contains(CGPoint(x: 115, y: 176)))
        XCTAssertEqual(VectorExporter.pathData(shape).components(separatedBy: "M ").count - 1, 2)
        let decoded = try JSONDecoder().decode(VectorShape.self, from: JSONEncoder().encode(shape))
        XCTAssertEqual(decoded, shape)
        let png = try VectorExporter.data(VectorProject(width: 240, height: 350, shapes: [shape]), format: .png)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 115, y: 176)).alphaComponent, 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 25, y: 36)).alphaComponent, 0.9)
    }
    func testOlderProjectsDecodeWithoutSubpaths() throws {
        let shape = VectorShape(name: "Old rectangle", kind: .rectangle)
        let encoded = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(VectorShape.self, from: encoded)
        XCTAssertNil(decoded.subpaths)
        XCTAssertEqual(decoded.contours.count, 1)
    }
    func testProjectRoundTripPreservesCurvesAndAppearance() throws {
        var path = VectorShape(name: "Curve", kind: .path)
        var a = Anchor(CGPoint(x: 10, y: 20)); a.outgoing = VectorPoint(70, 10)
        var b = Anchor(CGPoint(x: 200, y: 150)); b.incoming = VectorPoint(140, 190)
        path.anchors = [a, b]; path.closed = true; path.opacity = 0.4
        let project = VectorProject(shapes: [path])
        let decoded = try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(project)).validated()
        XCTAssertEqual(decoded, project)
        XCTAssertTrue(VectorExporter.pathData(path).contains("C "))
        XCTAssertTrue(VectorExporter.pathData(path).hasSuffix(" Z"))
    }
    func testEllipseConvertsToFourCubicAnchors() {
        var ellipse = VectorShape(name: "Ellipse", kind: .ellipse, x: 50, y: 80, width: 200, height: 100)
        ellipse.convertToPath()
        XCTAssertEqual(ellipse.kind, .path); XCTAssertEqual(ellipse.anchors.count, 4)
        XCTAssertTrue(ellipse.closed)
        XCTAssertEqual(ellipse.bounds.minX, 50, accuracy: 0.001)
        XCTAssertEqual(ellipse.bounds.maxY, 180, accuracy: 0.001)
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 150, y: 130), tolerance: 2))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 50, y: 80), tolerance: 2))
    }
    func testPathResizeTransformsControlHandles() {
        var shape = VectorShape(name: "Path", kind: .rectangle, x: 10, y: 20, width: 100, height: 50)
        shape.convertToPath()
        shape.resize(to: CGRect(x: 20, y: 40, width: 200, height: 150))
        XCTAssertEqual(shape.bounds, CGRect(x: 20, y: 40, width: 200, height: 150))
        shape.translate(CGSize(width: 5, height: -5))
        XCTAssertEqual(shape.bounds.origin, CGPoint(x: 25, y: 35))
    }
    func testSVGIsValidAndEscapesTextAndNames() throws {
        let hidden = VectorShape(name: "Hidden", kind: .ellipse, visible: false)
        let text = VectorShape(name: "A&B <label>", kind: .text, fill: .ink, text: "Fish & chips <3\nSecond line")
        let svg = try VectorExporter.svg(VectorProject(shapes: [text, hidden]))
        let xml = try XMLDocument(xmlString: svg, options: [])
        XCTAssertEqual(xml.rootElement()?.name, "svg")
        XCTAssertTrue(svg.contains("&amp;"))
        XCTAssertTrue(svg.contains("&lt;3"))
        XCTAssertTrue(try xml.nodes(forXPath: "//*[local-name()='tspan']").map { $0.stringValue ?? "" }.joined().contains("Fish & chips <3"))
        XCTAssertTrue(svg.contains("Hidden"))
        XCTAssertTrue(svg.contains("display=\"none\""))
        XCTAssertTrue(svg.contains("clip-path"))
    }
    func testPDFAndTransparentPNGExport() throws {
        let shape = VectorShape(name: "Square", kind: .rectangle, x: 10, y: 10, width: 20, height: 20, fill: .violet, stroke: nil)
        let project = VectorProject(width: 64, height: 64, shapes: [shape])
        let pdf = try VectorExporter.data(project, format: .pdf)
        XCTAssertTrue(String(decoding: pdf.prefix(4), as: UTF8.self).hasPrefix("%PDF"))
        let png = try VectorExporter.data(project, format: .png)
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 64); XCTAssertEqual(image.pixelsHigh, 64)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: 15, y: 15)).alphaComponent, 0.9)
        XCTAssertLessThan(try XCTUnwrap(image.colorAt(x: 15, y: 50)).alphaComponent, 0.1)
    }
    func testRejectsInvalidDimensionsAndDuplicateIDs() {
        XCTAssertThrowsError(try VectorProject(width: -1).validated())
        XCTAssertThrowsError(try VectorProject(width: .infinity).validated())
        let shape = VectorShape(name: "A", kind: .rectangle)
        XCTAssertThrowsError(try VectorProject(shapes: [shape, shape]).validated())
        XCTAssertThrowsError(try VectorProject(version: 99).validated())
    }
    func testUndoRedoAndLockedObjectProtection() {
        let shape = VectorShape(name: "Editable", kind: .rectangle)
        let locked = VectorShape(name: "Locked", kind: .ellipse, locked: true)
        let doc = VectorDocument(project: VectorProject(shapes: [shape, locked]))
        let session = EditorSession(document: doc)
        session.selection = [shape.id, locked.id]
        session.moveSelection(CGSize(width: 25, height: 30))
        XCTAssertEqual(doc.project.shapes[0].x, 25)
        XCTAssertEqual(doc.project.shapes[1].x, 0)
        if session.history.groupingLevel > 0 { session.history.endUndoGrouping() }
        session.undo(); XCTAssertEqual(doc.project.shapes[0].x, 0)
        session.redo(); XCTAssertEqual(doc.project.shapes[0].x, 25)
    }
    func testPenTransactionIsOneUndoAndDiscardsSinglePoint() {
        let doc = VectorDocument(); let session = EditorSession(document: doc)
        session.beginTransaction()
        var path = VectorShape(name: "Path", kind: .path)
        path.anchors = [Anchor(CGPoint(x: 1, y: 2))]
        doc.project.shapes.append(path); session.activePath = path.id; session.selection = [path.id]
        session.finishPath()
        XCTAssertTrue(doc.project.shapes.isEmpty)
        XCTAssertFalse(session.canUndo)
    }
    func testDuplicatePreservesOrderAndUsesUniqueIDs() {
        let shape = VectorShape(name: "Rect", kind: .rectangle)
        let doc = VectorDocument(project: VectorProject(shapes: [shape])); let session = EditorSession(document: doc)
        session.selection = [shape.id]; session.duplicate()
        XCTAssertEqual(doc.project.shapes.count, 2)
        XCTAssertNotEqual(doc.project.shapes[0].id, doc.project.shapes[1].id)
        XCTAssertEqual(doc.project.shapes[1].x, 20)
        XCTAssertEqual(session.selection, [doc.project.shapes[1].id])
    }
}
