import SwiftUI

struct ArtworkSaveView: View {
    let project: VectorProject
    var includesProject = true
    @StateObject private var saver: ArtworkSaveStore
    @Environment(\.dismiss) private var dismiss

    init(project: VectorProject, initialFormat: ArtworkFileFormat, includesProject: Bool = true) {
        self.project = project; self.includesProject = includesProject
        _saver = StateObject(wrappedValue: ArtworkSaveStore(format: initialFormat))
    }
    private var formats: [ArtworkFileFormat] { includesProject ? ArtworkFileFormat.allCases : [.svg, .pdf, .png] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(saver.format == .project ? "Save Editable Project" : "Export Artwork", systemImage: saver.format == .project ? "square.and.arrow.down" : "square.and.arrow.up")
                    .font(.title2.bold())
                Spacer()
                Text("\(project.shapes.count.formatted()) objects").foregroundStyle(.secondary)
            }
            Picker("File format", selection: $saver.format) {
                ForEach(formats) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(saver.busy || saver.choosingDestination)
                .help(includesProject ? "Choose an editable Magdobe project or a format for sharing and viewing" : "Choose SVG, PDF, or PNG for sharing and viewing")
            Text(saver.format.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if saver.format == .svg {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Preserve editable layers", isOn: $saver.options.preserveEditableLayers)
                        .help("Keep named SVG groups in their original order, including hidden objects")
                    Toggle("Convert text to outlines", isOn: $saver.options.convertTextToOutlines)
                        .help("Replace text with vector glyph contours to preserve its appearance without requiring the font")
                    Toggle("Optimize SVG", isOn: $saver.options.optimize)
                        .help("Remove formatting whitespace only; keep every object and the full precision of every curve")
                    Toggle("Export entire artboard", isOn: $saver.options.entireArtboard)
                        .help("Keep the artboard dimensions and clipping. Turn off to fit the visible drawing")
                }.toggleStyle(.checkbox).disabled(saver.busy || saver.choosingDestination)
                Text("Layers become named groups. Editable text may use a substitute font in another app; outlines preserve the glyph shapes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label(saver.format == .png ? "\(Int(ceil(project.width))) × \(Int(ceil(project.height))) pixels · transparency supported" : "\(Int(project.width)) × \(Int(project.height)) artboard", systemImage: "rectangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if saver.busy {
                if saver.format == .svg {
                    ProgressView(value: Double(saver.completed), total: Double(max(1, saver.total)))
                    Text("Exporting \(saver.completed.formatted()) of \(saver.total.formatted()) objects…").font(.caption)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Saving \(saver.format.title)…").font(.caption) }
                }
            }
            if let error = saver.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let url = saver.savedURL {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(2)
                HStack {
                    Button(saver.format.viewerTitle) { saver.openSavedFile() }.help("Open the file you just saved")
                    Button("Show in Finder") { saver.revealSavedFile() }.help("Reveal the saved file on your Mac")
                }
            }
            Divider()
            HStack {
                Spacer()
                if saver.busy {
                    Button("Cancel Save") { saver.cancel() }.help("Cancel before writing, keeping your artwork and any existing file")
                } else {
                    Button(saver.savedURL == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).help("Return to your artwork")
                    Button(saver.format == .project ? "Save Project…" : "Export \(saver.format.title)…") { saver.chooseDestination(project: project) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).help("Choose a name and location on your Mac")
                }
            }.disabled(saver.choosingDestination)
        }
        .padding(24).frame(width: 500)
        .background(PaperTexture.surface).preferredColorScheme(.light).tint(PaperTexture.accent)
        .interactiveDismissDisabled(saver.busy || saver.choosingDestination)
        .onChange(of: saver.format) { _, _ in saver.clearReceipt() }
        .onDisappear { saver.cancel() }
    }
}
