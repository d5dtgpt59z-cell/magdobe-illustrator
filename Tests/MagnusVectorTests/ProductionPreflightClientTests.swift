import XCTest
@testable import MagnusVector

private final class ProductionURLProtocol: URLProtocol {
    static var handler: ((URLRequest, ProductionURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func respond(_ data: Data, status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class ProductionPreflightClientTests: XCTestCase {
    private let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><path id=\"object_one\" d=\"M0 0L1 1\"/></svg>".utf8)
    private let job = Data("{\"schema_version\":1,\"name\":\"Card proof\"}".utf8)
    private let response = Data("""
    {"id":"check-123","status":"needs_review","source":{"name":"Artwork.svg","sha256":"abc","vector_objects":2199,"anchors":125093},"job":{"schema_version":1,"supplier_confirmed":false},"findings":[{"id":"f1","rule_id":"size.trim","status":"warning","message":"Review trim","object_ids":["object_one"],"measured":2.5,"expected":{"minimum":3},"unit":"mm"}],"limitations":["Color is RGB"],"report_url":"report.html","original_url":"original.svg"}
    """.utf8)

    override func tearDown() { ProductionURLProtocol.handler = nil; super.tearDown() }

    private func client(limits: ProductionPreflightClient.Limits = .init()) -> ProductionPreflightClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProductionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "must-not-be-forwarded"]
        return ProductionPreflightClient(sessionConfiguration: configuration, limits: limits)
    }

    func testOnlyExplicitLoopbackEndpointsAreAccepted() throws {
        for value in ["http://127.0.0.1:8000/api/preflights", "https://127.7.8.9/check", "http://[::1]:8000/api/preflights"] {
            XCTAssertNoThrow(try ProductionPreflightClient.validatedEndpoint(value), value)
        }
        XCTAssertEqual(try ProductionPreflightClient.validatedEndpoint("http://localhost:8000/api/preflights").host, "127.0.0.1")
        for value in ["https://example.com/check", "http://127.0.0.1.example.com/check", "http://127.1/check", "http://127.00.0.1/check", "http://127.0.0.256/check", "file:///tmp/check", "http://user:pass@127.0.0.1/check", "http://127.0.0.1/check?key=secret", "http://127.0.0.1/check#fragment", "http://127.0.0.1:99999/check", "http://127.0.0.1/../check", "http://127.0.0.1/%2e%2e/check", "http://127.0.0.1/check\n"] {
            XCTAssertThrowsError(try ProductionPreflightClient.validatedEndpoint(value), value)
        }
    }

    func testMultipartCarriesExactSVGAndJobWithoutAmbientAuthorization() async throws {
        let svg = self.svg, job = self.job, response = self.response
        ProductionURLProtocol.handler = { request, protocolObject in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let body: Data
            if let data = request.httpBody { body = data }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var captured = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; captured.append(contentsOf: buffer.prefix(count)) }
                body = captured
            } else { XCTFail("Missing multipart body"); protocolObject.respond(Data(), status: 400); return }
            XCTAssertNotNil(body.range(of: svg)); XCTAssertNotNil(body.range(of: job))
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"job\"")); XCTAssertTrue(text.contains("name=\"file\""))
            XCTAssertFalse(text.contains("Injected: true")); XCTAssertFalse(text.contains("../../"))
            protocolObject.respond(response)
        }
        let report = try await client().send(svg: svg, filename: "../../bad\"\r\nInjected: true.svg", job: job)
        XCTAssertEqual(report.source.vectorObjects, 2_199)
        XCTAssertEqual(report.findings[0].objectIDs, ["object_one"])
        XCTAssertEqual(report.findings[0].measured, .number(2.5))
        XCTAssertEqual(report.findings[0].expected, .object(["minimum": .number(3)]))
        XCTAssertEqual(report.job["supplier_confirmed"], .bool(false))
        XCTAssertNil(report.previewURL)
    }

    func testMalformedAndHTTPFailureDoNotExposeServerBody() async throws {
        ProductionURLProtocol.handler = { _, p in p.respond(Data("{\"secret\":\"private-artwork-body\"}".utf8), status: 422) }
        do { _ = try await client().send(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .httpStatus(422)); XCTAssertFalse(error.localizedDescription.contains("private-artwork-body")) }
        ProductionURLProtocol.handler = { _, p in p.respond(Data("<html>wrong local service</html>".utf8)) }
        do { _ = try await client().send(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected malformed report") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .malformedReport) }
    }

    func testUploadAndResponseLimits() async throws {
        ProductionURLProtocol.handler = { _, _ in XCTFail("Oversized input must not reach the network") }
        do { _ = try await client().send(svg: Data(repeating: 32, count: 40 * 1_024 * 1_024 + 1), filename: "Artwork.svg", job: job); XCTFail("The bundled backend cannot accept more than 40 MiB") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .artworkTooLarge) }
        do { _ = try await client().send(svg: svg, filename: "Artwork.svg", job: Data(repeating: 32, count: 32 * 1_024 + 1)); XCTFail("The bundled backend cannot accept more than 32 KiB of job settings") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .jobTooLarge) }
        do { _ = try await client(limits: .init(artworkBytes: 1)).send(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .artworkTooLarge) }
        do { _ = try await client(limits: .init(jobBytes: 1)).send(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .jobTooLarge) }
        ProductionURLProtocol.handler = { _, p in p.respond(Data(repeating: 32, count: 101)) }
        do { _ = try await client(limits: .init(responseBytes: 100)).send(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected size rejection") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .responseTooLarge) }
    }

    func testRedirectResponseIsRejectedAndDelegateNeverForwardsRequest() async throws {
        ProductionURLProtocol.handler = { _, p in p.respond(Data(), status: 307, headers: ["Location": "https://example.com/upload"]) }
        do { _ = try await client().send(svg: svg, filename: "Artwork.svg", job: job); XCTFail("Expected redirect rejection") }
        catch { XCTAssertEqual(error as? ProductionPreflightError, .redirectRejected) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: ProductionPreflightClient.defaultEndpoint)
        let task = session.dataTask(with: request)
        let redirect = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var called = false
        ProductionPreflightSessionDelegate().urlSession(session, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://example.com/upload")!)) { next in called = true; XCTAssertNil(next) }
        XCTAssertTrue(called)
    }

    func testCancelledCheckDoesNotBecomeConnectionError() async throws {
        let started = expectation(description: "Local request started")
        ProductionURLProtocol.handler = { _, _ in started.fulfill() }
        let client = client(), svg = self.svg, job = self.job
        let task = Task { try await client.send(svg: svg, filename: "Artwork.svg", job: job) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
