import AppKit
import Combine
import Foundation
import Darwin

/// Owns the installed production workspace's loopback process for this app session.
@MainActor
final class ProductionStudioLauncher: NSObject, ObservableObject {
    static let shared = ProductionStudioLauncher()
    @Published private(set) var busy = false
    private var process: Process?
    private var workspaceURL: URL?
    private var launchAttempt: StudioLaunchAttempt?
    private var launchTask: Task<Void, Never>?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: NSApplication.willTerminateNotification, object: nil)
    }

    func open() {
        guard !busy else { return }
        if let process, process.isRunning, let workspaceURL {
            NSWorkspace.shared.open(workspaceURL); return
        }
        busy = true
        let attempt = StudioLaunchAttempt()
        launchAttempt = attempt
        launchTask = Task {
            defer { busy = false; launchAttempt = nil; launchTask = nil }
            do {
                let executable = try ProductionCheckWorker().executableURL()
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Magdobe Illustrator/Production Workspace", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let (child, url) = try await attempt.start(executable: executable, data: directory)
                try Task.checkCancellation()
                process = child; workspaceURL = url
                NSWorkspace.shared.open(url)
            } catch {
                if Task.isCancelled { return }
                let alert = NSAlert()
                alert.messageText = "Production Workspace could not open"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = NSApp.keyWindow { await alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }

    @objc private func stop() {
        launchTask?.cancel(); launchAttempt?.cancel()
        if let process, process.isRunning { process.terminate() }
        process = nil; workspaceURL = nil
    }

    nonisolated static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1", components.user == nil, components.password == nil,
              let port = components.port, (1...65535).contains(port), components.path == "/production/", components.fragment == nil,
              let items = components.queryItems, items.count == 1, items[0].name == "token",
              let token = items[0].value, (32...128).contains(token.count),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw ArtworkError.message("The bundled workspace returned an invalid local address. Reinstall Magdobe.")
        }
        return url
    }
}

final class StudioLaunchAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true
    private var cancelled = false
    private let process = Process()

    func start(executable: URL, data: URL) async throws -> (Process, URL) {
        let attempt = self
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = Pipe()
                attempt.process.executableURL = executable
                attempt.process.arguments = ["serve", "--port", "0", "--data", data.path]
                attempt.process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "PYTHONNOUSERSITE": "1"]
                attempt.process.standardOutput = output; attempt.process.standardError = FileHandle.nullDevice
                attempt.process.standardInput = FileHandle.nullDevice
                attempt.lock.lock()
                if attempt.cancelled { attempt.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                do { try attempt.process.run(); attempt.lock.unlock() }
                catch { attempt.lock.unlock(); continuation.resume(throwing: ProductionCheckWorkerError.unavailable); return }
                try? output.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                    attempt.lock.lock(); let waiting = attempt.pending; attempt.lock.unlock()
                    if waiting { attempt.cancel() }
                }
                var bytes = Data()
                while bytes.count <= 4096 {
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }
                    bytes.append(chunk)
                    if bytes.contains(10) { break }
                }
                attempt.lock.lock(); attempt.pending = false; let cancelled = attempt.cancelled; attempt.lock.unlock()
                do {
                    if cancelled { throw CancellationError() }
                    guard bytes.count <= 4096, attempt.process.isRunning,
                          let first = bytes.split(separator: 10).first,
                          let result = try JSONSerialization.jsonObject(with: Data(first)) as? [String: String],
                          let address = result["url"] else { throw ProductionCheckWorkerError.unavailable }
                    let url = try ProductionStudioLauncher.validatedURL(address)
                    continuation.resume(returning: (attempt.process, url))
                } catch {
                    if attempt.process.isRunning { attempt.process.terminate() }
                    continuation.resume(throwing: error)
                }
            }
          }
        } onCancel: { attempt.cancel() }
    }

    func cancel() {
        lock.lock(); cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
