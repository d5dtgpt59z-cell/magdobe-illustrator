import SwiftUI
import AppKit

enum EditorTool: String, CaseIterable, Identifiable {
    case select, node, pen, rectangle, ellipse, text, hand
    var id: Self { self }
    var title: String { switch self {
        case .select: "Selection"; case .node: "Direct Selection"; case .pen: "Pen"; case .rectangle: "Rectangle"; case .ellipse: "Ellipse"; case .text: "Text"; case .hand: "Hand"
    } }
    var symbol: String { switch self {
        case .select: "cursorarrow"; case .node: "cursorarrow.square"; case .pen: "point.topleft.down.to.point.bottomright.curvepath"; case .rectangle: "rectangle"; case .ellipse: "circle"; case .text: "textformat"; case .hand: "hand.draw"
    } }
    var key: String { switch self {
        case .select: "v"; case .node: "a"; case .pen: "p"; case .rectangle: "m"; case .ellipse: "l"; case .text: "t"; case .hand: "h"
    } }
    var hint: String { switch self {
        case .select: "Click to select · Shift-click for multiple · Drag corners to resize"
        case .node: "Select a path · Drag anchors or handles · Convert shapes to paths to edit nodes"
        case .pen: "Click for corners · Click-drag for curves · Click first anchor to close · Return to finish"
        case .rectangle, .ellipse: "Drag to draw · Hold Shift for equal sides"
        case .text: "Click to place text · Edit the wording in the inspector"
        case .hand: "Drag to pan · Scroll to pan · Pinch to zoom"
    } }
}

final class EditorSession: ObservableObject {
    let document: VectorDocument
    @Published var selection: Set<UUID> = []
    @Published var tool: EditorTool = .select
    @Published var zoom: Double = 0.7
    @Published var pan: CGSize = .zero
    @Published var fitRequest = UUID()
    @Published var grid = false
    @Published var fill: VectorColor = .violet
    @Published var stroke: VectorColor = .ink
    @Published var hasFill = true
    @Published var hasStroke = false
    @Published var strokeWidth: Double = 2
    @Published var activePath: UUID?
    @Published var selectedAnchor: Int?
    @Published var selectedContour = 0
    @Published var error: String?
    @Published var showGeneration = false
    @Published var showSVGExport = false
    let history = UndoManager()
    private var transactionStart: VectorProject?

