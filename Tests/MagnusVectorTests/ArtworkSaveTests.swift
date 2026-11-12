import XCTest
import AppKit
@testable import MagnusVector

final class ArtworkSaveTests: XCTestCase {
    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testAllFormatsSaveComplexArtworkWithoutChangingTheProject() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Complex-2199", withExtension: "mvector", subdirectory: "Fixtures"))
        var project = try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: fixture)).validated()
        let group = VectorNode(kind: .group, name: "Editable illustration", children: project.shapes.map { .object($0.id) })
        project.version = 2
        project.hierarchy = [VectorNode(kind: .layer, name: "Artwork", children: [group])]
        let before = project, directory = try temporaryFolder()
        for format in ArtworkFileFormat.allCases {
            let url = directory.appendingPathComponent("Artwork.\(format.fileExtension)")
            try ArtworkFileWriter.write(project, format: format, to: url)
            let data = try Data(contentsOf: url)
            switch format {
            case .project:
                let reopened = try JSONDecoder().decode(VectorProject.self, from: data).validated()
                XCTAssertEqual(reopened, before)
                XCTAssertEqual(reopened.shapes.count, 2199)
            case .svg:
                let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
                XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='path']").count, 2199)
                XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='image']").count, 0)
            case .pdf:
                let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
                XCTAssertEqual(pdf.numberOfPages, 1)
                XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox), CGRect(x: 0, y: 0, width: 1024, height: 1536))
            case .png:
                let image = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertEqual(image.pixelsWide, 1024); XCTAssertEqual(image.pixelsHigh, 1536)
            }
            XCTAssertEqual(project, before)
        }
    }

    func testFailedSavePreservesExistingFilesForEveryFormat() throws {
        let dir = try temporaryFolder(), previous = Data("Existing file".utf8)
        let invalid = VectorProject(width: -1)
        for format in ArtworkFileFormat.allCases {
            let destination = dir.appendingPathComponent("Artwork.\(format.fileExtension)")
            try previous.write(to: destination)
            XCTAssertThrowsError(try ArtworkFileWriter.write(invalid, format: format, to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), previous)
        }
    }

    func testCancelledSavePreservesExistingFilesForEveryFormat() async throws {
        let dir = try temporaryFolder(), previous = Data("Existing file".utf8)
        for format in ArtworkFileFormat.allCases {
            let destination = dir.appendingPathComponent("Artwork.\(format.fileExtension)")
            try previous.write(to: destination)
            let work = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                try ArtworkFileWriter.write(VectorProject(), format: format, to: destination)
            }
            do { try await work.value; XCTFail("Cancellation must be honored before writing") }
            catch is CancellationError { }
            XCTAssertEqual(try Data(contentsOf: destination), previous)
        }
    }

    @MainActor func testSaveStoreReportsActualSuccessAndFailure() async throws {
        let dir = try temporaryFolder(), url = dir.appendingPathComponent("Artwork.mvector")
        let store = ArtworkSaveStore(format: .project)
        let project = VectorProject(shapes: [VectorShape(name: "Editable", kind: .ellipse)])
        store.start(project: project, to: url)
        for _ in 0..<200 { if !store.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.busy); XCTAssertNil(store.error); XCTAssertEqual(store.savedURL, url)
        XCTAssertEqual(try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: url)), project)

        store.start(project: project, to: dir.appendingPathComponent("missing/file.mvector"))
        for _ in 0..<200 { if !store.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.busy); XCTAssertNotNil(store.error); XCTAssertNil(store.savedURL)
        XCTAssertEqual(try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: url)), project)
    }
}
