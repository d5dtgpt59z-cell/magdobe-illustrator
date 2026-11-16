import Foundation

struct ProductionPDFReport: Decodable {
    struct Source: Decodable { var name: String; var sha256: String; var bytes: Int }
    struct Output: Decodable {
        var sha256: String
        var iccSHA256: String
        var bytes: Int
        var vectorPaths: Int?
        var textObjects: Int?
        var rasterObjects: Int?
        enum CodingKeys: String, CodingKey {
            case sha256, bytes, iccSHA256 = "icc_sha256", vectorPaths = "vector_paths", textObjects = "text_objects", rasterObjects = "raster_objects"
        }
    }
    var id: String
    var status: String
    var source: Source
    var output: Output?
    var job: [String: ProductionJSONValue]
    var findings: [ProductionPreflightReport.Finding]
    var limitations: [String]
    var reportURL: String?
    enum CodingKeys: String, CodingKey { case id, status, source, output, job, findings, limitations; case reportURL = "report_url" }
}

struct ProductionPDFResult {
    var report: ProductionPDFReport
    var directory: URL
    var pdfURL: URL?
    var reportURL: URL?
    var passed: Bool { report.status == "pass_supported_checks" && pdfURL != nil }
}

struct ProductionPDFJobFailure: LocalizedError {
    var directory: URL
    var message: String
    var errorDescription: String? { message + " Working copies were retained in the production artifacts folder." }
}

struct ProductionPDFFinalizer {
    var worker = ProductionCheckWorker()
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Magdobe Illustrator/Production PDFs", isDirectory: true)
    var timeout: TimeInterval = 300

    func finalize(draft: ProductionPDFDraft, icc: Data, spec: ProductionSpec) async throws -> ProductionPDFResult {
        try Task.checkCancellation()
        let settings = try requiredSettings(spec)
        _ = try ProductionICCProfile.validate(icc, expected: settings.iccProfile)
        let job = try spec.jobData()
        let limits = ProductionPreflightClient.Limits()
        guard draft.data.count <= limits.artworkBytes, draft.data.starts(with: Data("%PDF-".utf8)), job.count <= limits.jobBytes else {
            throw ProductionPDFError.settings("The production PDF or job exceeds the supported size limit.")
        }
        let executable = try worker.executableURL()
        let fm = FileManager.default
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let input = root.appendingPathComponent("draft.pdf"), profile = root.appendingPathComponent("printer.icc"), jobURL = root.appendingPathComponent("job.json")
            for (url, data) in [(input,draft.data), (profile,icc), (jobURL,job)] {
                try data.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let manifest: [String: Any] = ["included_object_ids": draft.includedObjectIDs.map { $0.uuidString.lowercased() },
                "omitted_object_ids": draft.omittedObjectIDs.map { $0.uuidString.lowercased() },
                "omitted_roles": "Technical, reference and finish roles; process artwork, barcodes and unassigned objects only."]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: root.appendingPathComponent("object-manifest.json"), options: .atomic)
            let output = root.appendingPathComponent("output", isDirectory: true)
            try fm.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let response = try await ProductionWorkerProcess().run(executable: executable,
                arguments: ["finalize-pdf", "--input", input.path, "--icc", profile.path, "--job", jobURL.path, "--output", output.path],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": fm.homeDirectoryForCurrentUser.path,
                    "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "PYTHONNOUSERSITE": "1"], timeout: timeout)
            try Task.checkCancellation()
            struct Receipt: Decodable { var id: String; var report_path: String; var pdf_path: String? }
            let receipt = try JSONDecoder().decode(Receipt.self, from: response)
            let reportFile = try ProductionCheckWorker.containedFile(receipt.report_path, in: output)
            guard try size(reportFile) <= 4 * 1_024 * 1_024 else { throw ProductionPDFError.invalidResult }
            let report = try JSONDecoder().decode(ProductionPDFReport.self, from: Data(contentsOf: reportFile))
            var expectedJob = try JSONDecoder().decode([String: ProductionJSONValue].self, from: job)
            // SHA-256 hex has one identity regardless of letter case. The
            // finalizer canonicalizes it without changing the selected profile.
            if case .object(var pdf)? = expectedJob["pdf"], case .object(var profile)? = pdf["icc_profile"],
               case .string(let hash)? = profile["sha256"] {
                profile["sha256"] = .string(hash.lowercased()); pdf["icc_profile"] = .object(profile); expectedJob["pdf"] = .object(pdf)
            }
            guard report.id == receipt.id, !report.id.isEmpty,
                  report.source.sha256.lowercased() == ProductionICCProfile.sha256(draft.data), report.source.bytes == draft.data.count,
                  ["pdf", "trim_width_mm", "trim_height_mm", "bleed_mm", "safe_mm", "placement"].allSatisfy({ report.job[$0] == expectedJob[$0] }),
                  try size(input) == draft.data.count, try size(profile) == icc.count, try size(jobURL) == job.count,
                  try Data(contentsOf: input) == draft.data, try Data(contentsOf: profile) == icc, try Data(contentsOf: jobURL) == job else {
                throw ProductionPDFError.invalidResult
            }
            let pdf: URL?
            if report.status == "pass_supported_checks" {
                guard let name = receipt.pdf_path, let details = report.output else { throw ProductionPDFError.invalidResult }
                let url = try ProductionCheckWorker.containedFile(name, in: output)
                guard try size(url) <= limits.artworkBytes else { throw ProductionPDFError.invalidResult }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.starts(with: Data("%PDF-".utf8)), data.count == details.bytes,
                      details.sha256.lowercased() == ProductionICCProfile.sha256(data), details.iccSHA256.lowercased() == ProductionICCProfile.sha256(icc),
                      details.rasterObjects == 0, (details.vectorPaths ?? 0) > 0 else { throw ProductionPDFError.invalidResult }
                pdf = url
            } else { pdf = nil }
            let html: URL?
            if let value = report.reportURL, let candidate = try? ProductionCheckWorker.containedFile(value, in: output), candidate.pathExtension == "html" { html = candidate }
            else { html = try? ProductionCheckWorker.containedFile("report.html", in: output) }
            return ProductionPDFResult(report: report, directory: root, pdfURL: pdf, reportURL: html)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ProductionPDFJobFailure(directory: root, message: error.localizedDescription) }
    }

    func commit(_ result: ProductionPDFResult, to destination: URL) throws {
        guard result.passed, let pdf = result.pdfURL, let output = result.report.output else { throw ProductionPDFError.validationFailed }
        let data = try Data(contentsOf: pdf, options: .mappedIfSafe)
        guard data.count <= ProductionPreflightClient.Limits().artworkBytes, ProductionICCProfile.sha256(data) == output.sha256.lowercased() else { throw ProductionPDFError.invalidResult }
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
    }
    private func size(_ url: URL) throws -> Int { try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max }
    private func requiredSettings(_ spec: ProductionSpec) throws -> ProductionPDFSettings {
        _ = try spec.validated()
        guard let settings = spec.pdf else { throw ProductionPDFError.settings("Enable Production PDF and choose the printer's output profile first.") }
        return try settings.validated(requireProfile: true)
    }
}
