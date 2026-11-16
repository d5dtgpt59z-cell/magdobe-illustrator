import XCTest
import AppKit
import PDFKit
@testable import MagnusVector

func productionTestICC() throws -> Data {
    if let path = ProcessInfo.processInfo.environment["MAGDOBE_TEST_ICC_PROFILE"] { return try Data(contentsOf: URL(fileURLWithPath: path)) }
    return try XCTUnwrap(NSColorSpace.genericCMYK.iccProfileData, "The macOS test environment needs its generic CMYK profile, or MAGDOBE_TEST_ICC_PROFILE")
}

final class ProductionPDFTests: XCTestCase {
    func test2199ObjectPhysicalVectorDraftAndSample() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Complex-2199", withExtension: "mvector", subdirectory: "Fixtures"))
        let project = try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: url)).validated(), before = project
        var spec = ProductionSpec(); spec.placement = .fillBleed
        let draft = try ProductionPDFDraftExporter.draft(project, spec: spec)
        XCTAssertEqual(draft.includedObjectIDs, project.shapes.map(\.id)); XCTAssertTrue(draft.omittedObjectIDs.isEmpty)
        let pdf = try XCTUnwrap(PDFDocument(data: draft.data)), page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 198, accuracy: 1e-8)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 270, accuracy: 1e-8)
        XCTAssertEqual(page.bounds(for: .trimBox), CGRect(x: 9, y: 9, width: 180, height: 252))
        XCTAssertEqual(page.bounds(for: .bleedBox), page.bounds(for: .mediaBox))
        XCTAssertEqual(project, before)
        if let path = ProcessInfo.processInfo.environment["MAGDOBE_PRODUCTION_QA_DIR"] {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try draft.data.write(to: dir.appendingPathComponent("Complex-2199-rgb-draft.pdf"), options: .atomic)
            var job = spec
            if ProcessInfo.processInfo.environment["MAGDOBE_TEST_ICC_PROFILE"] != nil {
                let icc = try productionTestICC(); var settings = ProductionPDFSettings()
                settings.iccProfile = try ProductionICCProfile.validate(icc); settings.target = .pdfx4
                settings.outputConditionIdentifier = "TEST_ONLY"
                settings.outputCondition = "Test ICC profile; not supplier approved."
                job.pdf = settings
                try icc.write(to: dir.appendingPathComponent("test-printer.icc"), options: .atomic)
            }
            try job.jobData().write(to: dir.appendingPathComponent("draft-job.json"), options: .atomic)
        }
    }
    func testICCValidationAndPortableAssetStayOutOfJobMetadata() throws {
        let data = try productionTestICC(), descriptor = try ProductionICCProfile.validate(data)
        var spec = ProductionSpec(), settings = ProductionPDFSettings()
        settings.iccProfile = descriptor; settings.outputConditionIdentifier = "Test profile · not supplier approved"; spec.pdf = settings
        let project = VectorProject(production: spec, productionICCProfile: data)
        XCTAssertEqual(try JSONDecoder().decode(VectorProject.self, from: JSONEncoder().encode(project)).validated(), project)
        let job = try spec.jobData()
        XCTAssertLessThan(job.count, 32 * 1_024)
        XCTAssertFalse(String(decoding: job, as: UTF8.self).contains(data.base64EncodedString()))
        XCTAssertTrue(String(decoding: job, as: UTF8.self).contains(descriptor.sha256))
        XCTAssertThrowsError(try VectorProject(productionICCProfile: data).validated())
        var mismatch = descriptor; mismatch.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ProductionICCProfile.validate(data, expected: mismatch))
        for (offset, bytes) in [(8, [UInt8(5)]), (12, Array("mntr".utf8)), (16, Array("RGB ".utf8)), (36, Array("bad!".utf8))] {
            var invalid = data; invalid.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            XCTAssertThrowsError(try ProductionICCProfile.validate(invalid))
        }
        XCTAssertThrowsError(try ProductionICCProfile.validate(Data(repeating: 0, count: ProductionICCProfile.maximumBytes + 1)))
        XCTAssertThrowsError(try ProductionICCProfile.validate(Data(repeating: 0, count: 128)))
        XCTAssertThrowsError(try ProductionICCProfile.validate(XCTUnwrap(NSColorSpace.sRGB.iccProfileData)))
    }
    func testICCProfileLibraryUsesValidatedContentHashAndNeverSubstitutesMissingProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ProductionICCLibrary(directory: dir), data = try productionTestICC()
        let descriptor = try ProductionICCProfile.validate(data)
        XCTAssertThrowsError(try library.load(descriptor))
        try library.save(data, descriptor: descriptor)
        XCTAssertEqual(try library.load(descriptor), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [descriptor.sha256 + ".icc"])
        try Data("damaged".utf8).write(to: dir.appendingPathComponent(descriptor.sha256 + ".icc"))
        XCTAssertThrowsError(try library.load(descriptor))
    }
    func testPartialPDFSetupIsBackwardsCompatibleButExportRequiresRealProfileAndCondition() throws {
        let partial = try JSONDecoder().decode(ProductionPDFSettings.self, from: Data("{\"target\":\"pdfx4\"}".utf8))
        XCTAssertEqual(partial.target, .pdfx4); XCTAssertNil(partial.iccProfile)
        XCTAssertNoThrow(try partial.validated()); XCTAssertThrowsError(try partial.validated(requireProfile: true))
        var settings = partial
        settings.iccProfile = try ProductionICCProfile.validate(productionTestICC())
        XCTAssertThrowsError(try settings.validated(requireProfile: true))
        settings.outputConditionIdentifier = "Test only"
        XCTAssertNoThrow(try settings.validated(requireProfile: true))
        for unsupported in ["{\"target\":\"pdfx1a\"}", "{\"black_policy\":\"rich_black\"}", "{\"text_mode\":\"rasterize\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(ProductionPDFSettings.self, from: Data(unsupported.utf8)))
        }
        settings.registryName = "https://user:secret@example.test/profile"
        XCTAssertThrowsError(try settings.validated())
        settings.registryName = ""; settings.outputConditionIdentifier = "bad\u{0}condition"
        XCTAssertThrowsError(try settings.validated())
    }
    func testProcessPDFOutlinesTextPreservesAlphaAndOmitsTechnicalFinishAndHiddenRoles() throws {
        let plain = VectorShape(name: "Process", kind: .rectangle, fill: VectorColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5), opacity: 0.7)
        let text = VectorShape(name: "Type", kind: .text, x: 10, y: 10, width: 80, height: 25, text: "Editable source", fontSize: 12)
        let cut = VectorShape(name: "Cut", kind: .rectangle), foil = VectorShape(name: "Foil", kind: .ellipse)
        let barcode = VectorShape(name: "Barcode", kind: .rectangle), hidden = VectorShape(name: "Hidden", kind: .rectangle, visible: false)
        var project = VectorProject(shapes: [plain,text,cut,foil,barcode,hidden])
        project.updateHierarchy { roots in
            VectorProject.editNode(text.id, in: &roots) { $0.productionRole = .artwork }
            VectorProject.editNode(cut.id, in: &roots) { $0.productionRole = .cut }
            VectorProject.editNode(foil.id, in: &roots) { $0.productionRole = .foil }
            VectorProject.editNode(barcode.id, in: &roots) { $0.productionRole = .barcode }
        }
        let before = project, draft = try ProductionPDFDraftExporter.draft(project, spec: ProductionSpec())
        XCTAssertEqual(draft.includedObjectIDs, [plain.id,text.id,barcode.id])
        XCTAssertEqual(draft.omittedObjectIDs, [cut.id,foil.id,hidden.id])
        let pdf = try XCTUnwrap(PDFDocument(data: draft.data)), page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertTrue(page.string?.isEmpty ?? true, "Production text must be actual glyph outlines")
        let cg = try XCTUnwrap(page.pageRef)
        var resources: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(cg.dictionary), "Resources", &resources))
        var fonts: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?, states: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(resources!, "Font", &fonts); CGPDFDictionaryGetDictionary(resources!, "XObject", &images)
        XCTAssertEqual(fonts.map(CGPDFDictionaryGetCount) ?? 0, 0)
        XCTAssertEqual(images.map(CGPDFDictionaryGetCount) ?? 0, 0)
        XCTAssertTrue(CGPDFDictionaryGetDictionary(resources!, "ExtGState", &states), "Transparency must survive as PDF graphics state")
        XCTAssertEqual(project, before)
        var technicalOnly = VectorProject(shapes: [cut]); technicalOnly.updateHierarchy { $0[0].productionRole = .cut }
        XCTAssertThrowsError(try ProductionPDFDraftExporter.draft(technicalOnly, spec: ProductionSpec()))
    }
    func testColorEmojiCannotSilentlyRasterizeIntoTheDraft() throws {
        let text = VectorShape(name: "Emoji", kind: .text, text: "🦄")
        XCTAssertThrowsError(try ProductionPDFDraftExporter.draft(VectorProject(shapes: [text]), spec: ProductionSpec()))
    }
    @MainActor func testProductionPDFSetupAndPortableICCUndoTogether() throws {
        let data = try productionTestICC(); var settings = ProductionPDFSettings()
        settings.iccProfile = try ProductionICCProfile.validate(data)
        var spec = ProductionSpec(); spec.pdf = settings
        let document = VectorDocument(), session = EditorSession(document: document)
        try session.applyProductionSpec(spec, iccProfile: data)
        XCTAssertEqual(document.project.production?.pdf, settings); XCTAssertEqual(document.project.productionICCProfile, data)
        session.undo(); XCTAssertNil(document.project.production); XCTAssertNil(document.project.productionICCProfile)
        session.redo(); XCTAssertEqual(document.project.productionICCProfile, data)
    }
}
