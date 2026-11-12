import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class GenerationStore: ObservableObject {
    @Published var prompt = ""
    @Published var style = "Painted detail"
    @Published var detail = "Balanced"
    @Published var format = "Portrait"
    @Published var reference: URL?
    @Published var connection = "Checking Codex…"
    @Published var connected = false
    @Published var busy = false
    @Published var stage = ""
    @Published var error: String?
    @Published var sourcePreview: NSImage?
    @Published var vectorPreview: NSImage?
    @Published var project: VectorProject?
    @Published var jobFolder: URL?
    @Published var showVectors = true
    private var worker: ArtworkWorker?
    private var task: Task<Void, Never>?
    private var runID = UUID()

    func checkConnection() async {
        connection = "Checking Codex…"
        do {
            try await ArtworkWorker().run(mode: "check") { _ in }
            connected = true; connection = "Connected to Codex · ChatGPT sign-in"
        } catch { connected = false; connection = error.localizedDescription }
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
    func start(image: URL? = nil) {
        guard !busy else { return }
        error = nil; busy = true; project = nil; vectorPreview = nil; sourcePreview = nil
        let id = UUID(); runID = id
        let prompt = self.prompt, detail = self.detail, style = self.style, format = self.format, reference = self.reference
        let worker = ArtworkWorker(); self.worker = worker
        task = Task {
            do {
                if image == nil && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ArtworkError.message("Describe the artwork you want to draw.") }
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Magdobe Illustrator/Artwork")
                let job = root.appendingPathComponent(id.uuidString)
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                var request: [String: Any] = ["prompt": prompt, "style": style, "detail": detail, "format": format.lowercased()]
                if let image {
                    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: image)),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw ArtworkError.message("This image could not be read. Try a PNG or JPEG file.")
                    }
                    let input = job.appendingPathComponent("input.png")
                    try png.write(to: input, options: .atomic)
                    request["image"] = input.path
                }
                if let reference { request["reference"] = reference.path }
                try JSONSerialization.data(withJSONObject: request, options: .prettyPrinted).write(to: job.appendingPathComponent("request.json"), options: .atomic)
                jobFolder = job; stage = image == nil ? "Connecting to Codex…" : "Preparing your image…"
                try await worker.run(mode: image == nil ? "generate" : "trace", job: job) { [weak self] value in
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
                stage = "\(result.0.shapes.count.formatted()) editable objects ready"
            } catch is CancellationError { if runID == id { stage = "Cancelled" } }
            catch { if runID == id { self.error = error.localizedDescription; stage = "" } }
            if runID == id { busy = false; self.worker = nil; task = nil }
        }
    }
    func cancel() {
        runID = UUID(); task?.cancel(); worker?.cancel(); task = nil; worker = nil; busy = false; stage = "Cancelled"
    }
    func revealFiles() { if let jobFolder { NSWorkspace.shared.open(jobFolder) } }
}
