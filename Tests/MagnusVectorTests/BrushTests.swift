import XCTest
import AppKit
@testable import MagnusVector

final class BrushTests: XCTestCase {
    func stroke(_ preset: BrushPreset = .round, pencil: Bool = false, pressure: Bool = false) -> FreehandStroke {
        var options = BrushSettings(); options.preset = preset; options.size = 24; options.opacity = 0.6
        var stroke = FreehandStroke(pencil: pencil, settings: options, color: .violet)
        for i in 0...80 {
            let t = Double(i) / 80
            stroke.append(CGPoint(x: 40 + 320 * t, y: 100 + sin(t * .pi * 2) * 35), pressure: pressure ? 0.2 + 0.8 * t : nil)
        }
        return stroke
    }
    func testPencilCreatesOpenEditableBezierCurveWithEndpoints() throws {
        let input = stroke(pencil: true), shape = try XCTUnwrap(input.shape())
        XCTAssertEqual(shape.kind, .path); XCTAssertFalse(shape.closed)
        XCTAssertNil(shape.fill); XCTAssertEqual(shape.stroke, .violet)
        XCTAssertEqual(shape.anchors.first?.point, VectorPoint(40, 100))
        XCTAssertEqual(shape.anchors.last?.point.x, 360)
        XCTAssertLessThan(shape.anchors.count, input.samples.count)
        XCTAssertTrue(shape.anchors.contains { $0.outgoing != nil })
        XCTAssertEqual(shape.strokeWidth, 24); XCTAssertEqual(shape.opacity, 0.6)
    }
    func testRoundBrushOutlineContainsTheCenterlineAndHasRoundCaps() throws {
        var options = BrushSettings(); options.size = 20
        var input = FreehandStroke(pencil: false, settings: options, color: .ink)
        input.append(CGPoint(x: 40, y: 100), pressure: nil); input.append(CGPoint(x: 200, y: 100), pressure: nil)
        let shape = try XCTUnwrap(input.shape())
        XCTAssertTrue(shape.closed); XCTAssertEqual(shape.fill, .ink); XCTAssertNil(shape.stroke)
        XCTAssertEqual(shape.bounds.minX, 30, accuracy: 0.01); XCTAssertEqual(shape.bounds.maxX, 210, accuracy: 0.01)
        XCTAssertEqual(shape.bounds.height, 20, accuracy: 0.01)
        XCTAssertTrue(shape.cgPath.contains(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(shape.cgPath.contains(CGPoint(x: 100, y: 111)))
    }
    func testPressureChangesWidthWithoutHolesOrDoubleOpacity() throws {
        var options = BrushSettings(); options.size = 40; options.smoothing = 0; options.opacity = 0.5
        var input = FreehandStroke(pencil: false, settings: options, color: .ink)
        for x in 40...240 { input.append(CGPoint(x: x, y: 100), pressure: x < 140 ? 0.2 : 1) }
        let shape = try XCTUnwrap(input.shape())
        for x in stride(from: 40, through: 240, by: 3) { XCTAssertTrue(shape.cgPath.contains(CGPoint(x: x, y: 100)), "Hole at \(x)") }
        XCTAssertFalse(shape.cgPath.contains(CGPoint(x: 80, y: 110)))
        XCTAssertTrue(shape.cgPath.contains(CGPoint(x: 200, y: 110)))
        let png = try VectorExporter.data(VectorProject(width: 280, height: 180, shapes: [shape]), format: .png)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 200, y: 100)).alphaComponent, 0.5, accuracy: 0.01)
        // Mouse draws at full width, even with pressure enabled.
        var mouse = FreehandStroke(pencil: false, settings: options, color: .ink)
        mouse.append(CGPoint(x: 40, y: 100), pressure: nil); mouse.append(CGPoint(x: 240, y: 100), pressure: nil)
        XCTAssertEqual(try XCTUnwrap(mouse.shape()).bounds.height, 40, accuracy: 0.01)
    }
    func testInkTapersAndCalligraphyRespectsNibAngle() throws {
        var options = BrushSettings(); options.preset = .ink; options.size = 40
        var ink = FreehandStroke(pencil: false, settings: options, color: .ink)
        ink.append(CGPoint(x: 40, y: 100), pressure: nil); ink.append(CGPoint(x: 240, y: 100), pressure: nil)
        let shape = try XCTUnwrap(ink.shape())
        XCTAssertFalse(shape.cgPath.contains(CGPoint(x: 42, y: 115)))
        XCTAssertTrue(shape.cgPath.contains(CGPoint(x: 140, y: 115)))
        options.preset = .calligraphy; options.angle = 0; options.roundness = 0.2
        var horizontal = FreehandStroke(pencil: false, settings: options, color: .ink)
        horizontal.append(CGPoint(x: 100, y: 100), pressure: nil)
        XCTAssertEqual(try XCTUnwrap(horizontal.shape()).bounds.width, 40, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(horizontal.shape()).bounds.height, 8, accuracy: 0.01)
        options.angle = 90
        var vertical = FreehandStroke(pencil: false, settings: options, color: .ink)
        vertical.append(CGPoint(x: 100, y: 100), pressure: nil)
        XCTAssertEqual(try XCTUnwrap(vertical.shape()).bounds.width, 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(vertical.shape()).bounds.height, 40, accuracy: 0.01)
    }
    func testTapDuplicateAndInvalidSamplesStayFinite() throws {
        var input = FreehandStroke(pencil: false, settings: BrushSettings(), color: .ink)
        XCTAssertNil(input.shape())
        input.append(CGPoint(x: Double.nan, y: 0), pressure: nil)
        XCTAssertNil(input.shape())
        for _ in 0..<20 { input.append(CGPoint(x: 100, y: 100), pressure: .nan) }
        XCTAssertEqual(input.samples.count, 1)
        let shape = try XCTUnwrap(input.shape())
        XCTAssertTrue(shape.cgPath.contains(CGPoint(x: 100, y: 100)))
        XCTAssertNoThrow(try VectorProject(shapes: [shape]).validated())
        var pencil = FreehandStroke(pencil: true, settings: BrushSettings(), color: .ink)
        pencil.append(CGPoint(x: 10, y: 10), pressure: nil)
        XCTAssertTrue(try XCTUnwrap(pencil.shape()).closed)
    }
    func testLongStrokeIsBoundedAndDoesNotLoseItsEndpoints() throws {
        var input = FreehandStroke(pencil: false, settings: BrushSettings(), color: .ink)
        for i in 0..<20_000 { input.append(CGPoint(x: Double(i) * 0.7, y: sin(Double(i) / 100) * 40), pressure: nil) }
        XCTAssertLessThanOrEqual(input.samples.count, FreehandStroke.sampleLimit)
        XCTAssertEqual(input.samples.first?.point.x, 0)
        XCTAssertEqual(input.samples.last?.point.x, 19_999 * 0.7)
        let start = Date()
        XCTAssertNoThrow(try VectorProject(shapes: [XCTUnwrap(input.shape())]).validated())
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testPencilReturningToStartKeepsItsLastCurve() throws {
        var input = FreehandStroke(pencil: true, settings: BrushSettings(), color: .ink)
        for p in [CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 200, y: 200), CGPoint(x: 50, y: 50)] { input.append(p, pressure: nil) }
        let shape = try XCTUnwrap(input.shape())
        XCTAssertEqual(shape.anchors.count, 4)
        XCTAssertEqual(shape.anchors.first?.point, shape.anchors.last?.point)
        XCTAssertFalse(shape.closed)
    }
    func testStrokeInLayerIsOneUndoStepAndRoundTripsWithoutRasterization() throws {
        let document = VectorDocument(project: VectorProject())
        let session = EditorSession(document: document)
        session.newLayer(); let layer = try XCTUnwrap(session.activeLayerID)
        session.selectTool(.brush)
        var input = try XCTUnwrap(session.beginFreehand())
        input.append(CGPoint(x: 50, y: 50), pressure: nil); input.append(CGPoint(x: 200, y: 80), pressure: nil)
        XCTAssertEqual(document.project.shapes.count, 0, "Preview must not mutate the document")
        session.commitFreehand(input)
        let saved = document.project, shape = try XCTUnwrap(saved.shapes.first)
        XCTAssertEqual(saved.shapes.count, 1); XCTAssertEqual(saved.hierarchyIndex.parents[shape.id], layer)
        session.undo(); XCTAssertEqual(document.project.shapes.count, 0)
        session.redo(); XCTAssertEqual(document.project, saved)
        XCTAssertEqual(try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(saved)), saved)
        let data = try SVGExporter.data(saved), xml = try XMLDocument(data: data)
        XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='image']").count, 0)
        let restored = try SVGTestImporter.read(xml)
        XCTAssertEqual(restored.shapes.count, 1)
        XCTAssertEqual(restored.shapes[0].bounds, shape.bounds)
        XCTAssertEqual(restored.shapes[0].fill, shape.fill)
        session.toggleNode(layer, visibility: false)
        XCTAssertNil(session.beginFreehand(), "Locked active layer must refuse drawing")
    }
    func testBrushPresetExportsAndNativeSample() throws {
        var shapes: [VectorShape] = []
        for (i, preset) in BrushPreset.allCases.enumerated() {
            var shape = try XCTUnwrap(stroke(preset, pressure: preset == .calligraphy).shape())
            shape.translate(CGSize(width: 0, height: i * 130)); shapes.append(shape)
        }
        var pencil = try XCTUnwrap(stroke(pencil: true).shape()); pencil.strokeWidth = 3; pencil.translate(CGSize(width: 0, height: 390)); shapes.append(pencil)
        let project = try VectorProject(width: 420, height: 560, shapes: shapes).validated()
        let data = try SVGExporter.data(project), xml = try XMLDocument(data: data)
        XCTAssertEqual(try xml.nodes(forXPath: "//*[starts-with(@id, 'object_')]").count, 4)
        XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='image']").count, 0)
        let imported = try SVGTestImporter.read(xml)
        for (a, b) in zip(shapes, imported.shapes) {
            XCTAssertEqual(a.bounds, b.bounds); XCTAssertEqual(a.closed, b.closed)
            XCTAssertEqual(a.opacity, b.opacity); XCTAssertEqual(a.contours.count, b.contours.count)
        }
        if let path = ProcessInfo.processInfo.environment["MAGDOBE_BRUSH_QA_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("brush-sampler.svg"))
            try JSONEncoder().encode(project).write(to: directory.appendingPathComponent("brush-sampler.mvector"))
            try VectorExporter.data(project, format: .png).write(to: directory.appendingPathComponent("brush-sampler.png"))
        }
    }
    func testCanvasGestureCommitsOnMouseUpAndEscapeCancelsWithoutUndo() throws {
        let document = VectorDocument(project: VectorProject(width: 1000, height: 800))
        let session = EditorSession(document: document); session.zoom = 1; session.selectTool(.brush)
        let canvas = CanvasView(session: session); canvas.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, 100, 100))
        for i in 1...20 { canvas.mouseDragged(with: try event(.leftMouseDragged, 100 + Double(i) * 5, 100 + sin(Double(i) / 4) * 20)) }
        XCTAssertTrue(document.project.shapes.isEmpty); XCTAssertFalse(session.canUndo)
        canvas.mouseUp(with: try event(.leftMouseUp, 205, 80))
        XCTAssertEqual(document.project.shapes.count, 1); XCTAssertTrue(session.canUndo)
        let saved = document.project
        canvas.mouseDown(with: try event(.leftMouseDown, 200, 200))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 300, 210))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape); canvas.mouseUp(with: try event(.leftMouseUp, 310, 220))
        XCTAssertEqual(document.project, saved)
        session.undo(); XCTAssertTrue(document.project.shapes.isEmpty)
        session.redo(); XCTAssertEqual(document.project, saved)
        canvas.mouseDown(with: try event(.leftMouseDown, 200, 200))
        _ = canvas.resignFirstResponder()
        canvas.mouseUp(with: try event(.leftMouseUp, 250, 250))
        XCTAssertEqual(document.project, saved)
    }
    func testCrossingAndReversalStayFilledAtConstantOpacity() throws {
        var options = BrushSettings(); options.preset = .calligraphy; options.opacity = 0.5; options.size = 28
        var input = FreehandStroke(pencil: false, settings: options, color: .ink)
        for point in [CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 200), CGPoint(x: 50, y: 200), CGPoint(x: 200, y: 50), CGPoint(x: 50, y: 200)] {
            input.append(point, pressure: 0.7)
        }
        let preview = input.geometry(), shape = try XCTUnwrap(input.shape())
        for y in stride(from: 20, to: 240, by: 4) {
            for x in stride(from: 20, to: 240, by: 4) {
                let point = CGPoint(x: x, y: y)
                XCTAssertEqual(shape.cgPath.contains(point), preview.contains(point), "Preview/final mismatch at \(point)")
            }
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: VectorExporter.data(VectorProject(width: 260, height: 260, shapes: [shape]), format: .png)))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 125, y: 125)).alphaComponent, 0.5, accuracy: 0.01)
    }
    func testDensePressureGestureFinishesInBoundedTime() throws {
        var options = BrushSettings(); options.size = 20
        var input = FreehandStroke(pencil: false, settings: options, color: .ink)
        for i in 0..<4096 {
            input.append(CGPoint(x: Double(i) * 0.7, y: 100 + sin(Double(i) / 30) * 40), pressure: 0.5 + sin(Double(i) / 15) * 0.4)
        }
        let start = Date(), shape = try XCTUnwrap(input.shape())
        XCTAssertNoThrow(try VectorProject(shapes: [shape]).validated())
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertLessThan(shape.contours.reduce(0) { $0 + $1.count }, 60_000)
    }
}
