import SwiftUI

struct InspectorView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var document: VectorDocument
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionTitle("PROPERTIES")
                    if let shape = session.selectedShape {
                        TextField("Object name", text: Binding(get: { session.selectedShape?.name ?? "" }, set: { value in session.modifySelection("Rename") { $0.name = value } }))
                            .font(.headline).textFieldStyle(.plain).help("Rename the selected object")
                        transform(shape)
                    } else {
                        Text(session.selection.isEmpty ? "Artboard" : "\(session.selection.count) objects").font(.headline)
                        if session.selection.isEmpty {
                            HStack {
                                NumericField(label: "W", value: document.project.width) { v in if (1...100_000).contains(v) { session.edit("Resize Artboard") { $0.width = v }; session.fit() } }
                                NumericField(label: "H", value: document.project.height) { v in if (1...100_000).contains(v) { session.edit("Resize Artboard") { $0.height = v }; session.fit() } }
                            }
                        }
                    }
                    appearance
                    if let shape = session.selectedShape, shape.kind == .text { textProperties(shape) }
                    if !session.selection.isEmpty { alignment }
                    if let shape = session.selectedShape, shape.kind == .rectangle || shape.kind == .ellipse {
                        Button("Convert to Editable Path") {
                            session.modifySelection("Convert to Path") { $0.convertToPath() }; session.selectTool(.node)
                        }.frame(maxWidth: .infinity).help("Turn this shape into editable Bézier anchors (⇧⌘O)")
                    }
                    if document.project.shapes.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("A blank canvas. All yours.").fontWeight(.medium)
                            Text("Choose a shape or the pen tool and draw on the artboard.").foregroundStyle(.secondary)
                            Button("Insert Sample Artwork") { session.addDemo() }.help("Add three sample shapes to try the editor")
                        }.font(.system(size: 12)).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                sectionTitle("LAYERS")
                Spacer()
                Text("\(document.project.shapes.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            if document.project.shapes.isEmpty {
                ContentUnavailableView("No objects yet", systemImage: "square.3.layers.3d").frame(height: 190)
            } else {
                List(selection: $session.selection) {
                    ForEach(document.project.shapes.reversed()) { shape in
                        HStack(spacing: 7) {
                            Image(systemName: shape.kind == .ellipse ? "circle" : shape.kind == .text ? "textformat" : shape.kind == .path ? "point.topleft.down.to.point.bottomright.curvepath" : "rectangle")
                                .foregroundStyle((shape.fill ?? shape.stroke ?? .ink).color).frame(width: 16)
                            Text(shape.name).lineLimit(1).foregroundStyle(shape.visible ? .primary : .secondary)
                            Spacer(minLength: 0)
                            Button { toggle(shape.id, key: "locked") } label: { Image(systemName: shape.locked ? "lock.fill" : "lock.open").foregroundStyle(.secondary) }.buttonStyle(.borderless).help(shape.locked ? "Unlock" : "Lock")
                            Button { toggle(shape.id, key: "visible") } label: { Image(systemName: shape.visible ? "eye" : "eye.slash").foregroundStyle(.secondary) }.buttonStyle(.borderless).help(shape.visible ? "Hide" : "Show")
                        }.font(.system(size: 12)).tag(shape.id).help("Select \(shape.name). Shift-click to select multiple objects.")
                    }
                }.scrollContentBackground(.hidden).listStyle(.sidebar).frame(minHeight: 170, idealHeight: 250, maxHeight: 290)
            }
            Divider()
            HStack {
                Button { session.duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate (⌘D)")
                Button { session.reorder(true) } label: { Image(systemName: "square.3.layers.3d.top.filled") }.help("Bring to front")
                Button { session.reorder(false) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }.help("Send to back")
                Spacer()
                Button { session.deleteSelection() } label: { Image(systemName: "trash") }.help("Delete")
            }.buttonStyle(.borderless).disabled(session.selection.isEmpty).padding(14)
        }.background(PaperTexture.surface)
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary) }
    private func transform(_ shape: VectorShape) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TRANSFORM")
            HStack {
                NumericField(label: "X", value: shape.bounds.minX) { session.setGeometry("x", value: $0) }
                NumericField(label: "Y", value: shape.bounds.minY) { session.setGeometry("y", value: $0) }
            }
            HStack {
                NumericField(label: "W", value: shape.bounds.width) { session.setGeometry("width", value: $0) }
                NumericField(label: "H", value: shape.bounds.height) { session.setGeometry("height", value: $0) }
            }
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("APPEARANCE")
            HStack {
                Toggle("Fill", isOn: Binding(get: { session.selectedShape.map { $0.fill != nil } ?? session.hasFill }, set: { enabled in session.hasFill = enabled; session.modifySelection("Toggle Fill") { $0.fill = enabled ? session.fill : nil } })).help("Enable or disable this appearance for the selection")
                Spacer()
                ColorPicker("Fill color", selection: Binding(get: { session.selectedShape?.fill?.color ?? session.fill.color }, set: { session.setFill($0) }), supportsOpacity: true).labelsHidden().help("Choose the color and transparency")
            }
            HStack {
                Toggle("Stroke", isOn: Binding(get: { session.selectedShape.map { $0.stroke != nil } ?? session.hasStroke }, set: { enabled in session.hasStroke = enabled; session.modifySelection("Toggle Stroke") { $0.stroke = enabled ? session.stroke : nil } })).help("Enable or disable this appearance for the selection")
                Spacer()
                ColorPicker("Stroke color", selection: Binding(get: { session.selectedShape?.stroke?.color ?? session.stroke.color }, set: { session.setStroke($0) }), supportsOpacity: true).labelsHidden().help("Choose the color and transparency")
            }
            NumericField(label: "Weight", value: session.selectedShape?.strokeWidth ?? session.strokeWidth) { value in
                session.strokeWidth = max(0, min(1000, value)); session.modifySelection("Stroke Weight") { $0.strokeWidth = session.strokeWidth }
            }
            if let shape = session.selectedShape {
                NumericField(label: "Opacity %", value: shape.opacity * 100) { value in session.modifySelection("Opacity") { $0.opacity = max(0, min(1, value / 100)) } }
            }
            HStack(spacing: 6) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                    Button { session.setFill(color.color) } label: { Circle().fill(color.color).frame(width: 21, height: 21).overlay(Circle().stroke(.primary.opacity(0.15), lineWidth: 1)) }
                        .buttonStyle(.plain).help("Fill \(color.hex)")
                }
            }
        }.toggleStyle(.checkbox).font(.system(size: 12))
    }
    private var palette: [VectorColor] { [.ink, .paper, .violet, VectorColor(red: 1, green: 0.38, blue: 0.29), VectorColor(red: 1, green: 0.75, blue: 0.2), VectorColor(red: 0.2, green: 0.72, blue: 0.55), VectorColor(red: 0.2, green: 0.6, blue: 0.96)] }
    private var alignment: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(session.selection.count == 1 ? "ALIGN TO ARTBOARD" : "ALIGN TO SELECTION")
            HStack {
                ForEach(["left", "center", "right", "top", "middle", "bottom"], id: \.self) { axis in
                    Button { session.align(axis) } label: { Image(systemName: "align.\(axis == "center" ? "horizontal.center" : axis == "middle" ? "vertical.center" : axis)").frame(maxWidth: .infinity) }.help("Align \(axis)")
                }
            }.buttonStyle(.borderless)
        }
    }
    private func textProperties(_ shape: VectorShape) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("TYPE")
            TextField("Text", text: Binding(get: { session.selectedShape?.text ?? "" }, set: { value in session.modifySelection("Edit Text") { $0.text = value } }), axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).help("Edit the wording of the text object")
            NumericField(label: "Size", value: shape.fontSize) { value in session.modifySelection("Font Size") { $0.fontSize = max(1, min(2000, value)) } }
        }
    }
    private func toggle(_ id: UUID, key: String) {
        session.edit(key == "locked" ? "Toggle Lock" : "Toggle Visibility") { p in
            guard let i = p.shapes.firstIndex(where: { $0.id == id }) else { return }
            if key == "locked" { p.shapes[i].locked.toggle() } else { p.shapes[i].visible.toggle() }
        }
        if let s = document.project.shapes.first(where: { $0.id == id }), s.locked || !s.visible { session.selection.remove(id) }
    }
}

struct NumericField: View {
    let label: String
    let value: Double
    let commit: (Double) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).font(.system(size: 11))
            TextField(label, text: $draft).multilineTextAlignment(.trailing).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .help("Set \(label). Press Return to apply.").focused($focused).onSubmit { apply(); focused = false }
                .onChange(of: focused) { _, active in if !active { apply() } }
        }.padding(.horizontal, 9).padding(.vertical, 7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .onAppear { sync() }.onChange(of: value) { _, _ in if !focused { sync() } }
    }
    private func sync() { draft = String(format: "%.1f", value) }
    private func apply() { if let next = Double(draft), next.isFinite, abs(next - value) > 0.0001 { commit(next) }; sync() }
}
