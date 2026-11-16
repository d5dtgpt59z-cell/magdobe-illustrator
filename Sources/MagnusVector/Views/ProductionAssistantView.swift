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
    @State private var reviewContext: ProductionProposalContext?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private var currentContext: ProductionProposalContext {
        ProductionProposalContext(spec: spec, instructions: instructions, provider: provider, model: model)
    }
    private var proposalIsCurrent: Bool {
        guard let reviewContext, let proposedSpec else { return false }
        return reviewContext.accepts(proposedSpec, current: currentContext)
    }
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
                    ForEach(changes(from: reviewContext?.spec ?? spec, to: proposedSpec), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    ForEach(proposal.unknowns, id: \.self) { Text("Unconfirmed: \($0)").font(.caption).foregroundStyle(.orange) }
                    ForEach(proposal.evidence, id: \.self) { Text("Source: \($0)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Artwork placement is uniform; fill-through-bleed may crop this delivery copy. Import the actual printer ICC profile yourself. The export engine performs color conversion and PDF checks; AI cannot confirm supplier approval.").font(.caption).foregroundStyle(.secondary)
                    if !proposalIsCurrent { Text("The current setup, provider or instructions changed. Request a new proposal before applying changes.").font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("Keep Current") { self.proposal = nil; self.proposedSpec = nil; reviewContext = nil }.help("Discard this proposal")
                        Button("Use Proposed Setup") {
                            guard proposalIsCurrent else { return }
                            spec = proposedSpec; spec.supplierConfirmed = false; self.proposal = nil; self.proposedSpec = nil; reviewContext = nil
                        }.disabled(!proposalIsCurrent)
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
        error = nil; proposal = nil; proposedSpec = nil; reviewContext = nil
        let context = currentContext
        task = Task {
            do {
                let result = try await assistant.propose(instructions: context.instructions, currentJob: context.spec.jobData(), provider: context.provider, model: context.model, settings: settings)
                try Task.checkCancellation()
                var next = try JSONDecoder().decode(ProductionSpec.self, from: result.proposedJob).validated()
                next.supplierConfirmed = false
                guard context.accepts(next, current: currentContext) else {
                    error = "The setup or instructions changed while the proposal was being prepared, or its ICC identity differed. Current settings were kept. Request a new proposal."
                    task = nil; return
                }
                reviewContext = context; proposedSpec = next; proposal = result
            } catch is CancellationError { error = "Proposal cancelled. Current settings were kept." }
            catch { self.error = error.localizedDescription }
            task = nil
        }
    }
    private func changes(from old: ProductionSpec, to new: ProductionSpec) -> [String] {
        guard let a = try? JSONSerialization.jsonObject(with: old.jobData()) as? [String: Any],
              let b = try? JSONSerialization.jsonObject(with: new.jobData()) as? [String: Any] else { return [] }
        func flattened(_ object: [String: Any], prefix: String = "") -> [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in object {
                let path = prefix.isEmpty ? key : prefix + "." + key
                if let nested = value as? [String: Any] { result.merge(flattened(nested, prefix: path)) { _, next in next } }
                else { result[path] = value }
            }
            return result
        }
        let beforeFields = flattened(a), afterFields = flattened(b)
        func string(_ value: Any?) -> String {
            guard let value else { return "Unspecified" }
            if let array = value as? [String] { return array.joined(separator: ", ") }
            return String(describing: value)
        }
        return Set(beforeFields.keys).union(afterFields.keys).sorted().compactMap { key in
            let before = string(beforeFields[key]), after = string(afterFields[key])
            return before == after ? nil : "\(key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " · ")): \(before) → \(after)"
        }
    }
}
