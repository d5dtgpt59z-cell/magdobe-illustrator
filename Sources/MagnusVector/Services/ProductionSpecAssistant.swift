import Foundation
import Combine

enum ProductionAIProvider: String, CaseIterable, Identifiable {
    case codex, openai, gemini, anthropic, claudeCLI, openrouter, compatible
    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex account"
        case .openai: "OpenAI API"
        case .gemini: "Google Gemini API"
        case .anthropic: "Claude API"
        case .claudeCLI: "Claude Code account"
        case .openrouter: "OpenRouter API"
        case .compatible: "OpenAI-compatible API"
        }
    }
    var requiresModel: Bool { self != .codex && self != .claudeCLI }
}

/// A proposal may only be applied to the exact setup and brief it was requested for.
struct ProductionProposalContext: Equatable {
    var spec: ProductionSpec
    var instructions: String
    var provider: ProductionAIProvider
    var model: String

    func accepts(_ proposal: ProductionSpec, current: ProductionProposalContext) -> Bool {
        self == current && proposal.pdf?.iccProfile == spec.pdf?.iccProfile
    }
}

struct ProductionSpecProposal {
    let proposedJob: Data
    let unknowns: [String]
    let explanation: String
    let evidence: [String]

    init(data: Data) throws {
        guard data.count <= 200_000,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = value["proposed_job"] as? [String: Any],
              let unknowns = value["unknowns"] as? [String],
              let explanation = value["explanation"] as? String,
              let evidence = value["evidence"] as? [String] else {
            throw ArtworkError.message("The production assistant returned an invalid proposal. Your settings were kept.")
        }
        proposedJob = try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
        self.unknowns = unknowns; self.explanation = explanation; self.evidence = evidence
    }
}

@MainActor
final class ProductionSpecAssistant: ObservableObject {
    @Published private(set) var busy = false
    private var worker: ArtworkWorker?

    func propose(instructions: String, currentJob: Data, provider: ProductionAIProvider,
                 model: String, settings: ProviderSettings) async throws -> ProductionSpecProposal {
        guard !busy else { throw ArtworkError.message("A production proposal is already running.") }
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty, instructions.count <= 32_000,
              currentJob.count <= 16_000,
              let current = try JSONSerialization.jsonObject(with: currentJob) as? [String: Any] else {
            throw ArtworkError.message("Enter printer specifications of no more than 32,000 characters and valid current job settings.")
        }
        let textModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.requiresModel || !textModel.isEmpty else {
            throw ArtworkError.message("Enter a text-capable model for this provider. The artwork model is kept separate.")
        }
        guard textModel.utf8.count <= 256, textModel.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ArtworkError.message("Enter a valid text model ID.")
        }
        let profile = settings.profile(for: provider.rawValue)
        let key = provider.requiresModel ? try settings.apiKey(for: provider.rawValue) : nil
        if provider.requiresModel && provider != .compatible && key?.isEmpty != false {
            throw ArtworkError.message("Save your \(provider.title) key in AI Providers settings first.")
        }
        let connection = ProviderConnection(id: provider.rawValue, model: textModel,
                                            baseURL: profile.baseURL, apiKey: key)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Magdobe Illustrator/Production Proposals/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["instructions": instructions, "current_job": current])
            .write(to: directory.appendingPathComponent("request.json"), options: .atomic)
        let worker = ArtworkWorker(); self.worker = worker; busy = true
        defer { self.worker = nil; busy = false }
        try await worker.run(mode: "print-spec", job: directory, connection: connection) { _ in }
        try Task.checkCancellation()
        return try ProductionSpecProposal(data: Data(contentsOf: directory.appendingPathComponent("production-proposal.json")))
    }

    func cancel() { worker?.cancel() }
}
