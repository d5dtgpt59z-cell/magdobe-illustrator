import Foundation

struct ProductionICCDescriptor: Codable, Equatable {
    var sha256: String
    var name: String
    func validated() throws -> ProductionICCDescriptor {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256,
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw ProductionPDFError.invalidProfile }
        return self
    }
}

/// Requirements only: ICC bytes are a separate portable document asset, never job/AI metadata.
struct ProductionPDFSettings: Codable, Equatable {
    enum Target: String, Codable, CaseIterable { case cmykPDF = "cmyk_pdf", pdfx4 }
    enum Intent: String, Codable, CaseIterable {
        case relativeColorimetric = "relative_colorimetric", perceptual, absoluteColorimetric = "absolute_colorimetric", saturation
        var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
    }
    enum BlackPolicy: String, Codable { case icc }
    enum TextMode: String, Codable { case outlines }
    var schemaVersion = 1
    var target: Target = .cmykPDF
    var iccProfile: ProductionICCDescriptor?
    var outputConditionIdentifier = ""
    var outputCondition = ""
    var registryName = ""
    var renderingIntent: Intent = .relativeColorimetric
    var blackPointCompensation = false
    var blackPolicy: BlackPolicy = .icc
    var textMode: TextMode = .outlines
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", target, iccProfile = "icc_profile"
        case outputConditionIdentifier = "output_condition_identifier", outputCondition = "output_condition"
        case registryName = "registry_name", renderingIntent = "rendering_intent"
        case blackPointCompensation = "black_point_compensation", blackPolicy = "black_policy", textMode = "text_mode"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .cmykPDF
        iccProfile = try c.decodeIfPresent(ProductionICCDescriptor.self, forKey: .iccProfile)
        outputConditionIdentifier = try c.decodeIfPresent(String.self, forKey: .outputConditionIdentifier) ?? ""
        outputCondition = try c.decodeIfPresent(String.self, forKey: .outputCondition) ?? ""
        registryName = try c.decodeIfPresent(String.self, forKey: .registryName) ?? ""
        renderingIntent = try c.decodeIfPresent(Intent.self, forKey: .renderingIntent) ?? .relativeColorimetric
        blackPointCompensation = try c.decodeIfPresent(Bool.self, forKey: .blackPointCompensation) ?? false
        blackPolicy = try c.decodeIfPresent(BlackPolicy.self, forKey: .blackPolicy) ?? .icc
        textMode = try c.decodeIfPresent(TextMode.self, forKey: .textMode) ?? .outlines
    }
    func validated(requireProfile: Bool = false) throws -> ProductionPDFSettings {
        guard schemaVersion == 1,
              outputConditionIdentifier.count <= 128, outputCondition.count <= 500, registryName.count <= 500,
              [outputConditionIdentifier, outputCondition, registryName].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw ProductionPDFError.settings("Keep the output condition identifier under 129 characters, descriptions under 501, without control characters.")
        }
        if let iccProfile { _ = try iccProfile.validated() }
        if !registryName.isEmpty {
            guard let url = URLComponents(string: registryName), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw ProductionPDFError.settings("Enter a registry URL without credentials, query parameters or fragments, or leave it blank.")
            }
        }
        if requireProfile {
            guard iccProfile != nil else { throw ProductionPDFError.missingProfile }
            guard !outputConditionIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProductionPDFError.settings("Enter the printer's output condition identifier before exporting Production PDF.")
            }
        }
        return self
    }
}

enum ProductionPDFError: LocalizedError {
    case invalidProfile, missingProfile, settings(String), noArtwork, invalidResult, validationFailed
    var errorDescription: String? { switch self {
        case .invalidProfile: return "Choose a valid CMYK printer/output ICC v2 or v4 profile, no larger than 16 MiB. RGB, display, DeviceLink and damaged profiles are not supported."
        case .missingProfile: return "Import the printer's CMYK ICC profile, or reimport the matching profile for this saved setup. No substitute profile will be chosen."
        case .settings(let message): return message
        case .noArtwork: return "There is no visible process artwork to export. Production PDF includes unassigned, Artwork and Barcode objects; technical and finish roles are omitted."
        case .invalidResult: return "The PDF finalizer returned an invalid or mismatched result. The destination was kept; inspect the retained production artifacts."
        case .validationFailed: return "The finalized PDF did not pass the supported generated-vector checks. Your existing destination was kept. Open the report to review the findings."
    } }
}
