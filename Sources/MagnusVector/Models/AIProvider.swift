import Foundation

enum ImageProviderID: String, Codable, CaseIterable, Identifiable {
    case codex, openai, gemini, openrouter, compatible
    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        case .compatible: "OpenAI-compatible"
        }
    }
    var defaultModel: String {
        switch self {
        case .codex, .compatible: ""
        case .openai: "gpt-image-2.5-flare"
        case .gemini: "gemini-nano-banana-2.1"
        case .openrouter: "google/gemini-2.5-flash-image"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .codex, .compatible: ""
        case .openai: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openrouter: "https://openrouter.ai/api/v1"
        }
    }
    var help: String {
        switch self {
        case .codex: "Uses your existing Codex ChatGPT sign-in. No API key is required."
        case .openai: "Generate images with your OpenAI API account and API key. API usage is billed by OpenAI."
        case .gemini: "Generate images with Google's Gemini API and your Google API key."
        case .openrouter: "Choose an image-capable model through OpenRouter using your OpenRouter API key."
        case .compatible: "Connect an image-generation API that supports the OpenAI-compatible image format. Enter its base URL and model."
        }
    }
}

enum PromptAssistantID: String, Codable, CaseIterable, Identifiable {
    case none, anthropic, claudeCLI
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "No prompt assistant"
        case .anthropic: "Claude API"
        case .claudeCLI: "Claude Code"
        }
    }
    var help: String {
        switch self {
        case .none: "Send your prompt directly to the selected image provider."
        case .anthropic: "Use Claude to refine your prompt before image generation. Requires an Anthropic API key."
        case .claudeCLI: "Use the installed Claude Code CLI and its existing sign-in to refine your prompt."
        }
    }
}

struct ProviderProfile: Codable, Equatable {
    var model: String
    var baseURL: String

    static func initial(for id: String) -> Self {
        if let provider = ImageProviderID(rawValue: id) {
            return Self(model: provider.defaultModel, baseURL: provider.defaultBaseURL)
        }
        if id == PromptAssistantID.anthropic.rawValue {
            // Current Claude API model ID; users can select another supported model.
            return Self(model: "claude-sonnet-5-5", baseURL: "https://api.anthropic.com/v1")
        }
        return Self(model: "", baseURL: "")
    }
}
