import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class GenerationStore: ObservableObject {
    @Published var prompt = ""
    @Published var style = "Painted detail"
    @Published var detail: ArtworkDetail = .detailed
    @Published var format = "Portrait"
    @Published var reference: URL?
    @Published var connection = "Checking provider…"
    @Published var connected = false
    @Published var busy = false
    @Published var stage = ""
    @Published var error: String?
    @Published var sourcePreview: NSImage?
    @Published var vectorPreview: NSImage?
    @Published var project: VectorProject?
    @Published var jobFolder: URL?
    @Published var showVectors = true
    @Published private(set) var savedSource: URL?
    @Published private(set) var resultDetail: ArtworkDetail?
    private let providers: ProviderSettings
    @Published var suggesting = false
    @Published var promptSuggestion: String?
    private var assistantWorker: ArtworkWorker?
    private var assistantRunID = UUID()
    private var worker: ArtworkWorker?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private let artworkDirectory: URL

    init(artworkDirectory: URL = ArtworkHistory.directory, providers: ProviderSettings? = nil) {
        self.providers = providers ?? .shared
        self.artworkDirectory = artworkDirectory
        savedSource = ArtworkHistory.latestSource(in: artworkDirectory)
    }

    func checkConnection() async {
        let revision = providers.revision
        connected = false; connection = "Checking provider…"
        do {
            let config = try ProviderConnection.image(providers)
            try await ArtworkWorker().run(mode: "check", connection: config) { _ in }
            guard !Task.isCancelled, providers.revision == revision else { return }
            connected = true
            connection = config.id == "codex" ? "Connected to Codex · ChatGPT sign-in" : "Connected to \(providers.imageProvider.title) · \(config.model)"
        } catch {
            guard !Task.isCancelled, providers.revision == revision else { return }
            connected = false; connection = error.localizedDescription
        }
    }
    func improvePrompt() async {
        guard !busy, !suggesting, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        suggesting = true; error = nil
        let id = UUID(); assistantRunID = id
        let worker = ArtworkWorker(); assistantWorker = worker
        defer { if assistantRunID == id { suggesting = false; assistantWorker = nil } }
        do {
            let config = try ProviderConnection.assistant(providers)
            let folder = artworkDirectory.deletingLastPathComponent().appendingPathComponent("Prompt Suggestions/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["prompt": prompt]).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
            try await worker.run(mode: "improve", job: folder, connection: config) { _ in }
            try Task.checkCancellation()
            guard assistantRunID == id else { return }
            promptSuggestion = try String(contentsOf: folder.appendingPathComponent("prompt-suggestion.txt"), encoding: .utf8)
        } catch is CancellationError { }
        catch { if assistantRunID == id { self.error = error.localizedDescription } }
    }
    func chooseReference() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
        panel.message = "Choose an optional visual reference to send with your prompt."
        if panel.runModal() == .OK { reference = panel.url }
    }
    func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
        panel.message = "Convert a local image into editable artwork."
        if panel.runModal() == .OK, let url = panel.url { start(image: url) }
    }
    func rebuildVectors() {
        guard let source = savedSource else { return }
        start(image: source, preservingResult: true)
    }
    func start(image: URL? = nil, preservingResult: Bool = false) {
        guard !busy, !suggesting else { return }
        error = nil; busy = true
        if !preservingResult { project = nil; vectorPreview = nil; sourcePreview = nil; resultDetail = nil }
        let id = UUID(); runID = id
        let prompt = self.prompt, detail = self.detail, style = self.style, format = self.format, reference = self.reference
        let worker = ArtworkWorker(); self.worker = worker
        task = Task {
            do {
                if image == nil && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ArtworkError.message("Describe the artwork you want to draw.") }
                let provider = image == nil ? try ProviderConnection.image(self.providers) : nil
                let root = self.artworkDirectory
                let job = root.appendingPathComponent(id.uuidString)
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                var request: [String: Any] = ["prompt": prompt, "style": style, "detail": detail.rawValue, "format": format.lowercased()]
                if let image {
                    if preservingResult {
                        // Keep the exact original source pixels, including its resolution.
                        let input = job.appendingPathComponent("input.png")
                        try FileManager.default.copyItem(at: image, to: input)
                        request["image"] = input.path
                    } else {
                        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: image)),
                              let png = bitmap.representation(using: .png, properties: [:]) else {
                            throw ArtworkError.message("This image could not be read. Try a PNG or JPEG file.")
                        }
                        let input = job.appendingPathComponent("input.png")
                        try png.write(to: input, options: .atomic)
                        request["image"] = input.path
                    }
                }
                if let reference { request["reference"] = reference.path }
                if let provider { request["provider"] = provider.workerConfiguration }
                try JSONSerialization.data(withJSONObject: request, options: .prettyPrinted).write(to: job.appendingPathComponent("request.json"), options: .atomic)
                stage = image == nil ? "Connecting to your image provider…" : "Rebuilding \(detail.rawValue.lowercased()) vectors from your image…"
                try await worker.run(mode: image == nil ? "generate" : "trace", job: job, connection: provider) { [weak self] value in
                    let message = value["message"] as? String
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == id else { return }
                        if let message { self.stage = message }
                    }
                }
                try Task.checkCancellation()
                stage = "Rendering your editable vector preview…"
                let result = try await Task.detached(priority: .userInitiated) {
                    let project = try JSONDecoder().decode(VectorProject.self, from: Data(contentsOf: job.appendingPathComponent("artwork.mvector"))).validated()
                    let data = try VectorExporter.data(project, format: .png)
                    try data.write(to: job.appendingPathComponent("vector-preview.png"), options: .atomic)
                    return (project, data)
                }.value
                try Task.checkCancellation()
                guard runID == id else { return }
                self.project = result.0; vectorPreview = NSImage(data: result.1)
                sourcePreview = NSImage(contentsOf: job.appendingPathComponent("source.png"))
                savedSource = job.appendingPathComponent("source.png"); jobFolder = job; resultDetail = detail
                stage = "\(result.0.shapes.count.formatted()) editable objects · \(detail.rawValue)"
            } catch is CancellationError { if runID == id { stage = "Cancelled" } }
            catch { if runID == id { self.error = error.localizedDescription; stage = "" } }
            if runID == id { busy = false; self.worker = nil; task = nil }
        }
    }
    func cancel() {
        assistantRunID = UUID(); assistantWorker?.cancel(); assistantWorker = nil; suggesting = false
        runID = UUID(); task?.cancel(); worker?.cancel(); task = nil; worker = nil; busy = false; stage = "Cancelled"
    }
    func revealFiles() { if let jobFolder { NSWorkspace.shared.open(jobFolder) } }
}
