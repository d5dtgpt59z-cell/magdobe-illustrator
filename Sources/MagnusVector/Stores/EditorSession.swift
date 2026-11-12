import SwiftUI
import AppKit

enum EditorTool: String, CaseIterable, Identifiable {
    case select, node, pen, pencil, brush, rectangle, ellipse, text, hand
    var isFreehand: Bool { self == .pencil || self == .brush }
    var id: Self { self }
    var title: String { switch self {
        case .select: "Selection"; case .node: "Direct Selection"; case .pen: "Pen"; case .pencil: "Pencil"; case .brush: "Brush"; case .rectangle: "Rectangle"; case .ellipse: "Ellipse"; case .text: "Text"; case .hand: "Hand"
    } }
    var symbol: String { switch self {
        case .select: "cursorarrow"; case .node: "cursorarrow.square"; case .pen: "point.topleft.down.to.point.bottomright.curvepath"; case .pencil: "pencil"; case .brush: "paintbrush.pointed"; case .rectangle: "rectangle"; case .ellipse: "circle"; case .text: "textformat"; case .hand: "hand.draw"
    } }
    var key: String { switch self {
        case .select: "v"; case .node: "a"; case .pen: "p"; case .pencil: "n"; case .brush: "b"; case .rectangle: "m"; case .ellipse: "l"; case .text: "t"; case .hand: "h"
    } }
    var hint: String { switch self {
        case .select: "Click to select · Shift-click for multiple · Drag corners to resize"
        case .node: "Select a path · Drag anchors or handles · Convert shapes to paths to edit nodes"
        case .pen: "Click for corners · Click-drag for curves · Click first anchor to close · Return to finish"
        case .pencil: "Drag to draw an editable curve · [ / ] size · Escape cancels the stroke"
        case .brush: "Drag to paint editable vectors · [ / ] size · Escape cancels the stroke"
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
    @Published var brushSettings = BrushSettings()
    @Published var pencilSize = 2.0
    @Published var brushColor: VectorColor = .ink
    @Published var activePath: UUID?
    @Published var selectedAnchor: Int?
    @Published var selectedContour = 0
    @Published var error: String?
    @Published var showGeneration = false
    @Published var showSVGExport = false
    let history = UndoManager()
    let dragSessionID = UUID()
    @Published var isolatedGroupID: UUID?
    @Published var activeLayerID: UUID?
    @Published var expandedNodes: Set<UUID> = []
    private struct Snapshot {
        var project: VectorProject
        var selection: Set<UUID>
        var isolation: UUID?
        var layer: UUID?
    }
    private var snapshot: Snapshot { Snapshot(project: document.project, selection: selection, isolation: isolatedGroupID, layer: activeLayerID) }
    private var transactionStart: Snapshot?

    init(document: VectorDocument) { self.document = document; history.levelsOfUndo = 100; history.groupsByEvent = false }
    var selectedShapes: [VectorShape] {
        let ids = document.project.hierarchyIndex.objectIDs(in: selection)
        return document.project.shapes.filter { ids.contains($0.id) }
    }
    var selectedShape: VectorShape? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return document.project.shapes.first { $0.id == id }
    }
    var selectionBounds: CGRect? { selectedShapes.reduce(nil) { r, s in r.map { $0.union(s.bounds) } ?? s.bounds } }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func beginTransaction() { if transactionStart == nil { transactionStart = snapshot } }
    func endTransaction(_ name: String) {
        guard let old = transactionStart else { return }; transactionStart = nil
        if old.project != document.project { register(old, name: name) }
    }
    private func register(_ project: Snapshot, name: String) {
        let ownsGroup = history.groupingLevel == 0
        if ownsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { target in target.restore(project, name: name) }
        history.setActionName(name)
        if ownsGroup { history.endUndoGrouping() }
        objectWillChange.send()
    }
    private func restore(_ state: Snapshot, name: String) {
        let current = snapshot
        document.project = state.project
        selection = state.selection
        isolatedGroupID = state.isolation; activeLayerID = state.layer
        reconcileHierarchyState()
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
            document.project.removeNodes([id]); selection.remove(id)
        }
        activePath = nil; endTransaction("Draw Path")
    }
    func makeShape(_ kind: ShapeKind, rect: CGRect) -> VectorShape {
        VectorShape(name: "\(kind.rawValue.capitalized) \(document.project.shapes.count + 1)", kind: kind, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, fill: hasFill ? fill : nil, stroke: hasStroke ? stroke : nil, strokeWidth: strokeWidth)
    }
    func beginFreehand() -> FreehandStroke? {
        guard tool.isFreehand, let destination = insertionDestination() else { return nil }
        finishPath()
        var settings = brushSettings
        if tool == .pencil { settings.size = pencilSize }
        return FreehandStroke(pencil: tool == .pencil, settings: settings, color: brushColor, parent: destination.parent)
    }
    func commitFreehand(_ stroke: FreehandStroke) {
        if let parent = stroke.parent {
            let index = document.project.hierarchyIndex
            guard index.nodes[parent] != nil, !index.hidden.contains(parent), !index.locked.contains(parent) else {
                error = "The stroke’s layer is no longer editable. Show or unlock it and draw again."; return
            }
        }
        guard document.project.shapes.count < 100_000, let shape = stroke.shape() else { return }
        edit(stroke.pencil ? "Draw Pencil" : "Draw Brush") { $0.appendShapes([shape], to: stroke.parent) }
        selection = [shape.id]; selectedAnchor = nil
    }
    func adjustDrawingSize(_ increase: Bool) {
        let factor = increase ? 1.2 : 1 / 1.2
        if tool == .pencil { pencilSize = min(300, max(1, pencilSize * factor)) }
        else { brushSettings.size = min(300, max(1, brushSettings.size * factor)) }
    }
    func deleteSelection() {
        let ids = Set(editableRoots)
        guard !ids.isEmpty else { return }
        edit("Delete") { $0.removeNodes(ids) }
        selection.subtract(ids); reconcileHierarchyState()
    }
    func duplicate() { duplicateSelection() }
    func modifySelection(_ name: String, _ mutation: (inout VectorShape) -> Void) {
        let ids = editableShapeIDs
        guard !ids.isEmpty else { return }
        edit(name) { project in
            for i in project.shapes.indices where ids.contains(project.shapes[i].id) { mutation(&project.shapes[i]) }
        }
    }
    func setFill(_ color: Color) { fill = VectorColor(color); hasFill = true; modifySelection("Change Fill") { $0.fill = fill } }
    func setStroke(_ color: Color) { stroke = VectorColor(color); hasStroke = true; modifySelection("Change Stroke") { $0.stroke = stroke } }
    func moveSelection(_ delta: CGSize) { modifySelection("Move") { $0.translate(delta) } }
    func reorder(_ front: Bool) { reorderSelection(front) }
    func align(_ axis: String) {
        let index = document.project.hierarchyIndex
        let roots = editableRoots
        guard !roots.isEmpty else { return }
        let units = roots.compactMap { id -> (Set<UUID>, CGRect)? in
            let ids = Set(index.nodes[id]?.objectIDs ?? [])
            guard let box = bounds(of: ids) else { return nil }
            return (ids, box)
        }
        guard let first = units.first else { return }
        let target = roots.count == 1 ? CGRect(x: 0, y: 0, width: document.project.width, height: document.project.height) : units.dropFirst().reduce(first.1) { $0.union($1.1) }
        var offsets: [UUID: CGSize] = [:]
        for (ids, b) in units {
            let delta: CGSize
            switch axis {
            case "left": delta = CGSize(width: target.minX - b.minX, height: 0)
            case "center": delta = CGSize(width: target.midX - b.midX, height: 0)
            case "right": delta = CGSize(width: target.maxX - b.maxX, height: 0)
            case "top": delta = CGSize(width: 0, height: target.minY - b.minY)
            case "middle": delta = CGSize(width: 0, height: target.midY - b.midY)
            default: delta = CGSize(width: 0, height: target.maxY - b.maxY)
            }
            for id in ids { offsets[id] = delta }
        }
        edit("Align") { p in
            for i in p.shapes.indices { if let delta = offsets[p.shapes[i].id] { p.shapes[i].translate(delta) } }
        }
    }
    func setGeometry(_ field: String, value: Double) {
        guard value.isFinite, abs(value) <= 1_000_000, let old = selectionBounds else { return }
        var target = old
        switch field {
        case "x": target.origin.x = value; case "y": target.origin.y = value
        case "width": target.size.width = max(1, value); default: target.size.height = max(1, value)
        }
        modifySelection("Transform") { s in
            let b = s.bounds
            let sx = old.width > 0.001 ? target.width / old.width : 1
            let sy = old.height > 0.001 ? target.height / old.height : 1
            s.resize(to: CGRect(x: target.minX + (b.minX - old.minX) * sx, y: target.minY + (b.minY - old.minY) * sy, width: b.width * sx, height: b.height * sy))
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
        do { _ = try incoming.validated() } catch { self.error = error.localizedDescription; return }
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
        art = remapped(art, offset: .zero, suffix: "")
        guard let destination = insertionDestination() else { return }
        if let parent = destination.parent, document.project.hierarchyIndex.nodes[parent]?.kind == .group,
           art.rootNodes.contains(where: { $0.kind == .layer }) { error = "Exit the group before inserting artwork containing layers."; return }
        structuralEdit("Add Generated Artwork") { p in
            if empty { p.width = art.width; p.height = art.height }
            merge(art, into: &p, parent: destination.parent)
        }
        selection = []; fit()
    }
    func addDemo() {
        guard let destination = insertionDestination() else { return }
        edit("Insert Sample Artwork") { p in
            var a = VectorShape(name: "Violet circle", kind: .ellipse, x: 240, y: 180, width: 360, height: 360, fill: .violet, stroke: nil)
            p.appendShapes([a], to: destination.parent)
            a = VectorShape(name: "Coral square", kind: .rectangle, x: 450, y: 370, width: 230, height: 230, fill: VectorColor(red: 1, green: 0.38, blue: 0.29), stroke: nil)
            p.appendShapes([a], to: destination.parent)
            a = VectorShape(name: "Orbit", kind: .ellipse, x: 160, y: 270, width: 580, height: 190, fill: nil, stroke: .ink, strokeWidth: 5)
            p.appendShapes([a], to: destination.parent)
        }
    }
}
