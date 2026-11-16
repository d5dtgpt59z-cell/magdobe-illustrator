import XCTest
import AppKit
@testable import MagnusVector

final class ProductionWorkflowTests: XCTestCase {
    func testLegacyDocumentNeedsNoProductionSettingsAndRoundTrips() throws {
        let old = Data("{\"version\":1,\"width\":1024,\"height\":1536,\"shapes\":[]}".utf8)
        let project = try JSONDecoder().decode(VectorProject.self, from: old).validated()
        XCTAssertNil(project.production)
        let restored = try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored, project)
    }
    func testProductionSpecPersistsWithPhysicalUnitsPrinterEvidenceAndRoles() throws {
        var spec = ProductionSpec()
        spec.name = "Artist series / revision 3"
        spec.trimWidthMM = 63.5; spec.trimHeightMM = 88.9; spec.bleedMM = 3.175; spec.safeMM = 4
        spec.minTextPT = 7; spec.minStrokeMM = 0.15; spec.minRasterPPI = 300
        spec.profileName = "My printer"; spec.specSource = "Approved specification rev 3"; spec.printerNotes = "Matte stock"
        spec.expectedRoles = [.artwork, .foil]; spec.colorPolicy = .cmyk
        let project = VectorProject(production: spec)
        XCTAssertEqual(try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(project)).validated(), project)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.jobData()) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["trim_width_mm"] as? Double, 63.5)
        XCTAssertEqual(object["bleed_intent"] as? String, "full_bleed")
        XCTAssertEqual(object["supplier_confirmed"] as? Bool, false)
        XCTAssertEqual(object["expected_roles"] as? [String], ["artwork", "foil"])
    }
    func testInvalidDimensionsAndOptionalLimitsCannotBeSavedOrExported() throws {
        for value in [Double.nan, .infinity, -1, 0, 5001] {
            var spec = ProductionSpec(); spec.trimWidthMM = value
            XCTAssertThrowsError(try spec.validated())
            XCTAssertThrowsError(try ProductionSVGExporter.data(VectorProject(), spec: spec))
        }
        var spec = ProductionSpec(); spec.safeMM = 40
        XCTAssertThrowsError(try spec.validated())
        spec = ProductionSpec(); spec.minStrokeMM = 0
        XCTAssertThrowsError(try spec.validated())
        spec = ProductionSpec(); spec.schemaVersion = 2
        XCTAssertThrowsError(try spec.validated())
        spec = ProductionSpec(); spec.name = "Bad\u{0}job name"
        XCTAssertThrowsError(try spec.validated())
        XCTAssertThrowsError(try ProductionSVGExporter.data(VectorProject(), spec: spec))
    }
    func testPlacementUniformlyFitsOrFillsWithoutMutatingArtwork() throws {
        let project = VectorProject(width: 1024, height: 1536, shapes: [VectorShape(name: "Curve", kind: .rectangle, x: 10, y: 20, width: 100, height: 200)])
        let before = project
        var spec = ProductionSpec()
        let pt = ProductionSpec.pointsPerMM
        let fit = try spec.layout(for: project)
        XCTAssertEqual(fit.scale, min(63.5 * pt / 1024, 88.9 * pt / 1536), accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(fit.x, spec.bleedMM * pt)
        XCTAssertGreaterThanOrEqual(fit.y, spec.bleedMM * pt - 1e-12)
        XCTAssertLessThanOrEqual(fit.width, spec.trimWidthMM * pt + 1e-12)
        XCTAssertLessThanOrEqual(fit.height, spec.trimHeightMM * pt + 1e-12)
        spec.placement = .fillBleed
        let fill = try spec.layout(for: project)
        XCTAssertEqual(fill.scale, max(spec.bleedWidthMM * pt / 1024, spec.bleedHeightMM * pt / 1536), accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(fill.width, spec.bleedWidthMM * pt - 1e-12)
        XCTAssertGreaterThanOrEqual(fill.height, spec.bleedHeightMM * pt - 1e-12)
        XCTAssertLessThanOrEqual(fill.y, 0)
        _ = try ProductionSVGExporter.data(project, spec: spec)
        XCTAssertEqual(project, before)
    }
    func test2199EditableObjectsKeepIDsGeometryPaintOrderAndPhysicalDimensions() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Complex-2199", withExtension: "mvector", subdirectory: "Fixtures"))
        let project = try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: url)).validated(), before = project
        var spec = ProductionSpec(); spec.placement = .fillBleed; spec.name = "Card & <printer> \"日本語\""
        let ordinary = try XMLDocument(data: SVGExporter.data(project), options: [.nodeLoadExternalEntitiesNever])
        let data = try ProductionSVGExporter.data(project, spec: spec)
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let root = try XCTUnwrap(xml.rootElement())
        XCTAssertEqual(root.attribute(forName: "width")?.stringValue, SVGExporter.number(spec.bleedWidthMM) + "mm")
        XCTAssertEqual(root.attribute(forName: "height")?.stringValue, SVGExporter.number(spec.bleedHeightMM) + "mm")
        let box = try XCTUnwrap(root.attribute(forName: "viewBox")?.stringValue).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(box[2], 198, accuracy: 1e-10); XCTAssertEqual(box[3], 270, accuracy: 1e-10)
        let objects = try xml.nodes(forXPath: "//*[starts-with(@id,'object_')]").compactMap { $0 as? XMLElement }
        let original = try ordinary.nodes(forXPath: "//*[starts-with(@id,'object_')]").compactMap { $0 as? XMLElement }
        XCTAssertEqual(objects.count, 2199)
        for (a,b) in zip(objects, original) { XCTAssertEqual(a.xmlString, b.xmlString) }
        XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='path']").count, 2199)
        XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='image' or local-name()='foreignObject' or local-name()='script']").count, 0)
        let nested = try XCTUnwrap(xml.nodes(forXPath: "//*[local-name()='svg']").last as? XMLElement)
        XCTAssertEqual(nested.attribute(forName: "width")?.stringValue, "1024.0", "Nested SVG viewport must use unitless user coordinates, avoiding a 96/72 conversion")
        XCTAssertEqual(nested.attribute(forName: "height")?.stringValue, "1536.0")
        let metadata = try XCTUnwrap(xml.nodes(forXPath: "//*[@id='magdobe-production-job']").first?.stringValue)
        XCTAssertEqual(try JSONDecoder().decode(ProductionSpec.self, from: Data(metadata.utf8)), spec)
        XCTAssertEqual(project, before)
        if let path = ProcessInfo.processInfo.environment["MAGDOBE_PRODUCTION_QA_DIR"] {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ProductionSVGExporter.write(project, spec: spec, to: dir.appendingPathComponent("Complex-2199-production.svg"))
            try spec.jobData().write(to: dir.appendingPathComponent("production-job.json"), options: .atomic)
        }
    }
    func testRolesInheritAndChildrenOverrideWithoutGeometryChanges() throws {
        let a = VectorShape(name: "A", kind: .rectangle), b = VectorShape(name: "B", kind: .ellipse)
        var first = VectorNode.object(a.id); first.productionRole = .foil
        let layer = VectorNode(kind: .layer, name: "Print", children: [first, .object(b.id)], productionRole: .artwork)
        let project = try VectorProject(version: 2, shapes: [a,b], hierarchy: [layer]).validated()
        XCTAssertEqual(project.hierarchyIndex.productionRoles[a.id], .foil)
        XCTAssertEqual(project.hierarchyIndex.productionRoles[b.id], .artwork)
        let xml = try XMLDocument(data: SVGExporter.data(project, options: .init(preserveEditableLayers: false)), options: [.nodeLoadExternalEntitiesNever])
        let objects = try xml.nodes(forXPath: "//*[starts-with(@id,'object_')]").compactMap { $0 as? XMLElement }
        XCTAssertEqual(objects.map { $0.attribute(forName: "data-production-role")?.stringValue }, ["foil", "artwork"])
        XCTAssertEqual(try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(project)), project)
    }
    func testAtomicProductionExportAndFailurePreservePreviousDestination() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.svg"), old = Data("previous".utf8)
        try old.write(to: url)
        var invalid = ProductionSpec(); invalid.trimWidthMM = -1
        XCTAssertThrowsError(try ProductionSVGExporter.write(VectorProject(), spec: invalid, to: url))
        XCTAssertEqual(try Data(contentsOf: url), old)
        let project = VectorProject(shapes: [VectorShape(name: "A", kind: .rectangle)])
        try ProductionSVGExporter.write(project, spec: ProductionSpec(), to: url)
        XCTAssertEqual(try Data(contentsOf: url), try ProductionSVGExporter.data(project, spec: ProductionSpec()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["card.svg"])
    }
    func testCustomProfilesAreLocalValidatedAndRecoverable() throws {
        let suite = "ProductionWorkflowTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var spec = ProductionSpec(); spec.profileName = "Supplier revised card"; spec.specSource = "Revision 4"
        let profile = ProductionProfile(spec: spec)
        try ProductionProfiles.save([profile], to: defaults)
        XCTAssertEqual(ProductionProfiles.load(from: defaults), [profile])
        defaults.set(Data("invalid".utf8), forKey: ProductionProfiles.key)
        XCTAssertEqual(ProductionProfiles.load(from: defaults), [])
    }
    @MainActor func testSetupAndRolesAreUndoableWhileExportDoesNotTouchSession() throws {
        let shape = VectorShape(name: "A", kind: .rectangle), document = VectorDocument(project: VectorProject(shapes: []))
        document.project.shapes = [shape]
        let session = EditorSession(document: document); session.selection = [shape.id]
        try session.applyProductionSpec(ProductionSpec())
        XCTAssertNotNil(document.project.production)
        session.undo(); XCTAssertNil(document.project.production)
        session.setProductionRole(.cut)
        XCTAssertEqual(document.project.hierarchyIndex.productionRoles[shape.id], .cut)
        session.undo(); XCTAssertNil(document.project.hierarchyIndex.productionRoles[shape.id])
        let before = document.project, selection = session.selection
        _ = try ProductionSVGExporter.data(document.project, spec: ProductionSpec())
        XCTAssertEqual(document.project, before); XCTAssertEqual(session.selection, selection)
    }
}
