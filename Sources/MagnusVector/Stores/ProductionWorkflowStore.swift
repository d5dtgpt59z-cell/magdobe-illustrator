import AppKit
import SwiftUI

@MainActor
final class ProductionWorkflowStore: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var choosingDestination = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var stage = ""
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    @Published private(set) var result: ProductionCheckResult?
    private var task: Task<Void, Never>?
    private var savePanel: NSSavePanel?

    func export(project: VectorProject, spec: ProductionSpec) {
        guard !busy, !choosingDestination else { return }
        do { _ = try spec.validated() } catch { self.error = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = "Artwork-production.svg"
        panel.title = "Export Production SVG"
        panel.message = "Editable RGB vectors at the specified physical size, including bleed. This is not a PDF/X or CMYK export."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.directoryURL = UserDefaults.standard.url(forKey: "artwork.lastExportDirectory")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        savePanel = panel; choosingDestination = true
        // A standalone asynchronous panel lets SwiftUI's main-actor callback
        // return so AppKit can validate the destination; do not nest sheets.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            Task { @MainActor in
                guard let self, let panel, self.savePanel === panel else { return }
                let destination = response == .OK ? panel.url : nil
                self.savePanel = nil; self.choosingDestination = false
                guard let url = destination else { return }
                UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "artwork.lastExportDirectory")
                self.start(project: project, spec: spec, destination: url)
            }
        }
    }
    func check(project: VectorProject, spec: ProductionSpec) { start(project: project, spec: spec, destination: nil) }
    private func start(project: VectorProject, spec: ProductionSpec, destination: URL?) {
        guard !busy, !choosingDestination else { return }
        error = nil; savedURL = nil; result = nil; busy = true; total = project.shapes.count; completed = 0
        stage = destination == nil ? "Preparing a vector snapshot…" : "Exporting production SVG…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let progress: (Int, Int) -> Void = { [weak self] done, count in
                    Task { @MainActor in self?.completed = done; self?.total = count }
                }
                if let destination {
                    let exporter = Task.detached(priority: .userInitiated) { try ProductionSVGExporter.write(project, spec: spec, to: destination, progress: progress) }
                    try await withTaskCancellationHandler { try await exporter.value } onCancel: { exporter.cancel() }
                    try Task.checkCancellation(); savedURL = destination
                } else {
                    let exporter = Task.detached(priority: .userInitiated) { try ProductionSVGExporter.data(project, spec: spec, progress: progress) }
                    let svg = try await withTaskCancellationHandler { try await exporter.value } onCancel: { exporter.cancel() }
                    try Task.checkCancellation(); stage = "Checking this snapshot locally…"
                    result = try await ProductionCheckWorker.check(svg: svg, filename: "Artwork-production.svg", job: spec.jobData())
                }
            } catch is CancellationError { error = "Production check or export cancelled. Your artwork was kept." }
            catch { self.error = error.localizedDescription }
            busy = false; stage = ""; task = nil
        }
    }
    func cancel() { task?.cancel(); savePanel?.cancel(nil) }
    func clearReceipts() {
        guard !busy else { return }
        result = nil; savedURL = nil; error = nil
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openReport() { if let url = result?.reportURL { NSWorkspace.shared.open(url) } }
}
