import Foundation

/// Distribution bundles own a frozen helper. Source builds can still use their local Python runtime.
struct ArtworkRuntime {
    static let helperRelativePath = "Contents/Helpers/MagdobeArtworkWorker.app/Contents/MacOS/MagdobeArtworkWorker"
    let executableURL: URL
    let workerScriptURL: URL?
    let codexURL: URL?
    var usesBundledHelper: Bool { workerScriptURL == nil }

    private struct DevelopmentConfiguration: Decodable { let python: String }

    static func load() throws -> ArtworkRuntime {
        try resolve(bundleURL: Bundle.main.bundleURL,
                    environment: ProcessInfo.processInfo.environment,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func resolve(bundleURL: URL, environment: [String: String], homeDirectory: URL,
                        fileManager: FileManager = .default, isExecutable: ((URL) -> Bool)? = nil) throws -> ArtworkRuntime {
        let executable = isExecutable ?? { fileManager.isExecutableFile(atPath: $0.path) }
        let codex = findCodex(environment: environment, homeDirectory: homeDirectory, isExecutable: executable)
        let helperBundle = bundleURL.appendingPathComponent("Contents/Helpers/MagdobeArtworkWorker.app", isDirectory: true)
        let helper = bundleURL.appendingPathComponent(helperRelativePath)
        if fileManager.fileExists(atPath: helperBundle.path) {
            guard executable(helper) else {
                throw ArtworkError.message("Magdobe’s bundled artwork helper is missing or cannot be launched. Reinstall the application.")
            }
            return ArtworkRuntime(executableURL: helper, workerScriptURL: nil, codexURL: codex)
        }
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let configuration = resources.appendingPathComponent("runtime.json")
        guard fileManager.fileExists(atPath: configuration.path) else {
            throw ArtworkError.message("The artwork runtime is missing. Reinstall Magdobe, or rebuild the application if you are working from source.")
        }
        let development: DevelopmentConfiguration
        do { development = try JSONDecoder().decode(DevelopmentConfiguration.self, from: Data(contentsOf: configuration)) }
        catch { throw ArtworkError.message("The source-build artwork runtime configuration is invalid. Rebuild the application from source.") }
        let python = URL(fileURLWithPath: development.python)
        guard development.python.hasPrefix("/"), executable(python) else {
            throw ArtworkError.message("The source-build Python runtime is unavailable. Rebuild from source, or install the packaged Magdobe application.")
        }
        let script = resources.appendingPathComponent("Artwork/artwork_worker.py")
        guard fileManager.isReadableFile(atPath: script.path) else {
            throw ArtworkError.message("The artwork worker is missing from the application. Reinstall Magdobe, or rebuild from source.")
        }
        return ArtworkRuntime(executableURL: python, workerScriptURL: script, codexURL: codex)
    }

    static func findCodex(environment: [String: String], homeDirectory: URL,
                          isExecutable: (URL) -> Bool) -> URL? {
        // Resolve on every operation so installing Codex later does not require rebuilding Magdobe.
        var candidates = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        candidates += [homeDirectory.appendingPathComponent(".local/bin/codex"),
                       URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        for applications in [homeDirectory.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            for name in ["Codex.app", "ChatGPT.app"] {
                let app = applications.appendingPathComponent(name)
                for path in ["Contents/Resources/codex-cli/bin/codex",
                             "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                             "Contents/Resources/codex"] {
                    candidates.append(app.appendingPathComponent(path))
                }
            }
        }
        return candidates.first(where: isExecutable)
    }

    func arguments(mode: String, job: URL?, requiresCodex: Bool) throws -> [String] {
        if requiresCodex, codexURL == nil {
            throw ArtworkError.message("Codex is not installed or could not be found. Install Codex and sign in, or choose an API image provider in AI Providers settings. You do not need to rebuild Magdobe.")
        }
        var arguments = workerScriptURL.map { [$0.path] } ?? []
        arguments.append(mode)
        if let codexURL { arguments += ["--codex", codexURL.path] }
        if let job { arguments += ["--job", job.path, "--request", job.appendingPathComponent("request.json").path] }
        return arguments
    }
}

enum ArtworkError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

final class ArtworkWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    func run(mode: String, job: URL? = nil, connection: ProviderConnection? = nil, event: @escaping @Sendable ([String: Any]) -> Void) async throws {
        let runtime = try ArtworkRuntime.load()
        let requiresCodex = mode != "trace" && (connection?.id ?? "codex") == "codex"
        let arguments = try runtime.arguments(mode: mode, job: job, requiresCodex: requiresCodex)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process(); let pipe = Pipe()
                    p.executableURL = runtime.executableURL
                    p.arguments = arguments
                    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                    var environment = ProcessInfo.processInfo.environment
                    // The bundled runtime must not import a developer/user Python installation.
                    if runtime.usesBundledHelper {
                        for name in ["PYTHONHOME", "PYTHONPATH", "PYTHONEXECUTABLE", "__PYVENV_LAUNCHER__"] { environment.removeValue(forKey: name) }
                        environment["PYTHONNOUSERSITE"] = "1"
                    }
                    environment["PYTHONUNBUFFERED"] = "1"
                    let inheritedPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
                    var paths: [String] = []
                    for path in [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
                        + inheritedPaths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                        where path.hasPrefix("/") && !paths.contains(path) { paths.append(path) }
                    environment["PATH"] = paths.joined(separator: ":")
                    environment.removeValue(forKey: "MAGDOBE_PROVIDER_API_KEY")
                    environment.removeValue(forKey: "MAGDOBE_PROVIDER_CONFIG")
                    if let connection {
                        let config = try? JSONSerialization.data(withJSONObject: connection.workerConfiguration)
                        environment["MAGDOBE_PROVIDER_CONFIG"] = config.map { String(decoding: $0, as: UTF8.self) }
                        if let key = connection.apiKey { environment["MAGDOBE_PROVIDER_API_KEY"] = key }
                    }
                    p.environment = environment
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    self.process = p
                    do { try p.run(); self.lock.unlock() }
                    catch { self.lock.unlock(); continuation.resume(throwing: error); return }
                    var buffer = Data(); var reportedError: String?
                    while true {
                        let bytes = pipe.fileHandleForReading.availableData
                        if bytes.isEmpty { break }
                        buffer.append(bytes)
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                            if value["stage"] as? String == "error" { reportedError = value["message"] as? String }
                            event(value)
                        }
                    }
                    p.waitUntilExit()
                    self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                    if wasCancelled { continuation.resume(throwing: CancellationError()) }
                    else if p.terminationStatus != 0 { continuation.resume(throwing: ArtworkError.message(reportedError ?? "The artwork process stopped. Try again or check the provider connection.")) }
                    else { continuation.resume() }
                }
            }
        } onCancel: { self.cancel() }
    }
}
