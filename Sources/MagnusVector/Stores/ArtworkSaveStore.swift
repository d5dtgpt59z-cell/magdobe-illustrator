import SwiftUI
import AppKit

@MainActor
final class ArtworkSaveStore: ObservableObject {
    @Published var format: ArtworkFileFormat
    @Published var options = SVGExportOptions()
    @Published private(set) var busy = false
    @Published private(set) var choosingDestination = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    private var worker: Task<Void, Error>?
    private var savePanel: NSSavePanel?

    init(format: ArtworkFileFormat) { self.format = format }

    func clearReceipt() { savedURL = nil; error = nil }

    func chooseDestination(project: VectorProject) {
        guard !busy, !choosingDestination else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "Artwork.\(format.fileExtension)"
        panel.title = format == .project ? "Save Editable Project" : "Export \(format.title)"
        panel.message = format.explanation
        panel.prompt = format == .project ? "Save" : "Export"
        panel.canCreateDirectories = true
        savePanel = panel; choosingDestination = true
        panel.directoryURL = UserDefaults.standard.url(forKey: "artwork.lastExportDirectory")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        // Use the panel's own event loop; nesting another sheet in a SwiftUI sheet can
        // leave destination validation disabled. File writing begins after it closes.
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        let destination = panel.url
        savePanel = nil; choosingDestination = false
        if response == .OK, let destination {
            UserDefaults.standard.set(destination.deletingLastPathComponent(), forKey: "artwork.lastExportDirectory")
            start(project: project, to: destination)
        }
    }

    func start(project: VectorProject, to url: URL) {
        guard !busy else { return }
        clearReceipt(); busy = true; completed = 0; total = project.shapes.count
        let format = self.format, options = self.options
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try ArtworkFileWriter.write(project, format: format, to: url, svgOptions: options) { done, count in
                Task { @MainActor [weak self] in self?.completed = done; self?.total = count }
            }
        }
        self.worker = worker
        Task { [weak self] in
            do { try await worker.value; self?.savedURL = url }
            catch is CancellationError { self?.error = "Save cancelled. Your artwork and any existing destination file were kept." }
            catch { self?.error = error.localizedDescription }
            self?.busy = false; self?.worker = nil
        }
    }

    func openSavedFile() {
        guard let url = savedURL else { return }
        let application: URL?
        switch format {
        case .project: application = Bundle.main.bundleURL
        case .svg: application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        case .pdf, .png: application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        }
        guard let application else { error = "The viewer could not be found. Use Show in Finder to open the saved file."; return }
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.error = "The file was saved, but could not be opened: \(error.localizedDescription)" } }
        }
    }
    func revealSavedFile() { if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) } }
    func cancel() { worker?.cancel() }
}
