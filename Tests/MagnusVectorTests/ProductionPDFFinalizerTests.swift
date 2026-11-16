import XCTest
import PDFKit
@testable import MagnusVector

/// Protocol/integrity tests use a fake local worker. Real ICC/PDF checks belong to engine integration tests.
final class ProductionPDFFinalizerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Production PDF tests " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func input() throws -> (ProductionPDFDraft, Data, ProductionSpec) {
        let icc = try productionTestICC(); var settings = ProductionPDFSettings()
        settings.iccProfile = try ProductionICCProfile.validate(icc); settings.outputConditionIdentifier = "Protocol test profile"
        var spec = ProductionSpec(); spec.pdf = settings
        let draft = try ProductionPDFDraftExporter.draft(VectorProject(shapes: [VectorShape(name: "Artwork", kind: .rectangle)]), spec: spec)
        return (draft,icc,spec)
    }
    private func executable(_ body: String) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func finalizer(_ helper: URL) -> ProductionPDFFinalizer {
        var value = ProductionPDFFinalizer()
        value.worker.environment = ["MAGDOBE_PRESSCHECK_WORKER": helper.path, "MAGDOBE_PROVIDER_API_KEY": "not-forwarded"]
        value.directory = root.appendingPathComponent("Retained artifacts"); value.timeout = 2
        return value
    }
    private func helper(draft: ProductionPDFDraft, icc: Data, spec: ProductionSpec, status: String = "pass_supported_checks", mutation: String = "", change: ((inout [String: Any]) -> Void)? = nil) throws -> URL {
        var report: [String: Any] = ["id": "test-pdf-job", "status": status,
            "source": ["name": "draft.pdf", "sha256": ProductionICCProfile.sha256(draft.data), "bytes": draft.data.count],
            "output": ["sha256": ProductionICCProfile.sha256(draft.data), "icc_sha256": ProductionICCProfile.sha256(icc), "bytes": draft.data.count,
                "vector_paths": 1, "text_objects": 0, "raster_objects": 0],
            "job": try JSONSerialization.jsonObject(with: spec.jobData()), "findings": [], "limitations": ["Fake protocol worker, not a PDF conformance engine"], "report_url": "report.html"]
        change?(&report)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
        return try executable("""
        while [ "$#" -gt 0 ]; do
          case "$1" in --output) output="$2"; shift 2;; --input) input="$2"; shift 2;; *) shift;; esac
        done
        if [ -n "$MAGDOBE_PROVIDER_API_KEY" ]; then exit 92; fi
        /bin/cp "$input" "$output/final.pdf"
        \(mutation)
        /bin/cat > "$output/report.json" <<'MAGDOBE_PDF_REPORT'
        \(json)
        MAGDOBE_PDF_REPORT
        /usr/bin/printf '<html>Protocol report</html>' > "$output/report.html"
        /usr/bin/printf '{"id":"test-pdf-job","report_path":"report.json","pdf_path":"final.pdf"}\\n'
        """)
    }
    func testValidatedReceiptCommitsAtomicallyAndPreservesItsInputsAndManifest() async throws {
        let (draft,icc,spec) = try input(), executable = try helper(draft: draft, icc: icc, spec: spec)
        let client = finalizer(executable), result = try await client.finalize(draft: draft, icc: icc, spec: spec)
        XCTAssertTrue(result.passed); XCTAssertEqual(result.reportURL?.lastPathComponent, "report.html")
        XCTAssertEqual(try Data(contentsOf: result.directory.appendingPathComponent("draft.pdf")), draft.data)
        XCTAssertEqual(try Data(contentsOf: result.directory.appendingPathComponent("printer.icc")), icc)
        XCTAssertEqual(try Data(contentsOf: result.directory.appendingPathComponent("job.json")), try spec.jobData())
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.directory.appendingPathComponent("object-manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["included_object_ids"] as? [String], draft.includedObjectIDs.map { $0.uuidString.lowercased() })
        let destination = root.appendingPathComponent("Saved production.pdf"); try Data("previous".utf8).write(to: destination)
        try client.commit(result, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), draft.data)
    }
    func testFailedValidationKeepsPriorDestinationAndRetainsReport() async throws {
        let (draft,icc,spec) = try input()
        let client = finalizer(try helper(draft: draft, icc: icc, spec: spec, status: "fail"))
        let result = try await client.finalize(draft: draft, icc: icc, spec: spec)
        XCTAssertFalse(result.passed); XCTAssertNil(result.pdfURL); XCTAssertNotNil(result.reportURL)
        let destination = root.appendingPathComponent("Existing.pdf"), original = Data("keep this file".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try client.commit(result, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }
    func testCanonicalFingerprintStillRefersToTheExactSelectedProfile() async throws {
        let (draft,icc,original) = try input(); var spec = original
        let fingerprint = try XCTUnwrap(spec.pdf?.iccProfile?.sha256)
        spec.pdf?.iccProfile?.sha256 = fingerprint.uppercased()
        let executable = try helper(draft: draft, icc: icc, spec: spec, change: { report in
            var job = report["job"] as! [String: Any], pdf = job["pdf"] as! [String: Any]
            var profile = pdf["icc_profile"] as! [String: Any]
            profile["sha256"] = (profile["sha256"] as! String).lowercased()
            pdf["icc_profile"] = profile; job["pdf"] = pdf; report["job"] = job
        })
        let result = try await finalizer(executable).finalize(draft: draft, icc: icc, spec: spec)
        XCTAssertTrue(result.passed)
    }
    func testWrongSourceProfileHashRasterOutputOrDifferentJobCannotBeCommitted() async throws {
        let (draft,icc,spec) = try input()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["source"] = ["name": "draft.pdf", "sha256": "wrong", "bytes": draft.data.count] },
            { value in var out = value["output"] as! [String: Any]; out["icc_sha256"] = String(repeating: "0", count: 64); value["output"] = out },
            { value in var out = value["output"] as! [String: Any]; out["raster_objects"] = 1; value["output"] = out },
            { value in var job = value["job"] as! [String: Any]; job["trim_width_mm"] = 999; value["job"] = job }]
        for mutation in mutations {
            let client = finalizer(try helper(draft: draft, icc: icc, spec: spec, change: mutation))
            do { _ = try await client.finalize(draft: draft, icc: icc, spec: spec); XCTFail("Expected integrity failure") }
            catch let error as ProductionPDFJobFailure { XCTAssertTrue(FileManager.default.fileExists(atPath: error.directory.appendingPathComponent("draft.pdf").path)) }
        }
    }
    func testWorkerCannotChangeInputOrTamperWithAcceptedOutputBeforeCommit() async throws {
        let (draft,icc,spec) = try input()
        let changing = finalizer(try helper(draft: draft, icc: icc, spec: spec, mutation: "/usr/bin/printf damaged > \"$input\""))
        do { _ = try await changing.finalize(draft: draft, icc: icc, spec: spec); XCTFail("Expected changed-source rejection") }
        catch is ProductionPDFJobFailure { }
        let client = finalizer(try helper(draft: draft, icc: icc, spec: spec))
        let result = try await client.finalize(draft: draft, icc: icc, spec: spec)
        try Data("tampered".utf8).write(to: XCTUnwrap(result.pdfURL))
        let destination = root.appendingPathComponent("Previous.pdf"); try Data("previous".utf8).write(to: destination)
        XCTAssertThrowsError(try client.commit(result, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
    }
    func testCancellationStopsTheWorkerAndKeepsWorkingCopies() async throws {
        let (draft,icc,spec) = try input(), client = finalizer(try executable("exec /bin/sleep 10\n"))
        let task = Task { try await client.finalize(draft: draft, icc: icc, spec: spec) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let folders = try FileManager.default.contentsOfDirectory(at: client.directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(try Data(contentsOf: folders[0].appendingPathComponent("draft.pdf")), draft.data)
    }
    func testBundledEngineIntegrationWhenExplicitlyConfigured() async throws {
        guard let helper = ProcessInfo.processInfo.environment["MAGDOBE_TEST_PDF_WORKER"] else {
            throw XCTSkip("Set MAGDOBE_TEST_PDF_WORKER to exercise the actual bundled conversion engine.")
        }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Complex-2199", withExtension: "mvector", subdirectory: "Fixtures"))
        let project = try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: source)).validated(), original = project
        let icc = try productionTestICC(); var settings = ProductionPDFSettings()
        settings.target = .pdfx4; settings.iccProfile = try ProductionICCProfile.validate(icc)
        settings.outputConditionIdentifier = "TEST_ONLY"; settings.outputCondition = "Integration test profile; not supplier approved."
        var spec = ProductionSpec(); spec.pdf = settings; spec.placement = .fillBleed
        let draft = try ProductionPDFDraftExporter.draft(project, spec: spec)
        XCTAssertEqual(draft.includedObjectIDs, project.shapes.map(\.id))
        XCTAssertEqual(draft.includedObjectIDs.count, 2199)
        var client = finalizer(URL(fileURLWithPath: helper)); client.timeout = 300
        if let path = ProcessInfo.processInfo.environment["MAGDOBE_PRODUCTION_QA_DIR"] {
            client.directory = URL(fileURLWithPath: path).appendingPathComponent("Native-engine-artifacts", isDirectory: true)
        }
        let result = try await client.finalize(draft: draft, icc: icc, spec: spec)
        XCTAssertTrue(result.passed, result.report.findings.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(result.report.output?.rasterObjects, 0)
        XCTAssertGreaterThan(result.report.output?.vectorPaths ?? 0, 0, "PDF paint operations may be clipped or optimized; native object IDs remain in the editable master")
        XCTAssertEqual(result.report.source.sha256, ProductionICCProfile.sha256(draft.data))
        XCTAssertEqual(result.report.output?.iccSHA256, ProductionICCProfile.sha256(icc))
        let destination = client.directory.appendingPathComponent("Native-finalized.pdf")
        try client.commit(result, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let pdf = try XCTUnwrap(PDFDocument(url: destination)), page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 198, accuracy: 0.001)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 270, accuracy: 0.001)
        XCTAssertEqual(page.bounds(for: .trimBox).minX, 9, accuracy: 0.001)
        XCTAssertEqual(page.bounds(for: .trimBox).minY, 9, accuracy: 0.001)
        XCTAssertEqual(page.bounds(for: .trimBox).width, 180, accuracy: 0.001)
        XCTAssertEqual(page.bounds(for: .trimBox).height, 252, accuracy: 0.001)
        XCTAssertEqual(project, original)
        print("Native finalizer integration output: \(destination.path)")
    }
}
