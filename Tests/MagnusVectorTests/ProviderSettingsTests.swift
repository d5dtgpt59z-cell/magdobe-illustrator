import XCTest
@testable import MagnusVector

private final class MemoryProviderCredentials: ProviderCredentialStore {
    var values: [String: String] = [:]
    var secretReads = 0
    var existenceChecks = 0
    func value(for account: String) throws -> String? { secretReads += 1; return values[account] }
    func contains(_ account: String) throws -> Bool { existenceChecks += 1; return values[account] != nil }
    func save(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

final class ProviderSettingsTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "Magdobe.ProviderSettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor func testDefaultSignInProvidersNeverReadOrRequireKeys() throws {
        let credentials = MemoryProviderCredentials()
        let settings = ProviderSettings(defaults: try isolatedDefaults(), credentialStore: credentials)
        XCTAssertEqual(settings.imageProvider, .codex)
        XCTAssertEqual(settings.assistant, .none)
        XCTAssertEqual(settings.profile(for: "codex"), ProviderProfile(model: "", baseURL: ""))
        XCTAssertNil(try settings.apiKey(for: "codex"))
        XCTAssertNil(try settings.apiKey(for: "claudeCLI"))
        XCTAssertFalse(settings.hasKey(for: "codex"))
        XCTAssertFalse(settings.hasKey(for: "claudeCLI"))
        XCTAssertEqual(credentials.secretReads, 0)
        XCTAssertEqual(credentials.existenceChecks, 0)
        XCTAssertThrowsError(try settings.saveAPIKey("not-needed", for: "codex"))
        XCTAssertTrue(credentials.values.isEmpty)
    }

    @MainActor func testNonsecretSettingsPersistAndPublishARevision() throws {
        let defaults = try isolatedDefaults(), credentials = MemoryProviderCredentials()
        let settings = ProviderSettings(defaults: defaults, credentialStore: credentials)
        let custom = ProviderProfile(model: "image-model-v2", baseURL: "https://images.example.test/v1")
        let initial = settings.revision
        settings.imageProvider = .compatible; settings.assistant = .anthropic
        try settings.updateProfile(custom, for: "compatible")
        XCTAssertGreaterThan(settings.revision, initial)
        let restored = ProviderSettings(defaults: defaults, credentialStore: credentials)
        XCTAssertEqual(restored.imageProvider, .compatible)
        XCTAssertEqual(restored.assistant, .anthropic)
        XCTAssertEqual(restored.profile(for: "compatible"), custom)
        XCTAssertEqual(restored.profile(for: "anthropic").model, "claude-sonnet-5-5")
        XCTAssertEqual(restored.profile(for: "openai").model, "gpt-image-2.5-flare")
        XCTAssertTrue(credentials.values.isEmpty)
    }

    @MainActor func testKeysStayOutOfDefaultsAndExistenceCheckDoesNotReadThem() throws {
        let defaults = try isolatedDefaults(), credentials = MemoryProviderCredentials()
        let settings = ProviderSettings(defaults: defaults, credentialStore: credentials)
        let secret = "isolated-unit-test-secret-5275"
        let initial = settings.revision
        try settings.saveAPIKey(secret, for: "openai")
        XCTAssertGreaterThan(settings.revision, initial)
        XCTAssertTrue(settings.hasKey(for: "openai"))
        XCTAssertEqual(credentials.secretReads, 0)
        XCTAssertEqual(credentials.existenceChecks, 1)
        XCTAssertEqual(try settings.apiKey(for: "openai"), secret)
        for value in defaults.dictionaryRepresentation().values {
            if let data = value as? Data { XCTAssertNil(data.range(of: Data(secret.utf8))) }
            XCTAssertFalse(String(describing: value).contains(secret))
        }
        XCTAssertEqual(credentials.values.count, 1)
        XCTAssertFalse(credentials.values.keys.contains { $0.contains(secret) })
        let revision = settings.revision
        try settings.removeAPIKey(for: "openai")
        XCTAssertGreaterThan(settings.revision, revision)
        XCTAssertNil(try settings.apiKey(for: "openai"))
    }

