import XCTest
@testable import MagnusVector

final class ProductionStudioTests: XCTestCase {
    private func fakeWorker(_ body: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        return (worker, directory)
    }

    func testCancellingAWorkspaceStartupStopsItsPendingProcess() async throws {
        let (worker, directory) = try fakeWorker("exec /bin/sleep 30\n")
        let attempt = StudioLaunchAttempt()
        let task = Task { try await attempt.start(executable: worker, data: directory) }
        try await Task.sleep(nanoseconds: 100_000_000)
        attempt.cancel()
        do { _ = try await task.value; XCTFail("Cancelled startup unexpectedly opened a workspace") }
        catch is CancellationError { }
    }

    func testWorkspaceOwnerCanStopAStartedProcess() async throws {
        let token = String(repeating: "a", count: 43)
        let (worker, directory) = try fakeWorker("echo '{\"url\":\"http://127.0.0.1:54321/production/?token=\(token)\"}'\nexec /bin/sleep 30\n")
        let attempt = StudioLaunchAttempt()
        let (process, _) = try await attempt.start(executable: worker, data: directory)
        XCTAssertTrue(process.isRunning)
        attempt.cancel()
        // waitUntilExit spins a Foundation run loop and can deadlock on a Swift
        // cooperative executor after the child has already exited. Yield while
        // waiting, and bound the assertion so a real cancellation bug fails.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(process.isRunning)
    }

    @MainActor func testOnlyAuthenticatedEphemeralLoopbackWorkspaceCanOpen() throws {
        let token = String(repeating: "a", count: 43)
        XCTAssertNoThrow(try ProductionStudioLauncher.validatedURL("http://127.0.0.1:54321/production/?token=\(token)"))
        for value in ["https://example.com/production/?token=\(token)",
                      "http://127.0.0.1:54321/production/", "http://127.0.0.1:54321/production/?token=short",
                      "http://user@127.0.0.1:54321/production/?token=\(token)",
                      "http://127.0.0.1:54321/production/?token=\(token)&other=1",
                      "http://127.0.0.1:54321/other/?token=\(token)"] {
            XCTAssertThrowsError(try ProductionStudioLauncher.validatedURL(value), value)
        }
    }
}
