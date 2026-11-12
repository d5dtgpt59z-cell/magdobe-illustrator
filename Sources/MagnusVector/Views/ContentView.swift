import SwiftUI

struct ContentView: View {
    @ObservedObject var document: VectorDocument
    @StateObject private var session: EditorSession
    init(document: VectorDocument) {
        self.document = document
        _session = StateObject(wrappedValue: EditorSession(document: document))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label(session.tool.title, systemImage: session.tool.symbol).fontWeight(.medium)
                Divider().frame(height: 16)
                Text(session.tool.hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).frame(height: 38)
            Divider()
            HStack(spacing: 0) {
                ToolRail(session: session)
                Divider()
                VectorCanvas(session: session, document: document)
                    .accessibilityLabel("Vector artboard")
                Divider()
                InspectorView(session: session, document: document).frame(width: 272)
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.tint)
                Text("MAGDOBE ILLUSTRATOR").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                Text("\(document.project.shapes.count) objects").foregroundStyle(.secondary)
                Spacer()
                if !session.selection.isEmpty { Text("\(session.selection.count) selected").foregroundStyle(.secondary) }
                Button { session.zoom = max(0.02, session.zoom / 1.25) } label: { Image(systemName: "minus") }.buttonStyle(.borderless).help("Zoom out")
                Text("\(Int(session.zoom * 100))% ").monospacedDigit().frame(width: 48)
                Button { session.zoom = min(32, session.zoom * 1.25) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Zoom in")
                Button("Fit") { session.fit() }.buttonStyle(.borderless).help("Fit the whole artboard in the window (⌘0)")
            }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 30)
        }
        .frame(minWidth: 1050, minHeight: 680)
        .focusedSceneObject(session)
        .background(PaperTexture.surface)
        .preferredColorScheme(.light)
        .tint(PaperTexture.accent)
        .sheet(isPresented: $session.showGeneration) { GenerationView(session: session) }
        .sheet(isPresented: $session.showSVGExport) { SVGExportView(session: session) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Label("Magdobe Illustrator", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            }
            ToolbarItemGroup {
                Button { session.showGeneration = true } label: { Label("Draw with Codex", systemImage: "sparkles") }.help("Describe artwork and generate editable vectors with Codex (⇧⌘G)")
                Divider()
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!session.canUndo).help("Undo (⌘Z)")
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!session.canRedo).help("Redo (⇧⌘Z)")
                Divider()
                Toggle(isOn: $session.grid) { Image(systemName: "square.grid.3x3") }.help("Show grid")
                Button { session.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit artboard (⌘0)").accessibilityLabel("Fit Artboard")
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { format in Button("Export \(format.rawValue.uppercased())…") { session.export(format) } }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }.help("Export artwork as SVG, PDF, or PNG")
            }
        }
        .alert("Couldn’t export", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) { Button("OK") { session.error = nil } } message: { Text(session.error ?? "") }
    }
}

struct ToolRail: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        VStack(spacing: 9) {
            ForEach(EditorTool.allCases) { tool in
                Button { session.selectTool(tool) } label: {
                    Image(systemName: tool.symbol).font(.system(size: 18)).frame(width: 38, height: 36)
                        .foregroundStyle(session.tool == tool ? PaperTexture.accent : .primary)
                        .background(session.tool == tool ? PaperTexture.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).help("\(tool.title) (\(tool.key.uppercased()))").accessibilityLabel(tool.title)
            }
            Divider().padding(.horizontal, 9)
            ZStack {
                RoundedRectangle(cornerRadius: 3).stroke(session.stroke.color, lineWidth: 3).frame(width: 22, height: 22).offset(x: 5, y: 5)
                RoundedRectangle(cornerRadius: 3).fill(session.fill.color).frame(width: 23, height: 23).overlay(RoundedRectangle(cornerRadius: 3).stroke(.background, lineWidth: 2)).offset(x: -4, y: -4)
            }.frame(height: 42).help("Current fill and stroke")
            Spacer()
        }.padding(.top, 13).frame(width: 58).background(PaperTexture.surface)
    }
}
