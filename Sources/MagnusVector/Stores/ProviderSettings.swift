import Foundation
import Combine
import CryptoKit
import Security
import LocalAuthentication

/// The only boundary that reads or writes provider secrets. Tests inject an in-memory store.
protocol ProviderCredentialStore: AnyObject {
    func value(for account: String) throws -> String?
    func contains(_ account: String) throws -> Bool
    func save(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

enum ProviderSettingsError: LocalizedError {
    case invalidEndpoint, invalidModel, unsupportedProvider, invalidKey, keychain(OSStatus), invalidCredential
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTPS API base URL without a username, password, query, or fragment. HTTP is supported only for a local loopback service."
        case .invalidModel: "Enter a provider model ID of no more than 256 characters, without line breaks or control characters."
        case .unsupportedProvider: "This provider uses its existing app sign-in and does not require an API key."
        case .invalidKey: "Enter a valid API key without spaces or line breaks."
        case .invalidCredential: "The saved API key could not be read. Remove it and save it again."
        case .keychain(let status): "Keychain could not complete the action: \(SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)")"
        }
    }
}

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service = "com.builtbymagnus.magdobe.ai-provider"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func value(for account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProviderSettingsError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw ProviderSettingsError.invalidCredential }
        return value
    }
    func contains(_ account: String) throws -> Bool {
        var request = query(account)
        // Check metadata only: displaying settings must not read the key or ask to unlock it.
        request[kSecReturnAttributes as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return false }
        guard status == errSecSuccess else { throw ProviderSettingsError.keychain(status) }
        return true
    }
    func save(_ value: String, for account: String) throws {
        let data = Data(value.utf8), request = query(account)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw ProviderSettingsError.keychain(inserted) }
        } else if status != errSecSuccess { throw ProviderSettingsError.keychain(status) }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderSettingsError.keychain(status) }
    }
}

@MainActor
final class ProviderSettings: ObservableObject {
    static let shared = ProviderSettings()
    @Published var imageProvider: ImageProviderID {
        didSet { defaults.set(imageProvider.rawValue, forKey: Self.imageKey); revision &+= 1 }
    }
    @Published var assistant: PromptAssistantID {
        didSet { defaults.set(assistant.rawValue, forKey: Self.assistantKey); revision &+= 1 }
    }
    @Published private(set) var revision: UInt64 = 0
    @Published private var profiles: [String: ProviderProfile]
    private let defaults: UserDefaults
    private let credentials: ProviderCredentialStore
    private static let imageKey = "ai.imageProvider"
    private static let assistantKey = "ai.promptAssistant"
    private static let profilesKey = "ai.providerProfiles"

    init(defaults: UserDefaults = .standard, credentialStore: ProviderCredentialStore = KeychainProviderCredentialStore()) {
        self.defaults = defaults; self.credentials = credentialStore
        imageProvider = defaults.string(forKey: Self.imageKey).flatMap(ImageProviderID.init(rawValue:)) ?? .codex
        assistant = defaults.string(forKey: Self.assistantKey).flatMap(PromptAssistantID.init(rawValue:)) ?? .none
        profiles = defaults.data(forKey: Self.profilesKey).flatMap { try? JSONDecoder().decode([String: ProviderProfile].self, from: $0) } ?? [:]
    }
    func profile(for id: String) -> ProviderProfile { profiles[id] ?? .initial(for: id) }
    func updateProfile(_ profile: ProviderProfile, for id: String) throws {
        let validated: ProviderProfile
        if id == ImageProviderID.codex.rawValue || id == PromptAssistantID.claudeCLI.rawValue {
            validated = profile
        } else {
            guard usesAPIKey(id) else { throw ProviderSettingsError.unsupportedProvider }
            let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, model.count <= 256,
                  profile.model.rangeOfCharacter(from: .controlCharacters) == nil else { throw ProviderSettingsError.invalidModel }
            validated = ProviderProfile(model: model, baseURL: try Self.canonicalEndpoint(profile.baseURL))
        }
        profiles[id] = validated
        // Models and endpoint URLs are the only profile fields. Secrets never enter this data.
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
        revision &+= 1
    }
    func apiKey(for id: String) throws -> String? {
        guard usesAPIKey(id) else { return nil }
        return try credentials.value(for: credentialAccount(id))
    }
    func saveAPIKey(_ key: String, for id: String) throws {
        guard usesAPIKey(id) else { throw ProviderSettingsError.unsupportedProvider }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { throw ProviderSettingsError.invalidKey }
        try credentials.save(value, for: credentialAccount(id)); revision &+= 1
    }
    func removeAPIKey(for id: String) throws {
        guard usesAPIKey(id) else { return }
        try credentials.remove(credentialAccount(id)); revision &+= 1
    }
    func hasKey(for id: String) -> Bool {
        guard usesAPIKey(id), let account = try? credentialAccount(id) else { return false }
        return (try? credentials.contains(account)) ?? false
    }
    private func usesAPIKey(_ id: String) -> Bool {
        if let provider = ImageProviderID(rawValue: id) { return provider != .codex }
        return id == PromptAssistantID.anthropic.rawValue
    }
    private func credentialAccount(_ id: String) throws -> String {
        let canonical = try Self.canonicalEndpoint(profile(for: id).baseURL)
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return id + ":" + digest
    }
    private static func canonicalEndpoint(_ value: String) throws -> String {
        guard value.rangeOfCharacter(from: .controlCharacters) == nil, !value.contains("\\") else { throw ProviderSettingsError.invalidEndpoint }
        let endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: endpoint), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              !components.path.components(separatedBy: "/").contains(".."),
              components.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && isLoopback(host)) else { throw ProviderSettingsError.invalidEndpoint }
        components.scheme = scheme; components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let canonical = components.string, components.url != nil else { throw ProviderSettingsError.invalidEndpoint }
        return canonical
    }
    private static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "::1", "0:0:0:0:0:0:0:1"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && Int($0).map { (0...255).contains($0) } == true
        }
    }
}
