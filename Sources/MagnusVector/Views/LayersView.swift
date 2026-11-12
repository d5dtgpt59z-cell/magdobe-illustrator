import SwiftUI
import UniformTypeIdentifiers

/// Existing inspector chrome with a native outline for selection and drag/drop.
struct LayersView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var document: VectorDocument
    var body: some View {
        let index = document.hierarchyIndex
        VStack(spacing: 0) {
            HStack {
                Text("LAYERS").font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                Text("\(document.project.shapes.count)").font(.caption).foregroundStyle(.secondary)
                Button { session.newLayer() } label: { Image(systemName: "plus.rectangle.on.folder") }
                    .buttonStyle(.borderless).help("Create a new layer (⇧⌘N)").accessibilityLabel("New Layer")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            if index.nodes.isEmpty {
                ContentUnavailableView("No objects yet", systemImage: "square.3.layers.3d").frame(height: 190)
            } else {
                NativeLayerOutline(session: session, document: document)
                    .frame(minHeight: 170, idealHeight: 250, maxHeight: 290)
            }
            Divider()
            HStack {
                Button { session.groupSelection() } label: { Image(systemName: "square.3.layers.3d") }
                    .disabled(!session.canGroup).help("Group selected siblings (⌘G)").accessibilityLabel("Group")
                Button { session.ungroupSelection() } label: { Image(systemName: "square.3.layers.3d.slash") }
                    .disabled(!session.canUngroup).help("Ungroup (⌥⌘G)").accessibilityLabel("Ungroup")
                Button { session.duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate (⌘D)")
                Button { session.reorder(true) } label: { Image(systemName: "square.3.layers.3d.top.filled") }.help("Bring to front within parent")
                Button { session.reorder(false) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }.help("Send to back within parent")
                Spacer(minLength: 0)
                Button { session.deleteSelection() } label: { Image(systemName: "trash") }.help("Delete selection")
            }.buttonStyle(.borderless).disabled(session.selection.isEmpty).padding(14)
        }
    }
}
