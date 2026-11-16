import XCTest
import CryptoKit
@testable import MagnusVector

final class ProductionCheckWorkerTests: XCTestCase {
    private var root: URL!
    private let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><path id=\"object_test\" d=\"M0 0L10 10\"/></svg>".utf8)
    private let job = Data("{\"schema_version\":1,\"supplier_confirmed\":false}".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Magdobe production checks " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func executable(_ url: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func worker(helper: URL? = nil) -> ProductionCheckWorker {
        var value = ProductionCheckWorker()
        value.bundleURL = root.appendingPathComponent("Relocatable Magdobe.app")
        value.auxiliaryExecutable = nil
        value.environment = helper.map { ["MAGDOBE_PRESSCHECK_WORKER": $0.path] } ?? [:]
        value.storageDirectory = root.appendingPathComponent("Private checks")
        value.timeout = 2
        return value
    }

    func testBundledHelperResolutionSurvivesAppMoveAndNeedsNoPython() throws {
        let first = worker()
        let helper = first.bundleURL.appendingPathComponent(ProductionCheckWorker.helperRelativePath)
        try executable(helper, body: "exit 0\n")
        XCTAssertEqual(try first.executableURL(), helper)
        let moved = root.appendingPathComponent("Moved App.app")
        try FileManager.default.moveItem(at: first.bundleURL, to: moved)
        var relocated = first; relocated.bundleURL = moved
        XCTAssertEqual(try relocated.executableURL(), moved.appendingPathComponent(ProductionCheckWorker.helperRelativePath))
        XCTAssertNil(relocated.environment["PATH"])
    }

    func testInvalidOverrideAndMissingWorkerAreActionable() throws {
        XCTAssertThrowsError(try worker().executableURL()) { XCTAssertEqual($0 as? ProductionCheckWorkerError, .unavailable) }
        var invalid = worker(); invalid.environment["MAGDOBE_PRESSCHECK_WORKER"] = "relative-worker"
        XCTAssertThrowsError(try invalid.executableURL()) { XCTAssertEqual($0 as? ProductionCheckWorkerError, .invalidOverride) }
    }

    func testBackendLimitsRejectOversizedInputsBeforeLaunchingAnyWorker() async throws {
        let checker = worker()
        do { _ = try await checker.runCheck(svg: Data(repeating: 32, count: 40 * 1_024 * 1_024 + 1), filename: "Artwork.svg", job: job); XCTFail("Expected the backend SVG limit, before missing-helper resolution") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .artworkTooLarge) }
        do { _ = try await checker.runCheck(svg: svg, filename: "Artwork.svg", job: Data(repeating: 32, count: 32 * 1_024 + 1)); XCTFail("Expected the backend job limit, before missing-helper resolution") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .jobTooLarge) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: checker.storageDirectory.path))
    }

    func testLocalCheckPreservesInputsAndReadsContainedReport() async throws {
        let hash = SHA256.hash(data: svg).map { String(format: "%02x", $0) }.joined()
        let report: [String: Any] = ["id": "check-test", "status": "needs_review",
            "source": ["name": "Artwork.svg", "sha256": hash, "vector_objects": 1],
            "job": ["schema_version": 1], "findings": [], "limitations": ["No PDF/X certification"],
            "report_url": "report.html", "original_url": "original.svg"]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
        let helper = try executable(root.appendingPathComponent("Fake Worker"), body: """
        while [ "$#" -gt 0 ]; do
          case "$1" in --output) output="$2"; shift 2;; *) shift;; esac
        done
        if [ -n "$MAGDOBE_PROVIDER_API_KEY" ]; then exit 92; fi
        /bin/cat > "$output/report.json" <<'MAGDOBE_REPORT'
        \(json)
        MAGDOBE_REPORT
        /usr/bin/printf '<html><body>Production report</body></html>' > "$output/report.html"
        /usr/bin/printf '{"report_path":"%s/report.json","id":"check-test"}\n' "$output"
        """)
        var checker = worker(helper: helper)
        checker.environment["MAGDOBE_PROVIDER_API_KEY"] = "test-credential-must-not-enter-worker"
        let result = try await checker.runCheck(svg: svg, filename: "Artwork.svg", job: job)
        XCTAssertEqual(result.report.source.vectorObjects, 1)
        XCTAssertEqual(result.reportURL?.lastPathComponent, "report.html")
        XCTAssertEqual(try Data(contentsOf: result.directory.appendingPathComponent("Artwork.svg")), svg)
        XCTAssertEqual(try Data(contentsOf: result.directory.appendingPathComponent("job.json")), job)
        XCTAssertTrue(result.directory.path.hasPrefix(checker.storageDirectory.path + "/"))
    }

    func testWorkerCannotReturnAReportOutsideItsOutputDirectory() async throws {
        let helper = try executable(root.appendingPathComponent("Escape Worker"), body: """
        /usr/bin/printf '{"report_path":"/etc/passwd","id":"outside"}\n'
        """)
        do { _ = try await worker(helper: helper).runCheck(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected containment rejection") }
        catch { XCTAssertEqual(error as? ProductionCheckWorkerError, .invalidResult) }
        let output = root.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("link.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try ProductionCheckWorker.containedFile("link.json", in: output))
        XCTAssertThrowsError(try ProductionCheckWorker.containedFile("https://example.com/report.json", in: output))
    }

    func testWorkerFailureAndTimeoutKeepOriginalCopy() async throws {
        let failure = try executable(root.appendingPathComponent("Failure Worker"), body: "exit 7\n")
        do { _ = try await worker(helper: failure).runCheck(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected failed worker") }
        catch { XCTAssertEqual(error as? ProductionCheckWorkerError, .failed(7)) }
        let sleeper = try executable(root.appendingPathComponent("Slow Worker"), body: "exec /bin/sleep 10\n")
        var checker = worker(helper: sleeper); checker.timeout = 0.1
        do { _ = try await checker.runCheck(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ProductionCheckWorkerError, .timedOut) }
        let checks = try FileManager.default.contentsOfDirectory(at: checker.storageDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(checks.count, 2)
        for directory in checks { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Artwork.svg")), svg) }
    }

    func testCancellationTerminatesWorkerAndKeepsInputCopy() async throws {
        let helper = try executable(root.appendingPathComponent("Cancel Worker"), body: "exec /bin/sleep 10\n")
        let checker = worker(helper: helper), svg = self.svg, job = self.job
        let task = Task { try await checker.runCheck(svg: svg, filename: "Artwork.svg", job: job) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
