import SwiftUI
import AppKit

@MainActor
final class SVGExportStore: ObservableObject {
    @Published var options = SVGExportOptions()
    @Published var busy = false
    @Published var choosingDestination = false
    @Published var completed = 0
    @Published var total = 0
    @Published var error: String?
    @Published var exportedURL: URL?
    private var task: Task<Void, Never>?
    private var worker: Task<Void, Error>?

    func chooseDestination(project: VectorProject) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = "Artwork.svg"
        panel.title = "Export SVG"
        panel.message = "Save editable vector artwork."
        panel.canCreateDirectories = true
        choosingDestination = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.choosingDestination = false
                if response == .OK, let url = panel.url { self.start(project: project, to: url) }
            }
        }
    }
    func start(project: VectorProject, to url: URL) {
        guard !busy else { return }
        error = nil; exportedURL = nil; busy = true; completed = 0; total = project.shapes.count
        let options = self.options
        // Value snapshot + copy-on-write: exporting never touches the editor or its undo state.
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try SVGExporter.write(project, to: url, options: options) { done, count in
                Task { @MainActor [weak self] in self?.completed = done; self?.total = count }
            }
        }
        self.worker = worker
        task = Task { [weak self] in
            do { try await worker.value; self?.exportedURL = url }
            catch is CancellationError { self?.error = "Export cancelled. Your document and any existing destination file were kept." }
            catch { self?.error = error.localizedDescription }
            self?.busy = false; self?.worker = nil; self?.task = nil
        }
    }
    func cancel() { worker?.cancel() }
}

struct SVGExportView: View {
    @ObservedObject var session: EditorSession
    @StateObject private var exporter = SVGExportStore()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Export SVG", systemImage: "square.and.arrow.up").font(.title2.bold())
                Spacer()
                Text("\(session.document.project.shapes.count.formatted()) objects").foregroundStyle(.secondary)
            }
            Text("Keep your artwork editable in vector applications.").foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Preserve editable layers", isOn: $exporter.options.preserveEditableLayers)
                    .help("Keep the Layers list as named SVG groups in its original order, including hidden objects")
                Toggle("Convert text to outlines", isOn: $exporter.options.convertTextToOutlines)
                    .help("Replace text with vector glyph contours to preserve its appearance without requiring the font")
                Toggle("Optimize SVG", isOn: $exporter.options.optimize)
                    .help("Remove formatting whitespace only; keep every object and the full precision of every curve")
                Toggle("Export entire artboard", isOn: $exporter.options.entireArtboard)
                    .help("Keep the artboard dimensions and clipping. Turn off to fit the visible drawing, including artwork outside the artboard.")
            }.toggleStyle(.checkbox).disabled(exporter.busy || exporter.choosingDestination)
            Text("Layers become named groups. Editable text may use a substitute font in another app; outlines preserve the glyph shapes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if exporter.busy {
                ProgressView(value: Double(exporter.completed), total: Double(max(1, exporter.total)))
                Text("Exporting \(exporter.completed.formatted()) of \(exporter.total.formatted()) objects…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = exporter.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let url = exporter.exportedURL {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(2)
            }
            Divider()
            HStack {
                if let url = exporter.exportedURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.help("Reveal the exported SVG file")
                }
                Spacer()
                if exporter.busy {
                    Button("Cancel Export") { exporter.cancel() }.help("Cancel this export without changing the document or destination file")
                } else {
                    Button(exporter.exportedURL == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).help("Return to the document")
                    Button("Export…") { exporter.chooseDestination(project: session.document.project) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).help("Choose where to save the SVG")
                }
            }.disabled(exporter.choosingDestination)
        }
        .padding(24).frame(width: 470)
        .background(PaperTexture.surface).preferredColorScheme(.light).tint(PaperTexture.accent)
        .interactiveDismissDisabled(exporter.busy || exporter.choosingDestination)
        .onDisappear { exporter.cancel() }
    }
}
