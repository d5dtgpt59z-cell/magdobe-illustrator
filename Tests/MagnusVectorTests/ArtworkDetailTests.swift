import XCTest
@testable import MagnusVector

final class ArtworkDetailTests: XCTestCase {
    func testHistoryUsesLatestCompletedSourceAndIgnoresPartialJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(ArtworkHistory.latestSource(in: root))
        for (name, completed, date) in [("older", true, 100.0), ("latest", true, 200.0), ("failed", false, 300.0)] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("source.png"))
            if completed { try Data([1]).write(to: dir.appendingPathComponent("artwork.mvector")) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: dir.path)
        }
        XCTAssertEqual(ArtworkHistory.latestSource(in: root)?.deletingLastPathComponent().lastPathComponent, "latest")
    }

    @MainActor func testFailedRebuildRetainsCurrentResultAndDoesNotCallGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GenerationStore(artworkDirectory: root)
        XCTAssertEqual(store.detail, .detailed)
        let original = VectorProject(shapes: [VectorShape(name: "Keep this", kind: .rectangle)])
        store.project = original; store.jobFolder = root.appendingPathComponent("previous")
        store.prompt = "" // A trace must not require a generation prompt or a connection.
        store.start(image: root.appendingPathComponent("missing-source.png"), preservingResult: true)
        for _ in 0..<100 {
            if !store.busy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.busy); XCTAssertNotNil(store.error)
        XCTAssertEqual(store.project, original)
        XCTAssertEqual(store.jobFolder?.lastPathComponent, "previous")
        XCTAssertFalse(store.connected)
    }
}
