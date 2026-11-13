import Foundation

/// A per-operation snapshot. The key is kept in memory and passed only to the selected worker.
struct ProviderConnection: Sendable {
    let id: String
    let model: String
    let baseURL: String
    let apiKey: String?

    @MainActor static func image(_ settings: ProviderSettings) throws -> Self {
        try connection(id: settings.imageProvider.rawValue, settings: settings)
    }
    @MainActor static func assistant(_ settings: ProviderSettings) throws -> Self {
        guard settings.assistant != .none else { throw ArtworkError.message("Choose a prompt assistant in AI Providers settings first.") }
        return try connection(id: settings.assistant.rawValue, settings: settings)
    }
    @MainActor private static func connection(id: String, settings: ProviderSettings) throws -> Self {
        let profile = settings.profile(for: id)
        if id == "codex" || id == "claudeCLI" {
            return Self(id: id, model: profile.model, baseURL: "", apiKey: nil)
        }
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArtworkError.message("Enter a model in AI Providers settings.")
        }
        guard let url = URL(string: profile.baseURL), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw ArtworkError.message("Use an HTTPS provider base URL, or HTTP on localhost for a local service.")
        }
        let key = try settings.apiKey(for: id)
        if id != "compatible", key?.isEmpty != false {
            throw ArtworkError.message("Save an API key for this provider in AI Providers settings.")
        }
        return Self(id: id, model: profile.model.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: profile.baseURL, apiKey: key)
    }
    var workerConfiguration: [String: String] { ["provider": id, "model": model, "baseURL": baseURL] }
}
