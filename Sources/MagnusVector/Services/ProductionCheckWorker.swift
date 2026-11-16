import Foundation
import CryptoKit
import Darwin

struct ProductionCheckResult {
    var report: ProductionPreflightReport
    var directory: URL
    var reportURL: URL?
}

enum ProductionCheckWorkerError: LocalizedError, Equatable {
    case unavailable, invalidOverride, failed(Int32), timedOut, excessiveOutput, invalidResult, sourceChanged
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The bundled PressCheck worker is missing. Reinstall Magdobe to use local production checks. Your project was kept."
        case .invalidOverride: return "The development PressCheck worker override is not an executable file."
        case .failed(let status): return "The local production check could not complete (worker exit \(status)). Your project and saved SVG were kept."
        case .timedOut: return "The local production check exceeded its time limit. Your project and saved SVG were kept."
        case .excessiveOutput: return "The local production worker exceeded its output limit. Your project was kept."
        case .invalidResult: return "The local production worker returned an invalid report. Your project and saved SVG were kept."
        case .sourceChanged: return "The local production worker changed its input copy. The check was rejected; your original project was kept."
        }
    }
}

/// The installed app runs its own bundled checker; no Python installation or server is required.
struct ProductionCheckWorker {
    static let helperRelativePath = "Contents/Helpers/PressCheckWorker.app/Contents/MacOS/PressCheckWorker"
    var bundleURL: URL = Bundle.main.bundleURL
    var auxiliaryExecutable: URL? = Bundle.main.url(forAuxiliaryExecutable: "PressCheckWorker")
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var storageDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Magdobe Illustrator/Print Checks", isDirectory: true)
    var timeout: TimeInterval = 120

    static func check(svg: Data, filename: String, job: Data) async throws -> ProductionCheckResult {
        try await ProductionCheckWorker().runCheck(svg: svg, filename: filename, job: job)
    }

    func executableURL() throws -> URL {
        let manager = FileManager.default
        func executable(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return url.isFileURL && manager.fileExists(atPath: url.path, isDirectory: &directory)
                && !directory.boolValue && manager.isExecutableFile(atPath: url.path)
        }
        if let override = environment["MAGDOBE_PRESSCHECK_WORKER"] {
            let url = URL(fileURLWithPath: override)
            guard override.hasPrefix("/"), executable(url) else { throw ProductionCheckWorkerError.invalidOverride }
            return url
        }
        let bundled = bundleURL.appendingPathComponent(Self.helperRelativePath)
        if executable(bundled) { return bundled }
        if let auxiliaryExecutable, executable(auxiliaryExecutable) { return auxiliaryExecutable }
        throw ProductionCheckWorkerError.unavailable
    }

