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
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                let destination = self.savePanel?.url
                self.savePanel = nil; self.choosingDestination = false
                if response == .OK, let destination { self.start(project: project, to: destination) }
            }
        }
        // Attach the picker to its owning sheet instead of creating a separate app-modal window.
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
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