    @MainActor func testKeysAreScopedToProviderAndFullEndpointIncludingPath() throws {
        let settings = ProviderSettings(defaults: try isolatedDefaults(), credentialStore: MemoryProviderCredentials())
        try settings.updateProfile(ProviderProfile(model: "first", baseURL: "https://images-a.example.test/v1"), for: "compatible")
        try settings.saveAPIKey("endpoint-a-key", for: "compatible")
        try settings.updateProfile(ProviderProfile(model: "second", baseURL: "https://images-a.example.test/v2"), for: "compatible")
        XCTAssertFalse(settings.hasKey(for: "compatible"))
        XCTAssertNil(try settings.apiKey(for: "compatible"))
        try settings.updateProfile(ProviderProfile(model: "second", baseURL: "https://images-b.example.test/v1"), for: "compatible")
        XCTAssertNil(try settings.apiKey(for: "compatible"))
        try settings.saveAPIKey("endpoint-b-key", for: "compatible")
        try settings.updateProfile(ProviderProfile(model: "new-model", baseURL: "HTTPS://IMAGES-A.EXAMPLE.TEST:443/v1/"), for: "compatible")
        XCTAssertEqual(try settings.apiKey(for: "compatible"), "endpoint-a-key")
        try settings.updateProfile(ProviderProfile(model: "new-model", baseURL: "https://images-a.example.test/v1"), for: "openai")
        XCTAssertNil(try settings.apiKey(for: "openai"))
        try settings.removeAPIKey(for: "compatible")
        XCTAssertNil(try settings.apiKey(for: "compatible"))
        try settings.updateProfile(ProviderProfile(model: "second", baseURL: "https://images-b.example.test/v1"), for: "compatible")
        XCTAssertEqual(try settings.apiKey(for: "compatible"), "endpoint-b-key")
    }

    @MainActor func testInvalidProfilesAreRejectedBeforePersistenceOrCredentialAccess() throws {
        let defaults = try isolatedDefaults(), credentials = MemoryProviderCredentials()
        let settings = ProviderSettings(defaults: defaults, credentialStore: credentials)
        let original = ProviderProfile(model: "custom-image", baseURL: "https://images.example.test/v1")
        try settings.updateProfile(original, for: "compatible")
        let revision = settings.revision
        for endpoint in ["", "not-a-url", "http://remote.example.test/v1", "https://user:password@example.test/v1", "https://example.test/v1?key=secret-must-not-persist", "https://example.test/v1#fragment", "https://example.test/../v1", "https://example.test/%2e%2e/v1", "https://example.test/\\v1", "https://example.test/v1\n", "https://example.test:99999/v1"] {
            XCTAssertThrowsError(try settings.updateProfile(ProviderProfile(model: "custom", baseURL: endpoint), for: "compatible"), endpoint)
            XCTAssertEqual(settings.profile(for: "compatible"), original)
            XCTAssertEqual(settings.revision, revision)
        }
        for model in ["", "   ", "image-model\nInjected", String(repeating: "x", count: 257)] {
            XCTAssertThrowsError(try settings.updateProfile(ProviderProfile(model: model, baseURL: original.baseURL), for: "compatible"))
            XCTAssertEqual(settings.profile(for: "compatible"), original)
        }
        let restored = ProviderSettings(defaults: defaults, credentialStore: credentials)
        XCTAssertEqual(restored.profile(for: "compatible"), original)
        for value in defaults.dictionaryRepresentation().values {
            if let data = value as? Data { XCTAssertNil(data.range(of: Data("secret-must-not-persist".utf8))) }
            XCTAssertFalse(String(describing: value).contains("secret-must-not-persist"))
        }
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertEqual(credentials.secretReads, 0)
        XCTAssertEqual(credentials.existenceChecks, 0)
        for key in ["", "   ", "header\r\nInjected: true", "bad key"] {
            XCTAssertThrowsError(try settings.saveAPIKey(key, for: "openai"))
        }
        XCTAssertTrue(credentials.values.isEmpty)
    }

    @MainActor func testInvalidLegacyEndpointNeverReadsCredentials() throws {
        let defaults = try isolatedDefaults(), credentials = MemoryProviderCredentials()
        let malformed = ["compatible": ProviderProfile(model: "image", baseURL: "https://images.example.test/v1?key=old-test-value")]
        defaults.set(try JSONEncoder().encode(malformed), forKey: "ai.providerProfiles")
        let settings = ProviderSettings(defaults: defaults, credentialStore: credentials)
        XCTAssertThrowsError(try settings.apiKey(for: "compatible"))
        XCTAssertFalse(settings.hasKey(for: "compatible"))
        XCTAssertEqual(credentials.secretReads, 0)
        XCTAssertEqual(credentials.existenceChecks, 0)
    }

    @MainActor func testLocalEndpointsAndSignInProfilesRemainSupported() throws {
        let settings = ProviderSettings(defaults: try isolatedDefaults(), credentialStore: MemoryProviderCredentials())
        for endpoint in ["http://localhost:8080/v1", "http://127.0.0.1:11434/v1", "http://127.20.1.2/v1", "http://[::1]:8080/v1"] {
            XCTAssertNoThrow(try settings.updateProfile(ProviderProfile(model: "local-image", baseURL: endpoint), for: "compatible"))
        }
        try settings.updateProfile(ProviderProfile(model: "", baseURL: ""), for: "codex")
        try settings.updateProfile(ProviderProfile(model: "", baseURL: ""), for: "claudeCLI")
        XCTAssertNil(try settings.apiKey(for: "codex"))
        XCTAssertNil(try settings.apiKey(for: "claudeCLI"))
    }
}