    func runCheck(svg: Data, filename: String, job: Data) async throws -> ProductionCheckResult {
        try Task.checkCancellation()
        guard !svg.isEmpty else { throw ProductionPreflightError.emptyArtwork }
        let limits = ProductionPreflightClient.Limits()
        guard svg.count <= limits.artworkBytes else { throw ProductionPreflightError.artworkTooLarge }
        guard job.count <= limits.jobBytes else { throw ProductionPreflightError.jobTooLarge }
        guard (try? JSONSerialization.jsonObject(with: job)) is [String: Any] else { throw ProductionPreflightError.invalidJob }
        let executable = try executableURL()
        let manager = FileManager.default
        let directory = storageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = directory.appendingPathComponent("report", isDirectory: true)
        try manager.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let input = directory.appendingPathComponent(safeFilename(filename)), jobURL = directory.appendingPathComponent("job.json")
        try svg.write(to: input, options: .atomic)
        try job.write(to: jobURL, options: .atomic)
        for url in [input, jobURL] { try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let originalHash = SHA256.hash(data: svg).map { String(format: "%02x", $0) }.joined()
        // A small allowlist prevents unrelated provider credentials and Python settings reaching the checker.
        let processEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": manager.homeDirectoryForCurrentUser.path,
                                  "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "PYTHONNOUSERSITE": "1"]
        let data = try await ProductionWorkerProcess().run(executable: executable,
            arguments: ["preflight", "--input", input.path, "--job", jobURL.path, "--output", output.path],
            environment: processEnvironment, timeout: timeout)
        try Task.checkCancellation()
        struct Receipt: Decodable { var report_path: String; var id: String }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data), !receipt.id.isEmpty else { throw ProductionCheckWorkerError.invalidResult }
        let reportFile = try Self.containedFile(receipt.report_path, in: output)
        let attributes = try manager.attributesOfItem(atPath: reportFile.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 4 * 1_024 * 1_024,
              let report = try? JSONDecoder().decode(ProductionPreflightReport.self, from: Data(contentsOf: reportFile)),
              report.id == receipt.id, !report.status.isEmpty,
              report.source.sha256.lowercased() == originalHash else { throw ProductionCheckWorkerError.invalidResult }
        guard try Self.hashFile(input) == originalHash,
              try Data(contentsOf: jobURL) == job else { throw ProductionCheckWorkerError.sourceChanged }
        let html: URL?
        if let url = try? Self.containedFile(report.reportURL, in: output), url.pathExtension.lowercased() == "html" { html = url }
        else { html = nil }
        return ProductionCheckResult(report: report, directory: directory, reportURL: html)
    }

    static func containedFile(_ path: String, in directory: URL) throws -> URL {
        let candidate: URL
        if let url = URL(string: path), url.scheme != nil {
            guard url.isFileURL else { throw ProductionCheckWorkerError.invalidResult }
            candidate = url
        } else if path.hasPrefix("/") { candidate = URL(fileURLWithPath: path) }
        else { candidate = directory.appendingPathComponent(path) }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let result = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard result.path.hasPrefix(root.path + "/"),
              (try? result.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw ProductionCheckWorkerError.invalidResult }
        return result
    }

    private func safeFilename(_ name: String) -> String {
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        let safe = String(leaf.unicodeScalars.prefix(120).map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._-".unicodeScalars.contains(scalar)) ? Character(String(scalar)) : "_"
        })
        return safe.lowercased().hasSuffix(".svg") && safe.count > 4 && safe != "job.json" ? safe : "Artwork.svg"
    }

    private static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Blocking process waits are confined to background queues. Pipe readers retain bounded output.
final class ProductionWorkerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var overflow = false

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let child = Process(), stdout = Pipe(), stderr = Pipe()
                    child.executableURL = executable; child.arguments = arguments; child.environment = environment
                    child.standardOutput = stdout; child.standardError = stderr; child.standardInput = FileHandle.nullDevice
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    do { try child.run(); self.process = child; self.lock.unlock() }
                    catch { self.lock.unlock(); continuation.resume(throwing: ProductionCheckWorkerError.unavailable); return }
                    try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                    let group = DispatchGroup(), capture = ProductionWorkerOutput()
                    for (pipe, isStandardOutput) in [(stdout, true), (stderr, false)] {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { try? pipe.fileHandleForReading.close(); group.leave() }
                            while let data = try? pipe.fileHandleForReading.read(upToCount: 8_192), !data.isEmpty {
                                if !capture.append(data, stdout: isStandardOutput) { self.stop(overflow: true) }
                            }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeout)) { self.stop(timedOut: true) }
                    child.waitUntilExit(); group.wait()
                    self.lock.lock()
                    self.process = nil
                    let cancelled = self.cancelled, timedOut = self.timedOut, overflow = self.overflow
                    self.lock.unlock()
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                    else if timedOut { continuation.resume(throwing: ProductionCheckWorkerError.timedOut) }
                    else if overflow { continuation.resume(throwing: ProductionCheckWorkerError.excessiveOutput) }
                    else if child.terminationStatus != 0 { continuation.resume(throwing: ProductionCheckWorkerError.failed(child.terminationStatus)) }
                    else { continuation.resume(returning: capture.output) }
                }
            }
        } onCancel: { self.stop(cancelled: true) }
    }

    private func stop(cancelled: Bool = false, timedOut: Bool = false, overflow: Bool = false) {
        lock.lock()
        if cancelled { self.cancelled = true }
        self.overflow = self.overflow || overflow
        guard let child = process, child.isRunning else { lock.unlock(); return }
        self.timedOut = self.timedOut || timedOut
        child.terminate()
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self, weak child] in
            guard let self, let child else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.process === child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

private final class ProductionWorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var stderrCount = 0
    var output: Data { lock.lock(); defer { lock.unlock() }; return standardOutput }
    func append(_ data: Data, stdout: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stdout {
            guard standardOutput.count + data.count <= 64 * 1_024 else { return false }
            standardOutput.append(data)
        } else {
            stderrCount += data.count
            guard stderrCount <= 16 * 1_024 else { return false }
        }
        return true
    }
}
