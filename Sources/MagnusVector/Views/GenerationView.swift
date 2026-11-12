import SwiftUI

struct GenerationView: View {
    @ObservedObject var session: EditorSession
    @StateObject private var generation = GenerationStore()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Draw with Codex", systemImage: "sparkles").font(.title2.bold())
                    Text("Your idea → an image → editable artwork").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(generation.busy).help("Return to the canvas")
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What would you like to draw?").font(.headline)
                    TextEditor(text: $generation.prompt).font(.body).scrollContentBackground(.hidden)
                        .padding(8).frame(height: 128).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.brown.opacity(0.18)))
                        .help("Describe the subject, pose, colors, style, and any exact text you want")
                    HStack {
                        picker("Style", selection: $generation.style, values: ["Illustration", "Clean vector", "Painted detail"], help: "Choose the visual style for Codex to draw")
                        picker("Format", selection: $generation.format, values: ["Square", "Portrait", "Landscape"], help: "Choose the composition of the generated image")
                    }
                    picker("Vector detail", selection: $generation.detail, values: ["Simple", "Balanced", "Detailed"], help: "Higher detail preserves more shading and creates more editable paths")
                    Text("Detailed shading becomes colored shapes. Fine texture is simplified; text becomes outlines.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { generation.chooseReference() } label: { Label(generation.reference == nil ? "Add Reference…" : "Change Reference…", systemImage: "photo") }.help("Choose an image for Codex to use as a visual reference")
                        if generation.reference != nil {
                            Button { generation.reference = nil } label: { Image(systemName: "xmark.circle") }.help("Remove the visual reference")
                        }
                    }
                    if let reference = generation.reference { Text(reference.lastPathComponent).font(.caption).lineLimit(1).foregroundStyle(.secondary).help(reference.path) }
                    Divider()
                    HStack(alignment: .top) {
                        Image(systemName: generation.connected ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(generation.connected ? .green : .secondary)
                        Text(generation.connection).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Check Connection") { Task { await generation.checkConnection() } }.font(.caption).help("Check your existing Codex ChatGPT sign-in")
                    Text("Uses your signed-in Codex account and its image limits. Vector conversion runs on this Mac.").font(.caption).foregroundStyle(.secondary)
                    Button { generation.start() } label: { Label("Generate Editable Artwork", systemImage: "sparkles").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!generation.connected || generation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || generation.busy)
                        .help("Ask Codex to draw one image, then turn it into editable vector shapes")
                    Button("Vectorize an Existing Image…") { generation.chooseImage() }.disabled(generation.busy).help("Convert a PNG, JPEG, or WebP locally without calling Codex")
                }.frame(width: 350).disabled(generation.busy)
                VStack(spacing: 12) {
                    if generation.project != nil {
                        Picker("Preview", selection: $generation.showVectors) { Text("Editable vectors").tag(true); Text("Source image").tag(false) }
                            .pickerStyle(.segmented).help("Compare the vector result with the original generated image")
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.65))
                        if let image = generation.showVectors ? generation.vectorPreview : generation.sourcePreview {
                            Image(nsImage: image).resizable().scaledToFit().padding(12)
                        } else {
                            VStack(spacing: 14) {
                                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.brown.opacity(0.6))
                                Text("Start with an idea").font(.title3)
                                Text("Preview your drawing here, then add its editable shapes to your canvas.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 260)
                            }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 330, maxHeight: .infinity)
                    if generation.busy { ProgressView().controlSize(.small) }
                    if !generation.stage.isEmpty { Text(generation.stage).font(.caption).foregroundStyle(.secondary) }
                    if let error = generation.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    HStack {
                        if generation.busy { Button("Cancel") { generation.cancel() }.help("Stop this request and keep your current document") }
                        if generation.project != nil {
                            Button("Show Files") { generation.revealFiles() }.help("Open the folder containing the source image, prompt, SVG, and project")
                            Spacer()
                            Button("Add to Canvas") {
                                if let project = generation.project { session.insertArtwork(project) }; dismiss()
                            }.buttonStyle(.borderedProminent).help("Insert the generated vectors as a single undoable action")
                        }
                    }
                }.frame(minWidth: 350)
            }.padding(24)
        }
        .frame(width: 850, height: 720)
        .background(PaperTexture.surface)
        .preferredColorScheme(.light)
        .tint(PaperTexture.accent)
        .interactiveDismissDisabled(generation.busy)
        .task { await generation.checkConnection() }
        .onDisappear { generation.cancel() }
    }
    private func picker(_ label: String, selection: Binding<String>, values: [String], help: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Picker(label, selection: selection) { ForEach(values, id: \.self) { Text($0).tag($0) } }.labelsHidden().help(help)
        }
    }
}
