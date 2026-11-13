import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject private var settings = ProviderSettings.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("AI Providers", systemImage: "sparkles").font(.title2.bold())
                Text("Connect your own accounts. Choose who draws your images and, optionally, who helps refine your prompts.")
                    .foregroundStyle(.secondary)
                GroupBox("Image generation") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Provider", selection: $settings.imageProvider) {
                            ForEach(ImageProviderID.allCases) { Text($0.title).tag($0) }
                        }.help("Choose the service that generates the source image")
                        Text(settings.imageProvider.help).font(.callout).foregroundStyle(.secondary)
                        ProviderConnectionEditor(id: settings.imageProvider.rawValue, settings: settings)
                            .id(settings.imageProvider)
                    }.padding(10)
                }
                GroupBox("Prompt assistant · optional") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Assistant", selection: $settings.assistant) {
                            ForEach(PromptAssistantID.allCases) { Text($0.title).tag($0) }
                        }.help("Claude can refine your brief before the selected image provider draws it")
                        Text(settings.assistant.help).font(.callout).foregroundStyle(.secondary)
                        if settings.assistant != .none {
                            Text("Claude refines prompts. Your image provider generates the illustration.")
                                .font(.caption).foregroundStyle(.secondary)
                            ProviderConnectionEditor(id: settings.assistant.rawValue, settings: settings)
                                .id(settings.assistant)
                        }
                    }.padding(10)
                }
                Text("API keys stay in macOS Keychain. API usage is charged by your chosen provider. A ChatGPT or Claude subscription does not automatically include API credits. Local vector conversion and editing work without an AI provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .frame(width: 610, height: 680)
        .background(PaperTexture.surface).preferredColorScheme(.light).tint(PaperTexture.accent)
    }
}

private struct ProviderConnectionEditor: View {
    let id: String
    @ObservedObject var settings: ProviderSettings
    @State private var model = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var status = ""
    @State private var isError = false
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?
    private var usesKey: Bool { id != "codex" && id != "claudeCLI" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usesKey {
                TextField("Model", text: $model).textFieldStyle(.roundedBorder)
                    .help("Enter an image-capable model ID; for Claude, choose a text model")
                TextField("API base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                    .help("HTTPS API root, including its version path. Local services can use HTTP on localhost.")
                SecureField(settings.hasKey(for: id) ? "Replace saved API key (optional)" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder).help("Stored only in Keychain for this provider and endpoint")
                HStack {
                    Label(settings.hasKey(for: id) ? "Key stored for the saved endpoint" : (id == "compatible" ? "API key optional for local services" : "No API key saved"), systemImage: settings.hasKey(for: id) ? "lock.fill" : "key")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if settings.hasKey(for: id) {
                        Button("Remove Key") {
                            do { try settings.removeAPIKey(for: id); status = "Key removed."; isError = false }
                            catch { status = error.localizedDescription; isError = true }
                        }.help("Remove this connection’s saved API key")
                    }
                }
            } else if id == "claudeCLI" {
                Text("Install Claude Code and sign in with claude auth login. Magdobe uses that existing sign-in; it does not copy your login credentials.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Install Codex and sign in with your ChatGPT account. Magdobe uses the existing sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if usesKey {
                    Button("Save Connection") { save() }.help("Save the model, endpoint, and any newly entered key")
                }
                Button(checking ? "Checking…" : "Check Connection") { check() }
                    .help("Check authentication without requesting an image or spending image-generation credits")
                if checking { ProgressView().controlSize(.small) }
            }.disabled(checking)
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(isError ? .red : .secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { let profile = settings.profile(for: id); model = profile.model; baseURL = profile.baseURL }
        .onDisappear { checkTask?.cancel(); key = "" }
    }
    @discardableResult private func save() -> Bool {
        do {
            try settings.updateProfile(ProviderProfile(model: model.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), for: id)
            if !key.isEmpty { try settings.saveAPIKey(key, for: id); key = "" }
            status = "Connection saved."; isError = false; return true
        } catch { status = error.localizedDescription; isError = true; return false }
    }
    private func check() {
        guard !usesKey || save() else { return }
        checking = true; status = ""; isError = false
        checkTask = Task { @MainActor in
            defer { checking = false }
            do {
                let profile = settings.profile(for: id)
                let connection = ProviderConnection(id: id, model: profile.model, baseURL: profile.baseURL, apiKey: try settings.apiKey(for: id))
                try await ArtworkWorker().run(mode: "check", connection: connection) { _ in }
                guard !Task.isCancelled else { return }
                status = id == "codex" || id == "claudeCLI" ? "Existing sign-in connected." : "Provider responded successfully. Model access is checked when used."
            } catch { if !Task.isCancelled { status = error.localizedDescription; isError = true } }
        }
    }
}
