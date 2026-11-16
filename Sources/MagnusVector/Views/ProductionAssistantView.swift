import SwiftUI

struct ProductionAssistantView: View {
    @Binding var spec: ProductionSpec
    @ObservedObject private var settings = ProviderSettings.shared
    @StateObject private var assistant = ProductionSpecAssistant()
    @State private var instructions = ""
    @State private var provider: ProductionAIProvider = .codex
    @State private var model = ""
    @State private var proposal: ProductionSpecProposal?
    @State private var proposedSpec: ProductionSpec?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        GroupBox("Use your AI provider · optional") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste printer specifications or describe the change. AI proposes settings; review them before applying. Only these instructions and job settings go to the selected provider.").font(.caption).foregroundStyle(.secondary)
                TextField("Printer specifications / instructions", text: $instructions, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
                    .help("Include dimensions, units, bleed, safe margins and the source document; do not include API keys")
                Picker("Provider", selection: $provider) { ForEach(ProductionAIProvider.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: provider) { _, next in
                        UserDefaults.standard.set(next.rawValue, forKey: "production.aiProvider")
                        model = UserDefaults.standard.string(forKey: "production.aiTextModel.\(next.rawValue)") ?? ""
                    }
                TextField("Text model ID · required for API providers", text: $model).textFieldStyle(.roundedBorder)
                    .help("Choose a text-capable model. The image-generation model is not reused.")
                    .onChange(of: model) { _, next in UserDefaults.standard.set(next, forKey: "production.aiTextModel.\(provider.rawValue)") }
                Text("Uses the connection and Keychain key saved in Magdobe Settings → AI Providers. CLI providers use their existing sign-in.").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button(assistant.busy ? "Preparing proposal…" : "Propose Setup") { propose() }
                        .disabled(assistant.busy || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? spec.validated()) == nil)
                        .help("Ask the selected provider for a proposed setup; nothing is applied automatically")
                    if assistant.busy { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel(); assistant.cancel() } }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let proposal, let proposedSpec {
                    Divider()
                    Text("Review proposed changes").font(.headline)
                    Text(proposal.explanation).font(.caption).textSelection(.enabled)
                    ForEach(changes(from: spec, to: proposedSpec), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    ForEach(proposal.unknowns, id: \.self) { Text("Unconfirmed: \($0)").font(.caption).foregroundStyle(.orange) }
                    ForEach(proposal.evidence, id: \.self) { Text("Source: \($0)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Artwork placement is uniform; fill-through-bleed may crop this delivery copy. AI cannot confirm supplier approval, convert colors or certify print readiness.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Keep Current") { self.proposal = nil; self.proposedSpec = nil }.help("Discard this proposal")
                        Button("Use Proposed Setup") { spec = proposedSpec; spec.supplierConfirmed = false; self.proposal = nil; self.proposedSpec = nil }
                            .help("Apply these settings to the draft; Save Setup persists them in your project")
                    }
                }
            }.padding(8)
        }.onAppear {
            provider = ProductionAIProvider(rawValue: UserDefaults.standard.string(forKey: "production.aiProvider") ?? settings.imageProvider.rawValue) ?? .codex
            model = UserDefaults.standard.string(forKey: "production.aiTextModel.\(provider.rawValue)") ?? ""
        }.onDisappear { task?.cancel(); assistant.cancel() }
    }
    private func propose() {
        error = nil; proposal = nil; proposedSpec = nil
        let before = spec, selected = provider, textModel = model, brief = instructions
        task = Task {
            do {
                let result = try await assistant.propose(instructions: brief, currentJob: before.jobData(), provider: selected, model: textModel, settings: settings)
                try Task.checkCancellation()
                var next = try JSONDecoder().decode(ProductionSpec.self, from: result.proposedJob).validated()
                next.supplierConfirmed = false
                proposedSpec = next; proposal = result
            } catch is CancellationError { error = "Proposal cancelled. Current settings were kept." }
            catch { self.error = error.localizedDescription }
            task = nil
        }
    }
    private func changes(from old: ProductionSpec, to new: ProductionSpec) -> [String] {
        guard let a = try? JSONSerialization.jsonObject(with: old.jobData()) as? [String: Any],
              let b = try? JSONSerialization.jsonObject(with: new.jobData()) as? [String: Any] else { return [] }
        func string(_ value: Any?) -> String {
            guard let value else { return "Unspecified" }
            if let array = value as? [String] { return array.joined(separator: ", ") }
            return String(describing: value)
        }
        return Set(a.keys).union(b.keys).sorted().compactMap { key in
            let before = string(a[key]), after = string(b[key])
            return before == after ? nil : "\(key.replacingOccurrences(of: "_", with: " ")): \(before) → \(after)"
        }
    }
}
