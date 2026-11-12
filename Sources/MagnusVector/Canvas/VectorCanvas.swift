import SwiftUI
import AppKit

struct VectorCanvas: NSViewRepresentable {
    @ObservedObject var session: EditorSession
    @ObservedObject var document: VectorDocument
    func makeNSView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateNSView(_ view: CanvasView, context: Context) {
        if view.lastFitRequest != session.fitRequest {
            view.lastFitRequest = session.fitRequest
            DispatchQueue.main.async { [weak view] in view?.fitArtboard() }
        }
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class CanvasView: NSView, NSUserInterfaceValidations {
    let session: EditorSession
    var lastFitRequest: UUID?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var down = CGPoint.zero
    private var lastViewPoint = CGPoint.zero
    private var baseline: [VectorShape] = []
    private var baselineIndices: [UUID: Int] = [:]
    private var dragShapeIDs: Set<UUID> = []
    private var initialSelection: Set<UUID> = []
    private var creating: UUID?
    private var moving = false
    private var panning = false
    private var spaceHeld = false
    private var marquee: CGRect?
    private var resizeCorner: Int?
    private var resizeBounds = CGRect.zero
    private var nodeDrag: (shape: UUID, contour: Int, index: Int, handle: Int)?

    init(session: EditorSession) { self.session = session; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.fitArtboard() }
    }
    private var origin: CGPoint {
        CGPoint(x: (bounds.width - session.document.project.width * session.zoom) / 2 + session.pan.width,
                y: (bounds.height - session.document.project.height * session.zoom) / 2 + session.pan.height)
    }
    private func world(_ view: CGPoint) -> CGPoint { CGPoint(x: (view.x - origin.x) / session.zoom, y: (view.y - origin.y) / session.zoom) }
    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    func fitArtboard() {
        guard bounds.width > 100, bounds.height > 100 else { return }
        session.zoom = max(0.02, min(4, min((bounds.width - 100) / session.document.project.width, (bounds.height - 100) / session.document.project.height)))
        session.pan = .zero; lastFitRequest = session.fitRequest; needsDisplay = true
    }
    override func resetCursorRects() {
        let cursor: NSCursor = spaceHeld || session.tool == .hand ? .openHand : ([.pen, .rectangle, .ellipse, .text].contains(session.tool) ? .crosshair : .arrow)
        addCursorRect(bounds, cursor: cursor)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(patternImage: PaperTexture.tile).setFill(); bounds.fill()
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y); ctx.scaleBy(x: session.zoom, y: session.zoom)
        let project = session.document.project
        let artboard = CGRect(x: 0, y: 0, width: project.width, height: project.height)
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 16 / session.zoom, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(artboard)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.saveGState(); ctx.clip(to: artboard)
        if session.grid, session.zoom > 0.14 {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.07).cgColor); ctx.setLineWidth(0.5 / session.zoom)
            let spacing = max(20, ceil(max(project.width, project.height) / 2000) * 20)
            for x in stride(from: 0.0, through: project.width, by: spacing) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: project.height)) }
            for y in stride(from: 0.0, through: project.height, by: spacing) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: project.width, y: y)) }
            ctx.strokePath()
        }
        VectorRenderer.draw(project, in: ctx)
        ctx.restoreGState()
        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.cgColor); ctx.setFillColor(accent.cgColor); ctx.setLineWidth(1 / session.zoom)
        let hierarchy = project.hierarchyIndex
        for shape in session.selectedShapes where !hierarchy.hidden.contains(shape.id) {
            ctx.addPath(shape.cgPath); ctx.strokePath()
            if session.tool == .node || shape.id == session.activePath { drawNodes(shape, context: ctx) }
        }
        if session.tool == .select, !session.editableShapeIDs.isEmpty, let box = session.selectionBounds {
            ctx.setStrokeColor(accent.cgColor); ctx.stroke(box)
            for point in corners(box) { drawHandle(point, context: ctx, filled: false) }
        }
        if let marquee {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor); ctx.fill(marquee)
            ctx.setStrokeColor(accent.cgColor); ctx.stroke(marquee)
        }
        ctx.restoreGState()
        let label = "ARTBOARD 1  ·  \(Int(project.width)) × \(Int(project.height))"
        (label as NSString).draw(at: CGPoint(x: origin.x, y: max(8, origin.y - 23)), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }
    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    private func drawHandle(_ p: CGPoint, context: CGContext, filled: Bool) {
        let size = 7 / session.zoom
        let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        context.setFillColor((filled ? NSColor.controlAccentColor : NSColor.white).cgColor)
        context.fill(r); context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.stroke(r)
    }
    private func drawNodes(_ shape: VectorShape, context: CGContext) {
        for (c, contour) in shape.contours.enumerated() {
        for (i, anchor) in contour.enumerated() {
            for handle in [anchor.incoming, anchor.outgoing].compactMap({ $0 }) {
                context.move(to: anchor.point.cg); context.addLine(to: handle.cg); context.strokePath()
                let size = 5 / session.zoom
                context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in: CGRect(x: handle.x - size / 2, y: handle.y - size / 2, width: size, height: size))
                context.strokeEllipse(in: CGRect(x: handle.x - size / 2, y: handle.y - size / 2, width: size, height: size))
            }
            drawHandle(anchor.point.cg, context: context, filled: session.selectedAnchor == i && session.selectedContour == c)
        }
        }
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private func pick(_ p: CGPoint) -> VectorShape? {
        let index = session.document.project.hierarchyIndex
        return session.document.project.shapes.reversed().first {
            index.canvasTarget(for: $0.id, inside: session.isolatedGroupID) != nil && $0.hitTest(p, tolerance: 5 / session.zoom)
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        down = world(location(event)); lastViewPoint = location(event)
        initialSelection = session.selection; baseline = session.document.project.shapes
        baselineIndices = Dictionary(uniqueKeysWithValues: baseline.enumerated().map { ($0.element.id, $0.offset) })
        if spaceHeld || session.tool == .hand { panning = true; NSCursor.closedHand.set(); return }
        switch session.tool {
        case .select:
            if event.clickCount == 1, let box = session.selectionBounds, !session.editableShapeIDs.isEmpty, let corner = corners(box).firstIndex(where: { distance($0, down) < 8 / session.zoom }) {
                resizeCorner = corner; resizeBounds = box; dragShapeIDs = session.editableShapeIDs; session.beginTransaction(); return
            }
            if let hit = pick(down), let target = session.document.project.hierarchyIndex.canvasTarget(for: hit.id, inside: session.isolatedGroupID) {
                if event.clickCount == 2, session.document.project.hierarchyIndex.nodes[target]?.kind == .group {
                    session.enterGroup(target); needsDisplay = true; return
                }
                if event.modifierFlags.contains(.shift) {
                    if session.selection.contains(target) { session.selection.remove(target) } else { session.selection.insert(target) }
                } else if !session.selection.contains(target) { session.selection = [target] }
                dragShapeIDs = session.editableShapeIDs
                moving = session.selection.contains(target) && !dragShapeIDs.isEmpty
                if moving { session.beginTransaction() }
            } else {
                if event.clickCount == 2, session.isolatedGroupID != nil { session.exitGroup(); needsDisplay = true; return }
                if !event.modifierFlags.contains(.shift) { session.selection = [] }
                marquee = CGRect(origin: down, size: .zero)
            }
        case .node:
            let editable = session.editableShapeIDs
            for shape in session.selectedShapes where editable.contains(shape.id) && shape.visible {
                for (c, contour) in shape.contours.enumerated() {
                for (i, a) in contour.enumerated() {
                    for (handle, p) in [(1, a.incoming), (2, a.outgoing), (0, Optional(a.point))] {
                        if let p, distance(p.cg, down) < 8 / session.zoom {
                            session.selectedAnchor = i; session.selectedContour = c; nodeDrag = (shape.id, c, i, handle); session.beginTransaction(); return
                        }
                    }
                }
                }
            }
            session.selection = pick(down).map { [$0.id] } ?? []; session.selectedAnchor = nil
        case .rectangle, .ellipse:
            guard let destination = session.insertionDestination() else { return }
            session.beginTransaction()
            let shape = session.makeShape(session.tool == .rectangle ? .rectangle : .ellipse, rect: CGRect(origin: down, size: .zero))
            session.document.project.appendShapes([shape], to: destination.parent); creating = shape.id; session.selection = [shape.id]
        case .pen: penDown(down)
        case .text:
            guard let destination = session.insertionDestination() else { return }
            var shape = session.makeShape(.text, rect: CGRect(x: down.x, y: down.y, width: 360, height: 130))
            shape.fill = session.fill; shape.name = "Text"
            session.edit("Add Text") { $0.appendShapes([shape], to: destination.parent) }; session.selection = [shape.id]; session.tool = .select
        case .hand: break
        }
        needsDisplay = true
    }
    private func penDown(_ p: CGPoint) {
        if let id = session.activePath, let i = session.document.project.shapes.firstIndex(where: { $0.id == id }) {
            let shape = session.document.project.shapes[i]
            if shape.anchors.count >= 3, let first = shape.anchors.first, distance(first.point.cg, p) < 10 / session.zoom {
                session.document.project.shapes[i].closed = true; session.finishPath(); return
            }
            session.document.project.shapes[i].anchors.append(Anchor(p))
        } else {
            guard let destination = session.insertionDestination() else { return }
            session.beginTransaction()
            var shape = session.makeShape(.path, rect: .zero); shape.anchors = [Anchor(p)]
            // Open paths start with a visible stroke, even when shape fill was the previous appearance.
            shape.fill = nil; shape.stroke = session.stroke; shape.strokeWidth = max(1, session.strokeWidth)
            session.document.project.appendShapes([shape], to: destination.parent); session.activePath = shape.id; session.selection = [shape.id]
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let viewPoint = location(event), p = world(viewPoint)
        if panning {
            session.pan.width += viewPoint.x - lastViewPoint.x; session.pan.height += viewPoint.y - lastViewPoint.y
            lastViewPoint = viewPoint; needsDisplay = true; return
        }
        var delta = CGSize(width: p.x - down.x, height: p.y - down.y)
        if let id = creating, let i = session.document.project.shapes.firstIndex(where: { $0.id == id }) {
            if event.modifierFlags.contains(.shift) {
                let side = max(abs(delta.width), abs(delta.height)); delta = CGSize(width: delta.width < 0 ? -side : side, height: delta.height < 0 ? -side : side)
            }
            session.document.project.shapes[i].resize(to: normalized(down, CGPoint(x: down.x + delta.width, y: down.y + delta.height)))
        } else if let corner = resizeCorner {
            let opposite = corners(resizeBounds)[(corner + 2) % 4]
            var end = p
            if event.modifierFlags.contains(.shift), resizeBounds.height > 0, resizeBounds.width > 0 {
                let ratio = resizeBounds.width / resizeBounds.height
                let width = max(abs(p.x - opposite.x), abs(p.y - opposite.y) * ratio)
                end = CGPoint(x: opposite.x + (p.x < opposite.x ? -width : width), y: opposite.y + (p.y < opposite.y ? -width / ratio : width / ratio))
            }
            let target = normalized(opposite, end)
            guard resizeBounds.width > 0, resizeBounds.height > 0 else { return }
            let sx = max(0.001, target.width) / resizeBounds.width, sy = max(0.001, target.height) / resizeBounds.height
            for original in baseline where dragShapeIDs.contains(original.id) {
                guard let i = baselineIndices[original.id] else { continue }
                let b = original.bounds
                var shape = original
                shape.resize(to: CGRect(x: target.minX + (b.minX - resizeBounds.minX) * sx, y: target.minY + (b.minY - resizeBounds.minY) * sy, width: b.width * sx, height: b.height * sy))
                session.document.project.shapes[i] = shape
            }
        } else if let node = nodeDrag, let i = session.document.project.shapes.firstIndex(where: { $0.id == node.shape }), let original = baseline.first(where: { $0.id == node.shape }) {
            var a = original.contours[node.contour][node.index]
            if node.handle == 0 { a.translate(delta) }
            else if node.handle == 1 { a.incoming = VectorPoint(p) }
            else { a.outgoing = VectorPoint(p) }
            var contours = session.document.project.shapes[i].contours
            contours[node.contour][node.index] = a
            session.document.project.shapes[i].contours = contours
        } else if moving {
            if event.modifierFlags.contains(.shift) { if abs(delta.width) > abs(delta.height) { delta.height = 0 } else { delta.width = 0 } }
            for original in baseline where dragShapeIDs.contains(original.id) {
                if let i = baselineIndices[original.id] {
                    var shape = original; shape.translate(delta); session.document.project.shapes[i] = shape
                }
            }
        } else if marquee != nil {
            marquee = normalized(down, p)
            let index = session.document.project.hierarchyIndex
            let hits = session.document.project.shapes.filter { marquee!.intersects($0.bounds) }
            session.selection = Set(hits.compactMap { index.canvasTarget(for: $0.id, inside: session.isolatedGroupID) }).union(event.modifierFlags.contains(.shift) ? initialSelection : [])
        } else if session.tool == .pen, let id = session.activePath, let i = session.document.project.shapes.firstIndex(where: { $0.id == id }), let j = session.document.project.shapes[i].anchors.indices.last {
            let anchor = session.document.project.shapes[i].anchors[j].point
            session.document.project.shapes[i].anchors[j].outgoing = VectorPoint(p)
            session.document.project.shapes[i].anchors[j].incoming = VectorPoint(anchor.x * 2 - p.x, anchor.y * 2 - p.y)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let id = creating, let shape = session.document.project.shapes.first(where: { $0.id == id }), shape.width < 1 || shape.height < 1 {
            session.document.project.removeNodes([id]); session.selection.remove(id)
        }
        if creating != nil || moving || resizeCorner != nil || nodeDrag != nil { session.endTransaction(creating != nil ? "Draw Shape" : nodeDrag != nil ? "Edit Anchor" : resizeCorner != nil ? "Resize" : "Move") }
        creating = nil; moving = false; panning = false; marquee = nil; resizeCorner = nil; nodeDrag = nil
        window?.invalidateCursorRects(for: self); needsDisplay = true
    }
    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoom(at: location(event), factor: exp(event.scrollingDeltaY * 0.01))
        } else { session.pan.width += event.scrollingDeltaX; session.pan.height += event.scrollingDeltaY }
    }
    override func magnify(with event: NSEvent) { zoom(at: location(event), factor: 1 + event.magnification) }
    private func zoom(at point: CGPoint, factor: Double) {
        let before = world(point)
        session.zoom = max(0.02, min(32, session.zoom * factor))
        let after = world(point)
        session.pan.width += (after.x - before.x) * session.zoom; session.pan.height += (after.y - before.y) * session.zoom
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 49: spaceHeld = true; window?.invalidateCursorRects(for: self)
        case 51, 117: session.deleteSelection()
        case 36, 76: session.finishPath()
        case 53:
            session.finishPath()
            if session.isolatedGroupID != nil { session.exitGroup() } else { session.selection = [] }
            session.selectedAnchor = nil
        case 123: session.moveSelection(CGSize(width: -step, height: 0))
        case 124: session.moveSelection(CGSize(width: step, height: 0))
        case 125: session.moveSelection(CGSize(width: 0, height: step))
        case 126: session.moveSelection(CGSize(width: 0, height: -step))
        default:
            if let tool = EditorTool.allCases.first(where: { $0.key == key }) { session.selectTool(tool) }
            else { super.keyDown(with: event) }
        }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false; window?.invalidateCursorRects(for: self) } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { spaceHeld = false; return super.resignFirstResponder() }

    override func selectAll(_ sender: Any?) { session.selectAll() }
    @objc func copy(_ sender: Any?) { session.copySelection() }
    @objc func cut(_ sender: Any?) { session.copySelection(); session.deleteSelection() }
    @objc func paste(_ sender: Any?) { session.pasteSelection() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)) { return !session.selection.isEmpty }
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.data(forType: EditorSession.vectorPasteboard) != nil }
        return true
    }
}