    init(document: VectorDocument) { self.document = document; history.levelsOfUndo = 100 }
    var selectedShapes: [VectorShape] { document.project.shapes.filter { selection.contains($0.id) } }
    var selectedShape: VectorShape? { selectedShapes.count == 1 ? selectedShapes.first : nil }
    var selectionBounds: CGRect? { selectedShapes.reduce(nil) { r, s in r.map { $0.union(s.bounds) } ?? s.bounds } }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func beginTransaction() { if transactionStart == nil { transactionStart = document.project } }
    func endTransaction(_ name: String) {
        guard let old = transactionStart else { return }; transactionStart = nil
        if old != document.project { register(old, name: name) }
    }
    private func register(_ project: VectorProject, name: String) {
        history.registerUndo(withTarget: self) { target in target.restore(project, name: name) }
        history.setActionName(name); objectWillChange.send()
    }
    private func restore(_ project: VectorProject, name: String) {
        let current = document.project
        document.project = project
        selection.formIntersection(Set(project.shapes.map(\.id)))
        activePath = nil; selectedAnchor = nil
        register(current, name: name)
    }
    func edit(_ name: String, _ mutation: (inout VectorProject) -> Void) {
        finishPath(); beginTransaction(); mutation(&document.project); endTransaction(name)
    }
    func undo() { finishPath(); history.undo(); objectWillChange.send() }
    func redo() { finishPath(); history.redo(); objectWillChange.send() }
    func selectTool(_ next: EditorTool) { finishPath(); tool = next; selectedAnchor = nil }
    func fit() { fitRequest = UUID() }
    func finishPath() {
        guard activePath != nil else { return }
        if let id = activePath, let i = document.project.shapes.firstIndex(where: { $0.id == id }), document.project.shapes[i].anchors.count < 2 {
            document.project.shapes.remove(at: i); selection.remove(id)
        }
        activePath = nil; endTransaction("Draw Path")
    }
    func makeShape(_ kind: ShapeKind, rect: CGRect) -> VectorShape {
        VectorShape(name: "\(kind.rawValue.capitalized) \(document.project.shapes.count + 1)", kind: kind, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, fill: hasFill ? fill : nil, stroke: hasStroke ? stroke : nil, strokeWidth: strokeWidth)
    }
    func deleteSelection() {
        let ids = selection
        edit("Delete") { $0.shapes.removeAll { ids.contains($0.id) && !$0.locked } }
        selection = []
    }
    func duplicate() {
        let originals = selectedShapes.filter { !$0.locked }
        guard !originals.isEmpty else { return }
        var copies = originals.map { s in var s = s; s.id = UUID(); s.name += " copy"; s.translate(CGSize(width: 20, height: 20)); return s }
        for i in copies.indices { copies[i].contours = copies[i].contours.map { $0.map { a in var a = a; a.id = UUID(); return a } } }
        edit("Duplicate") { $0.shapes.append(contentsOf: copies) }; selection = Set(copies.map(\.id))
    }
    func modifySelection(_ name: String, _ mutation: (inout VectorShape) -> Void) {
        let ids = selection
        edit(name) { project in
            for i in project.shapes.indices where ids.contains(project.shapes[i].id) && !project.shapes[i].locked { mutation(&project.shapes[i]) }
        }
    }
    func setFill(_ color: Color) { fill = VectorColor(color); hasFill = true; modifySelection("Change Fill") { $0.fill = fill } }
    func setStroke(_ color: Color) { stroke = VectorColor(color); hasStroke = true; modifySelection("Change Stroke") { $0.stroke = stroke } }
    func moveSelection(_ delta: CGSize) { modifySelection("Move") { $0.translate(delta) } }
    func reorder(_ front: Bool) {
        let ids = selection
        edit(front ? "Bring to Front" : "Send to Back") { p in
            let selected = p.shapes.filter { ids.contains($0.id) && !$0.locked }
            let selectedIDs = Set(selected.map(\.id))
            p.shapes.removeAll { selectedIDs.contains($0.id) }
            p.shapes.insert(contentsOf: selected, at: front ? p.shapes.count : 0)
        }
    }
    func align(_ axis: String) {
        guard let bounds = selectionBounds else { return }
        let target = selectedShapes.count == 1 ? CGRect(x: 0, y: 0, width: document.project.width, height: document.project.height) : bounds
        modifySelection("Align") { s in
            let b = s.bounds
            switch axis {
            case "left": s.translate(CGSize(width: target.minX - b.minX, height: 0))
            case "center": s.translate(CGSize(width: target.midX - b.midX, height: 0))
            case "right": s.translate(CGSize(width: target.maxX - b.maxX, height: 0))
            case "top": s.translate(CGSize(width: 0, height: target.minY - b.minY))
            case "middle": s.translate(CGSize(width: 0, height: target.midY - b.midY))
            default: s.translate(CGSize(width: 0, height: target.maxY - b.maxY))
            }
        }
    }
    func setGeometry(_ field: String, value: Double) {
        guard value.isFinite else { return }
        modifySelection("Transform") { s in
            var b = s.bounds
            switch field {
            case "x": b.origin.x = value; case "y": b.origin.y = value
            case "width": b.size.width = max(1, value); default: b.size.height = max(1, value)
            }
            s.resize(to: b)
        }
    }
    func export(_ format: ExportFormat) {
        if format == .svg { showSVGExport = true; return }
        finishPath()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.\(format.rawValue)"
        panel.allowedContentTypes = [format.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try VectorExporter.data(document.project, format: format).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    func insertArtwork(_ incoming: VectorProject) {
        var art = incoming
        let empty = document.project.shapes.isEmpty
        if !empty {
            let scale = min(document.project.width / art.width, document.project.height / art.height) * 0.85
            let dx = (document.project.width - art.width * scale) / 2
            let dy = (document.project.height - art.height * scale) / 2
            for i in art.shapes.indices {
                let b = art.shapes[i].bounds
                art.shapes[i].resize(to: CGRect(x: dx + b.minX * scale, y: dy + b.minY * scale, width: b.width * scale, height: b.height * scale))
                art.shapes[i].strokeWidth *= scale
            }
        }
        for i in art.shapes.indices {
            art.shapes[i].id = UUID()
            art.shapes[i].contours = art.shapes[i].contours.map { $0.map { a in var a = a; a.id = UUID(); return a } }
        }
        edit("Add Generated Artwork") { p in
            if empty { p.width = art.width; p.height = art.height }
            p.shapes.append(contentsOf: art.shapes)
        }
        selection = []; fit()
    }
    func addDemo() {
        edit("Insert Sample Artwork") { p in
            var a = VectorShape(name: "Violet circle", kind: .ellipse, x: 240, y: 180, width: 360, height: 360, fill: .violet, stroke: nil)
            p.shapes.append(a)
            a = VectorShape(name: "Coral square", kind: .rectangle, x: 450, y: 370, width: 230, height: 230, fill: VectorColor(red: 1, green: 0.38, blue: 0.29), stroke: nil)
            p.shapes.append(a)
            a = VectorShape(name: "Orbit", kind: .ellipse, x: 160, y: 270, width: 580, height: 190, fill: nil, stroke: .ink, strokeWidth: 5)
            p.shapes.append(a)
        }
    }
}
