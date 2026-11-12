import AppKit

extension EditorSession {
    static let vectorPasteboard = NSPasteboard.PasteboardType("com.builtbymagnus.vector.objects")
    func copySelection() {
        finishPath()
        guard let project = selectionProject(), let data = try? JSONEncoder().encode(project) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.vectorPasteboard)
        if let svg = try? VectorExporter.svg(project) { pasteboard.setString(svg, forType: .string) }
    }
    func pasteSelection() {
        guard let data = NSPasteboard.general.data(forType: Self.vectorPasteboard) else { return }
        if let project = try? JSONDecoder().decode(VectorProject.self, from: data) { pasteProject(project) }
        else if let shapes = try? JSONDecoder().decode([VectorShape].self, from: data) { pasteProject(VectorProject(shapes: shapes)) }
    }
}
