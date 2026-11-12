import XCTest
import AppKit
@testable import MagnusVector

final class SVGExportTests: XCTestCase {
    func fixture() throws -> VectorProject {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Complex-2199", withExtension: "mvector", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: url)).validated()
    }
    func xml(_ data: Data) throws -> XMLDocument { try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) }
    func objects(_ xml: XMLDocument) throws -> [XMLElement] {
        try xml.nodes(forXPath: "//*[starts-with(@id, 'object_')]").compactMap { $0 as? XMLElement }
    }
    func number(_ e: XMLElement, _ key: String, fallback: Double = 0) throws -> Double {
        guard let value = e.attribute(forName: key)?.stringValue else { return fallback }
        return try XCTUnwrap(Double(value))
    }
    func testActual2199ObjectIllustrationRoundTripAndSampleExport() throws {
        let project = try fixture(), before = project
        XCTAssertEqual(project.shapes.count, 2199)
        let start = Date()
        let data = try SVGExporter.data(project)
        let elapsed = Date().timeIntervalSince(start)
        let doc = try xml(data), exported = try objects(doc)
        XCTAssertEqual(exported.count, 2199)
        XCTAssertEqual(try doc.nodes(forXPath: "//*[local-name()='path']").count, 2199)
        XCTAssertEqual(try doc.nodes(forXPath: "//*[starts-with(@id, 'layer_')]").count, 2199)
        XCTAssertEqual(try doc.nodes(forXPath: "//*[local-name()='image' or local-name()='foreignObject' or local-name()='use' or local-name()='script']").count, 0)
        let ids = try doc.nodes(forXPath: "//*[@id]").compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(doc.rootElement()?.namespace(forPrefix: "")?.stringValue, "http://www.w3.org/2000/svg")
        XCTAssertEqual(doc.rootElement()?.attribute(forName: "width")?.stringValue, "1024.0pt")
        XCTAssertEqual(doc.rootElement()?.attribute(forName: "height")?.stringValue, "1536.0pt")
        XCTAssertEqual(doc.rootElement()?.attribute(forName: "viewBox")?.stringValue, "0 0 1024.0 1536.0")
        // Independent SVG-subset importer reads real d/paint attributes, not a source-project payload.
        let imported = try SVGTestImporter.read(doc)
        XCTAssertEqual(imported.shapes.count, project.shapes.count)
        var totalAnchors = 0
        for (source, restored) in zip(project.shapes, imported.shapes) {
            XCTAssertEqual(restored.id, source.id)
            XCTAssertEqual(restored.name, source.name)
            XCTAssertEqual(restored.kind, source.kind)
            XCTAssertEqual(restored.closed, source.closed)
            XCTAssertEqual(restored.contours.count, source.contours.count)
            for (a, b) in zip(source.contours, restored.contours) {
                XCTAssertEqual(a.count, b.count)
                totalAnchors += a.count
                for (lhs, rhs) in zip(a, b) {
                    XCTAssertEqual(lhs.point, rhs.point)
                    // A missing handle and an explicit handle at its anchor describe identical curves.
                    XCTAssertEqual(lhs.incoming ?? lhs.point, rhs.incoming ?? rhs.point)
                    XCTAssertEqual(lhs.outgoing ?? lhs.point, rhs.outgoing ?? rhs.point)
                }
            }
            XCTAssertEqual(source.bounds, restored.bounds)
            assertColor(source.fill, restored.fill)
            assertColor(source.stroke, restored.stroke)
            XCTAssertEqual(source.opacity, restored.opacity)
            XCTAssertEqual(source.strokeWidth, restored.strokeWidth)
            XCTAssertEqual(source.visible, restored.visible)
            XCTAssertEqual(source.locked, restored.locked)
        }
        XCTAssertEqual(totalAnchors, 125093)
        XCTAssertEqual(project, before)
        XCTAssertLessThan(elapsed, 30, "SVG serialization should comfortably handle the actual complex document")
        if let path = ProcessInfo.processInfo.environment["MAGDOBE_SVG_QA_DIR"] {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Optimus-and-GPK-2199-editable.svg")
            var last = 0
            let writeStart = Date()
            try SVGExporter.write(project, to: url) { n, total in
                XCTAssertGreaterThanOrEqual(n, last); XCTAssertEqual(total, 2199); last = n
            }
            let writeSeconds = Date().timeIntervalSince(writeStart)
            XCTAssertEqual(last, 2199)
            XCTAssertEqual(try Data(contentsOf: url), data)
            try VectorExporter.data(project, format: .png).write(to: dir.appendingPathComponent("native-reference.png"))
            let report = "Objects: 2199\nAnchors: 125093\nSVG bytes: \(data.count)\nSerialize seconds: \(elapsed)\nAtomic file export seconds: \(writeSeconds)\nNative bitmap reference: native-reference.png\nAdobe Illustrator: unavailable; not tested\n"
            try report.write(to: dir.appendingPathComponent("validation-metrics.txt"), atomically: true, encoding: .utf8)
        }
    }
    func assertColor(_ a: VectorColor?, _ b: VectorColor?, file: StaticString = #filePath, line: UInt = #line) {
        if let a, let b {
            XCTAssertEqual(a.red, b.red, accuracy: 1e-15, file: file, line: line)
            XCTAssertEqual(a.green, b.green, accuracy: 1e-15, file: file, line: line)
            XCTAssertEqual(a.blue, b.blue, accuracy: 1e-15, file: file, line: line)
            XCTAssertEqual(a.alpha, b.alpha, accuracy: 1e-15, file: file, line: line)
        } else { XCTAssertEqual(a, b, file: file, line: line) }
    }
    func testMixedGeometryPrecisionTransparencyHiddenObjectsAndNames() throws {
        var curve = VectorShape(name: "Curve & <layer> \"日本語\"\nsecond line", kind: .path, fill: VectorColor(red: 0.123456789012345, green: 0.4, blue: 1, alpha: 0.47), stroke: .ink, strokeWidth: 3.123456789012345, opacity: 0.37)
        var a = Anchor(CGPoint(x: -12.123456789012345, y: 0.000000003)); a.outgoing = VectorPoint(7.123456789012345, 8.45678901234567)
        var b = Anchor(CGPoint(x: 42.123456789012345, y: 54.98765432109876)); b.incoming = VectorPoint(37.456789012345, -15.123456789012345)
        curve.anchors = [a,b]
        let rect = VectorShape(name: "Hidden rectangle", kind: .rectangle, x: -50, y: 20, width: 30, height: 40, fill: nil, stroke: .violet, visible: false, locked: true)
        let ellipse = VectorShape(name: "Top ellipse", kind: .ellipse, x: 83.25, y: 94.5, width: 32.5, height: 21.75, stroke: nil)
        let project = VectorProject(width: 200, height: 180, shapes: [curve,rect,ellipse])
        let doc = try xml(SVGExporter.data(project)), restored = try SVGTestImporter.read(doc)
        XCTAssertEqual(restored.shapes.map(\.id), project.shapes.map(\.id))
        for (a,b) in zip(project.shapes,restored.shapes) {
            XCTAssertEqual(a.name,b.name); XCTAssertEqual(a.bounds,b.bounds); XCTAssertEqual(a.kind,b.kind)
            XCTAssertEqual(a.visible,b.visible); XCTAssertEqual(a.locked,b.locked)
            XCTAssertEqual(a.strokeWidth,b.strokeWidth); XCTAssertEqual(a.opacity,b.opacity)
            assertColor(a.fill,b.fill); assertColor(a.stroke,b.stroke)
        }
        let exported = try objects(doc)
        let paints = try exported[0].nodes(forXPath: "./*[local-name()='path']").compactMap { $0 as? XMLElement }
        XCTAssertEqual(paints.count, 2)
        XCTAssertEqual(paints.last?.attribute(forName: "stroke-linejoin")?.stringValue, "round")
        XCTAssertEqual(paints.last?.attribute(forName: "stroke-linecap")?.stringValue, "round")
        XCTAssertEqual(paints.first?.attribute(forName: "fill-rule")?.stringValue, "nonzero")
    }
    func testNamedGroupsCanBeDisabledWithoutChangingGeometryAndOptimizationIsLossless() throws {
        let project = VectorProject(shapes: [VectorShape(name: "One", kind: .rectangle),VectorShape(name: "Two", kind: .ellipse)])
        let standard = try SVGExporter.data(project)
        let optimized = try SVGExporter.data(project, options: .init(optimize: true))
        XCTAssertLessThan(optimized.count, standard.count)
        XCTAssertEqual(try SVGTestImporter.read(xml(standard)), try SVGTestImporter.read(xml(optimized)))
        let flat = try xml(SVGExporter.data(project, options: .init(preserveEditableLayers: false)))
        XCTAssertEqual(try flat.nodes(forXPath: "//*[starts-with(@id, 'layer_')]").count, 0)
        XCTAssertEqual(try objects(flat).count, 2)
        XCTAssertEqual(try SVGTestImporter.read(flat), project)
    }
    func testArtboardClipAndFitDrawingRetainOriginalCoordinatesAndStrokeExtents() throws {
        let shape = VectorShape(name: "Overhanging", kind: .rectangle, x: -10, y: 30, width: 100, height: 50, strokeWidth: 8)
        let project = VectorProject(width: 80, height: 80, shapes: [shape])
        let clipped = try xml(SVGExporter.data(project))
        XCTAssertEqual(try clipped.nodes(forXPath: "//*[@clip-path='url(#magdobe_artboard_clip)']").count, 1)
        let fit = try xml(SVGExporter.data(project, options: .init(entireArtboard: false)))
        XCTAssertEqual(fit.rootElement()?.attribute(forName: "viewBox")?.stringValue, "-14.0 26.0 108.0 58.0")
        XCTAssertEqual(try objects(fit)[0].attribute(forName: "x")?.stringValue, "-10.0")
        XCTAssertEqual(try fit.nodes(forXPath: "//*[local-name()='clipPath']").count, 0)
        XCTAssertThrowsError(try SVGExporter.data(VectorProject(), options: .init(entireArtboard: false)))
    }
    func testEditableTextAndOutlinedTextRemainVectors() throws {
        let text = VectorShape(name: "Type", kind: .text, x: 30, y: 40, width: 180, height: 60, fill: .ink, stroke: nil, text: "Office & café\nSecond line that wraps and continues", fontSize: 24)
        let project = VectorProject(width: 240, height: 150, shapes: [text])
        let editable = try xml(SVGExporter.data(project))
        XCTAssertEqual(try editable.nodes(forXPath: "//*[local-name()='text']").count, 1)
        let spans = try editable.nodes(forXPath: "//*[local-name()='tspan']")
        XCTAssertGreaterThan(spans.count, 2)
        XCTAssertEqual(spans.map { $0.stringValue ?? "" }.joined(), text.text)
        XCTAssertEqual(try SVGTestImporter.read(editable).shapes[0].text, text.text)
        let outlined = try xml(SVGExporter.data(project, options: .init(convertTextToOutlines: true)))
        XCTAssertEqual(try outlined.nodes(forXPath: "//*[local-name()='text' or local-name()='image']").count, 0)
        XCTAssertEqual(try objects(outlined).count, 1)
        let path = try SVGTestImporter.path(try XCTUnwrap(objects(outlined).first?.attribute(forName: "d")?.stringValue))
        XCTAssertGreaterThan(path.contours.flatMap { $0 }.count, 20)
        XCTAssertGreaterThan(path.bounds.minX, 25)
        XCTAssertGreaterThan(path.bounds.minY, 35)
        XCTAssertLessThan(path.bounds.minY, 70)
        XCTAssertEqual(project.shapes[0], text)
        if let dir = ProcessInfo.processInfo.environment["MAGDOBE_SVG_QA_DIR"] {
            try SVGExporter.write(project, to: URL(fileURLWithPath: dir).appendingPathComponent("text-outlined.svg"), options: .init(convertTextToOutlines: true))
            try SVGExporter.write(project, to: URL(fileURLWithPath: dir).appendingPathComponent("text-editable.svg"))
            try VectorExporter.data(project, format: .png).write(to: URL(fileURLWithPath: dir).appendingPathComponent("text-native.png"))
        }
    }
    func testOpacityPreservesSeparateNativeFillAndStrokeCompositing() throws {
        let shape = VectorShape(name: "Transparent fill and stroke", kind: .rectangle, x: 20, y: 20, width: 40, height: 40, fill: VectorColor(red: 1,green: 0,blue: 0), stroke: VectorColor(red: 0,green: 0,blue: 1), strokeWidth: 10, opacity: 0.5)
        let project = VectorProject(width: 80,height: 80,shapes: [shape])
        let native = try VectorExporter.data(project,format: .png)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: native))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 22,y: 40)).alphaComponent,0.75,accuracy: 0.01)
        let doc = try xml(SVGExporter.data(project))
        let object = try XCTUnwrap(objects(doc).first)
        XCTAssertEqual(object.localName,"g")
        XCTAssertEqual(try object.nodes(forXPath: "./*[local-name()='rect' and @opacity='0.5']").count,2)
        let restored = try SVGTestImporter.read(doc)
        XCTAssertEqual(restored,project)
        if let dir = ProcessInfo.processInfo.environment["MAGDOBE_SVG_QA_DIR"] {
            try SVGExporter.write(project,to: URL(fileURLWithPath: dir).appendingPathComponent("transparency.svg"))
            try native.write(to: URL(fileURLWithPath: dir).appendingPathComponent("transparency-native.png"))
        }
    }
    func testCancellationLeavesExistingDestinationIntact() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("existing.svg"), original = Data("original".utf8)
        try original.write(to: url)
        let project = try fixture()
        let entered = expectation(description: "Started writing geometry")
        let gate = DispatchSemaphore(value: 0)
        let work = Task.detached {
            try SVGExporter.write(project,to: url) { done, _ in
                if done == 32 { entered.fulfill(); _ = gate.wait(timeout: .now() + 10) }
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        work.cancel()
        gate.signal()
        do { try await work.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url),original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path),["existing.svg"])
    }
    func testUnsupportedColorGlyphFailsWithoutRasterization() throws {
        let shape = VectorShape(name: "Color emoji", kind: .text, text: "🎨", fontSize: 48)
        XCTAssertThrowsError(try SVGExporter.data(VectorProject(shapes: [shape]), options: .init(convertTextToOutlines: true)))
    }
    func testAtomicReplacementAndFailureKeepDestinationAndDocument() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("existing.svg")
        let sentinel = Data("previous file".utf8); try sentinel.write(to: url)
        var project = VectorProject(shapes: [VectorShape(name: "Invalid\u{0}name", kind: .rectangle)])
        let original = project
        XCTAssertThrowsError(try SVGExporter.write(project, to: url))
        XCTAssertEqual(try Data(contentsOf: url),sentinel); XCTAssertEqual(project,original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path),["existing.svg"])
        project.shapes[0].name = "Valid & name"
        try SVGExporter.write(project, to: url)
        XCTAssertEqual(try Data(contentsOf: url), try SVGExporter.data(project))
        XCTAssertThrowsError(try SVGExporter.write(project, to: dir.appendingPathComponent("missing/out.svg")))
    }
    func testSVGExportPresentationDoesNotFinishOrChangeAnActivePenPath() {
        var path = VectorShape(name: "In progress", kind: .path)
        path.anchors = [Anchor(CGPoint(x: 10, y: 20))]
        let doc = VectorDocument(project: VectorProject(shapes: [path])), original = doc.project
        let session = EditorSession(document: doc)
        session.activePath = path.id; session.beginTransaction()
        for format in ExportFormat.allCases {
            session.export(format)
            XCTAssertEqual(doc.project,original)
            XCTAssertEqual(session.activePath,path.id)
            XCTAssertEqual(session.exportFormat?.rawValue, format.rawValue)
            XCTAssertFalse(session.canUndo)
        }
    }
}
