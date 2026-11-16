import Foundation

/// Values measured by a preflight rule may be numbers, ranges, strings, or structured data.
enum ProductionJSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: ProductionJSONValue]), array([ProductionJSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([ProductionJSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: ProductionJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .null: try value.encodeNil()
        }
    }
}

struct ProductionPreflightReport: Codable, Equatable {
    struct Source: Codable, Equatable {
        var name: String
        var sha256: String
        var vectorObjects: Int?
        enum CodingKeys: String, CodingKey { case name, sha256; case vectorObjects = "vector_objects" }
    }

    struct Finding: Codable, Equatable, Identifiable {
        var id: String
        var ruleID: String
        var status: String
        var message: String
        var objectIDs: [String]
        var measured: ProductionJSONValue?
        var expected: ProductionJSONValue?
        var unit: String?
        enum CodingKeys: String, CodingKey {
            case id, status, message, measured, expected, unit
            case ruleID = "rule_id", objectIDs = "object_ids"
        }
    }

    var id: String
    var status: String
    var source: Source
    var job: [String: ProductionJSONValue]
    var findings: [Finding]
    var limitations: [String]
    // These are server-provided references, not permission to navigate to an external URL.
    var previewURL: String?
    var reportURL: String
    var originalURL: String
    enum CodingKeys: String, CodingKey {
        case id, status, source, job, findings, limitations
        case previewURL = "preview_url", reportURL = "report_url", originalURL = "original_url"
    }
}

enum ProductionPreflightError: LocalizedError, Equatable {
    case invalidEndpoint, emptyArtwork, artworkTooLarge, jobTooLarge, invalidJob
    case responseTooLarge, invalidResponse, malformedReport, redirectRejected, httpStatus(Int), unavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Use a local PressCheck HTTP or HTTPS endpoint, such as http://127.0.0.1:8000/api/preflights. Remote hosts, credentials, query strings, and fragments are not allowed."
        case .emptyArtwork: return "There is no SVG artwork to check. Export the production SVG again."
        case .artworkTooLarge: return "The production SVG exceeds the local preflight upload limit. Save the artwork and check it directly in PressCheck."
        case .jobTooLarge: return "The production settings exceed the local preflight limit."
        case .invalidJob: return "The production settings could not be read as a JSON job. Review Production Setup and try again."
        case .responseTooLarge: return "PressCheck returned a report larger than the supported limit. Your original artwork was kept."
        case .invalidResponse: return "PressCheck returned an unexpected response. Check the local service address and try again."
        case .malformedReport: return "PressCheck returned an unreadable preflight report. Check that the local service supports this production workflow."
        case .redirectRejected: return "PressCheck tried to redirect the request. Artwork is sent only to the selected local endpoint."
        case .httpStatus(let status):
            switch status {
            case 400, 415, 422: return "PressCheck could not accept the SVG or production settings (HTTP \(status)). Review the job and the local service version. Your artwork was kept."
            case 413: return "PressCheck rejected the upload size (HTTP 413). Your artwork was kept."
            case 401, 403: return "The local PressCheck endpoint refused this request (HTTP \(status)). Check its access settings."
            default: return "PressCheck could not complete the check (HTTP \(status)). Your artwork was kept."
            }
        case .unavailable: return "Could not reach local PressCheck. Start its local service and check the endpoint in Production Setup. Your artwork was kept."
        }
    }
}

/// This delegate refuses redirects even between local hosts, so a server cannot forward artwork.
final class ProductionPreflightSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // HTTPS uses normal certificate validation. Never consult saved HTTP credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

final class ProductionPreflightClient {
    struct Limits {
        var artworkBytes = 40 * 1_024 * 1_024
        var jobBytes = 32 * 1_024
        var responseBytes = 4 * 1_024 * 1_024
        var timeout: TimeInterval = 120
    }

    static let defaultEndpoint = URL(string: "http://127.0.0.1:8000/api/preflights")!
    private let session: URLSession
    private let delegate = ProductionPreflightSessionDelegate()
    private let limits: Limits

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral, limits: Limits = .init()) {
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = limits.timeout
        configuration.timeoutIntervalForResource = limits.timeout
        self.session = URLSession(configuration: configuration)
        self.limits = limits
    }

    deinit { session.invalidateAndCancel() }

    static func validatedEndpoint(_ text: String) throws -> URL {
        guard !text.isEmpty, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !text.contains("\\"), var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true else { throw ProductionPreflightError.invalidEndpoint }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        if host == "localhost" {
            // Resolve the conventional alias without DNS, including custom resolver configurations.
            parts.host = "127.0.0.1"
        } else if host != "::1" {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.first == "127",
                  octets.allSatisfy({ octet in
                      !octet.isEmpty && octet.allSatisfy({ $0.isASCII && $0.isNumber })
                      && (octet.count == 1 || octet.first != "0")
                      && Int(octet).map({ (0...255).contains($0) }) == true
                  }) else { throw ProductionPreflightError.invalidEndpoint }
        }
        let segments = parts.percentEncodedPath.removingPercentEncoding?.split(separator: "/")
        guard segments != nil, !segments!.contains(where: { $0 == "." || $0 == ".." }),
              let url = parts.url, url.host != nil else { throw ProductionPreflightError.invalidEndpoint }
        return url
    }

    func send(svg: Data, filename: String, job: Data, endpoint: URL = defaultEndpoint) async throws -> ProductionPreflightReport {
        try Task.checkCancellation()
        let endpoint = try Self.validatedEndpoint(endpoint.absoluteString)
        guard !svg.isEmpty else { throw ProductionPreflightError.emptyArtwork }
        guard svg.count <= limits.artworkBytes else { throw ProductionPreflightError.artworkTooLarge }
        guard job.count <= limits.jobBytes else { throw ProductionPreflightError.jobTooLarge }
        guard (try? JSONSerialization.jsonObject(with: job)) is [String: Any] else { throw ProductionPreflightError.invalidJob }

        let boundary = "Magdobe-" + UUID().uuidString
        var body = Data()
        body.reserveCapacity(svg.count + job.count + 512)
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"job\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(job)
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(Self.safeFilename(filename))\"\r\nContent-Type: image/svg+xml\r\n\r\n")
        body.append(svg)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: limits.timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.httpBody = body
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw ProductionPreflightError.invalidResponse }
            guard !(300...399).contains(http.statusCode) else { throw ProductionPreflightError.redirectRejected }
            guard (200...299).contains(http.statusCode) else { throw ProductionPreflightError.httpStatus(http.statusCode) }
            guard response.expectedContentLength <= Int64(limits.responseBytes) else { throw ProductionPreflightError.responseTooLarge }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                if data.count % 4_096 == 0 { try Task.checkCancellation() }
                guard data.count < limits.responseBytes else { throw ProductionPreflightError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let report = try? JSONDecoder().decode(ProductionPreflightReport.self, from: data),
                  !report.id.isEmpty, report.id.utf8.count <= 256, !report.status.isEmpty,
                  !report.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw ProductionPreflightError.malformedReport }
            return report
        } catch is CancellationError { throw CancellationError() }
        catch let error as ProductionPreflightError { throw error }
        catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw ProductionPreflightError.unavailable
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProductionPreflightError.invalidResponse
        }
    }

    private static func safeFilename(_ name: String) -> String {
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        let safe = String(leaf.unicodeScalars.prefix(120).map { scalar -> Character in
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._-".unicodeScalars.contains(scalar)) { return Character(String(scalar)) }
            return "_"
        })
        return safe.lowercased().hasSuffix(".svg") && safe.count > 4 ? safe : "Artwork.svg"
    }
}
