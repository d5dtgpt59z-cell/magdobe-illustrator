import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProductionPDFSettingsView: View {
    @Binding var settings: ProductionPDFSettings?
    @Binding var profileData: Data?
    @Binding var importing: Bool
    @State private var error: String?
    @State private var panel: NSOpenPanel?
    private var enabled: Binding<Bool> { Binding(get: { settings != nil }, set: { settings = $0 ? ProductionPDFSettings() : nil; if !$0 { profileData = nil } }) }
    private func field<T>(_ key: WritableKeyPath<ProductionPDFSettings, T>, fallback: T) -> Binding<T> {
        Binding(get: { settings?[keyPath: key] ?? fallback }, set: { value in
            var next = settings ?? ProductionPDFSettings(); next[keyPath: key] = value; settings = next
        })
    }
    var body: some View {
        GroupBox("Production PDF") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Configure production PDF", isOn: enabled).toggleStyle(.checkbox)
                    .help("Prepare a separate PDF using your printer's ICC profile; existing SVG and ordinary PDF export stay available")
                if let settings {
                    Picker("Target", selection: field(\.target, fallback: .cmykPDF)) {
                        Text("CMYK PDF").tag(ProductionPDFSettings.Target.cmykPDF)
                        Text("PDF/X-4 · supported checks").tag(ProductionPDFSettings.Target.pdfx4)
                    }.help("The bundled finalizer converts RGB once and validates the generated vector PDF; this is not independent full ISO certification")
                    if let descriptor = settings.iccProfile {
                        Text(descriptor.name).font(.callout.bold()).textSelection(.enabled)
                        Text("SHA-256: \(descriptor.sha256)").font(.caption2.monospaced()).textSelection(.enabled)
                        if profileData == nil { Text("Profile bytes are missing. Import the matching printer ICC before exporting.").font(.caption).foregroundStyle(.red) }
                    } else { Text("Import the CMYK output profile supplied by your printer. No generic profile is chosen.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(importing ? "Importing…" : "Import Printer ICC…") { chooseProfile() }.disabled(importing)
                            .help("Select a CMYK printer/output ICC v2 or v4 file, up to 16 MiB; the active profile travels with the saved project")
                        if importing { ProgressView().controlSize(.small) }
                    }
                    TextField("Output condition identifier", text: field(\.outputConditionIdentifier, fallback: "")).textFieldStyle(.roundedBorder)
                        .help("Enter the printer's production condition identifier, such as the identifier in its specification")
                    if settings.iccProfile != nil, settings.outputConditionIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter an output condition identifier to enable Production PDF export.").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Output condition description", text: field(\.outputCondition, fallback: "")).textFieldStyle(.roundedBorder)
                        .help("Describe the intended press and stock condition; this is stored in the PDF output intent")
                    TextField("Registry URL · optional", text: field(\.registryName, fallback: "")).textFieldStyle(.roundedBorder)
                        .help("An optional registry reference; this field is metadata and is never fetched")
                    Picker("Rendering intent", selection: field(\.renderingIntent, fallback: .relativeColorimetric)) {
                        ForEach(ProductionPDFSettings.Intent.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.help("Use the rendering intent requested by your supplier")
                    Toggle("Black point compensation", isOn: field(\.blackPointCompensation, fallback: false)).toggleStyle(.checkbox)
                        .help("Pass the selected black point compensation setting to the ICC conversion engine")
                    Text("Black generation: printer ICC. Text: vector outlines. Technical, reference and finish roles are omitted; unassigned objects, Artwork and Barcode roles are included.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("A successful report covers the supported generated-vector checks. Color proofing, ink limits and supplier manufacturing approval remain separate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(8)
        }.onDisappear { panel?.cancel(nil) }
    }
    private func chooseProfile() {
        guard !importing else { return }
        let picker = NSOpenPanel(); picker.title = "Import Printer ICC Profile"
        let types = [UTType(filenameExtension: "icc"), UTType(filenameExtension: "icm")].compactMap { $0 }
        picker.allowedContentTypes = types.isEmpty ? [.data] : types
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false; picker.prompt = "Import"
        panel = picker; importing = true; error = nil
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { response in
            Task { @MainActor in
                panel = nil
                guard response == .OK, let url = picker.url else { importing = false; return }
                do {
                    let imported = try await Task.detached(priority: .userInitiated) { try ProductionICCProfile.read(url) }.value
                    try ProductionICCLibrary().save(imported.0, descriptor: imported.1)
                    var next = settings ?? ProductionPDFSettings(); next.iccProfile = imported.1
                    profileData = imported.0; settings = next
                } catch { self.error = error.localizedDescription }
                importing = false
            }
        }
    }
}
