import XCTest
@testable import MagnusVector

final class ArtworkRuntimeTests: XCTestCase {
    private var root: URL!
    private var app: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Magdobe-runtime-" + UUID().uuidString)
        app = root.appendingPathComponent("Installed Apps/Magdobe Illustrator.app", isDirectory: true)
        home = root.appendingPathComponent("User Home", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func file(_ url: URL, executable: Bool = false, text: String = "fixture") throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }
    private func resolve(_ bundle: URL? = nil, path: String = "") throws -> ArtworkRuntime {
        let root = self.root!
        return try ArtworkRuntime.resolve(bundleURL: bundle ?? app, environment: ["PATH": path], homeDirectory: home,
                                          isExecutable: { url in url.path.hasPrefix(root.path + "/") && FileManager.default.isExecutableFile(atPath: url.path) })
    }
    private func sourceRuntime() throws -> URL {
        let python = try file(root.appendingPathComponent("Development Runtime/bin/python"), executable: true)
        let staleCodex = try file(root.appendingPathComponent("Build Host/bin/codex"), executable: true)
        let json = try JSONSerialization.data(withJSONObject: ["python": python.path, "codex": staleCodex.path])
        let configuration = app.appendingPathComponent("Contents/Resources/runtime.json")
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: configuration)
        try file(app.appendingPathComponent("Contents/Resources/Artwork/artwork_worker.py"))
        return python
    }

    func testBundledHelperWorksWithoutPythonOrRuntimeJSONAndAfterMovingTheApp() throws {
        let helper = try file(app.appendingPathComponent(ArtworkRuntime.helperRelativePath), executable: true)
        let before = try resolve()
        XCTAssertTrue(before.usesBundledHelper)
        XCTAssertEqual(before.executableURL, helper)
        XCTAssertNil(before.workerScriptURL)
        XCTAssertNil(before.codexURL)
        let moved = root.appendingPathComponent("Another Folder/Moved Magdobe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: moved)
        let relocated = try resolve(moved)
        XCTAssertEqual(relocated.executableURL, moved.appendingPathComponent(ArtworkRuntime.helperRelativePath))
        XCTAssertTrue(relocated.usesBundledHelper)
        XCTAssertEqual(try relocated.arguments(mode: "trace", job: nil, requiresCodex: false), ["trace"])
    }

    func testBundledHelperTakesPrecedenceOverSourceBuildConfiguration() throws {
        _ = try sourceRuntime()
        let helper = try file(app.appendingPathComponent(ArtworkRuntime.helperRelativePath), executable: true)
        XCTAssertEqual(try resolve().executableURL, helper)
        XCTAssertNil(try resolve().workerScriptURL)
    }

    func testDamagedBundledHelperDoesNotSilentlyUseDevelopmentPython() throws {
        _ = try sourceRuntime()
        try file(app.appendingPathComponent(ArtworkRuntime.helperRelativePath))
        XCTAssertThrowsError(try resolve()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Reinstall"))
        }
    }

    func testSourceBuildFallbackUsesPythonAndScriptButIgnoresBuildHostCodexPath() throws {
        let python = try sourceRuntime()
        let runtime = try resolve()
        XCTAssertFalse(runtime.usesBundledHelper)
        XCTAssertEqual(runtime.executableURL, python)
        XCTAssertEqual(runtime.workerScriptURL, app.appendingPathComponent("Contents/Resources/Artwork/artwork_worker.py"))
        XCTAssertNil(runtime.codexURL)
        let arguments = try runtime.arguments(mode: "generate", job: root, requiresCodex: false)
        XCTAssertEqual(arguments.first, runtime.workerScriptURL?.path)
        XCTAssertEqual(arguments[1], "generate")
        XCTAssertTrue(arguments.contains("--request"))
        XCTAssertFalse(arguments.contains("--codex"))
    }

    func testCodexIsDiscoveredFromCurrentUserPathWithoutRebuilding() throws {
        try file(app.appendingPathComponent(ArtworkRuntime.helperRelativePath), executable: true)
        XCTAssertNil(try resolve().codexURL)
        let codex = try file(root.appendingPathComponent("User Tools/bin/codex"), executable: true)
        let runtime = try resolve(path: codex.deletingLastPathComponent().path)
        XCTAssertEqual(runtime.codexURL, codex)
        let arguments = try runtime.arguments(mode: "check", job: nil, requiresCodex: true)
        XCTAssertEqual(arguments, ["check", "--codex", codex.path])
    }

    func testInstalledCodexAppCLIIsDiscoveredForThisUser() throws {
        try file(app.appendingPathComponent(ArtworkRuntime.helperRelativePath), executable: true)
        let cli = try file(home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"), executable: true)
        XCTAssertEqual(try resolve().codexURL, cli)
    }

    func testMissingCodexBlocksOnlyCodexAndOffersAnAPIConnection() throws {
        try file(app.appendingPathComponent(ArtworkRuntime.helperRelativePath), executable: true)
        let runtime = try resolve()
        XCTAssertNoThrow(try runtime.arguments(mode: "trace", job: root, requiresCodex: false))
        XCTAssertNoThrow(try runtime.arguments(mode: "generate", job: root, requiresCodex: false))
        XCTAssertThrowsError(try runtime.arguments(mode: "generate", job: root, requiresCodex: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("API image provider"))
            XCTAssertTrue(error.localizedDescription.contains("do not need to rebuild"))
        }
    }

    func testMissingOrBrokenDevelopmentRuntimeHasAnActionableError() throws {
        XCTAssertThrowsError(try resolve()) { error in XCTAssertTrue(error.localizedDescription.contains("Reinstall")) }
        let python = try sourceRuntime()
        try FileManager.default.removeItem(at: python)
        XCTAssertThrowsError(try resolve()) { error in XCTAssertTrue(error.localizedDescription.contains("Python runtime is unavailable")) }
    }
}
