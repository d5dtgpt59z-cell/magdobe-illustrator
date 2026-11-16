import Foundation
import CoreGraphics

/// A job's physical requirements. Artwork coordinates remain independent of physical units.
struct ProductionSpec: Codable, Equatable {
    enum Workflow: String, Codable, CaseIterable { case tradingCard = "trading_card", packaging }
    enum Placement: String, Codable, CaseIterable { case fitTrim = "fit_trim", fillBleed = "fill_bleed" }
    enum BleedIntent: String, Codable, CaseIterable { case fullBleed = "full_bleed", whiteBorder = "white_border" }
    enum ColorPolicy: String, Codable, CaseIterable { case reviewRGB = "review_rgb", rgb, cmyk }
    var schemaVersion = 1
    var workflow: Workflow = .tradingCard
    var name = "Untitled production job"
    var trimWidthMM = 63.5
    var trimHeightMM = 88.9
    var bleedMM = 3.175
    var safeMM = 3.175
    var placement: Placement = .fitTrim
    var bleedIntent: BleedIntent = .fullBleed
    var colorPolicy: ColorPolicy = .reviewRGB
    var minTextPT: Double?
    var minStrokeMM: Double?
    var minRasterPPI: Double?
    var expectedRoles: [ProductionRole]?
    var supplierConfirmed = false
    var profileName: String?
    var printerNotes: String?
    var specSource: String?
    var pdf: ProductionPDFSettings?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", workflow, name, placement, pdf
        case trimWidthMM = "trim_width_mm", trimHeightMM = "trim_height_mm"
        case bleedMM = "bleed_mm", safeMM = "safe_mm", bleedIntent = "bleed_intent"
        case colorPolicy = "color_policy", minTextPT = "min_text_pt", minStrokeMM = "min_stroke_mm"
        case minRasterPPI = "min_raster_ppi", expectedRoles = "expected_roles", supplierConfirmed = "supplier_confirmed"
        case profileName = "profile_name", printerNotes = "printer_notes", specSource = "spec_source"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        workflow = try c.decode(Workflow.self, forKey: .workflow)
        name = try c.decode(String.self, forKey: .name)
        trimWidthMM = try c.decode(Double.self, forKey: .trimWidthMM)
        trimHeightMM = try c.decode(Double.self, forKey: .trimHeightMM)
        bleedMM = try c.decode(Double.self, forKey: .bleedMM)
        safeMM = try c.decode(Double.self, forKey: .safeMM)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .fitTrim
        bleedIntent = try c.decode(BleedIntent.self, forKey: .bleedIntent)
        colorPolicy = try c.decode(ColorPolicy.self, forKey: .colorPolicy)
        minTextPT = try c.decodeIfPresent(Double.self, forKey: .minTextPT)
        minStrokeMM = try c.decodeIfPresent(Double.self, forKey: .minStrokeMM)
        minRasterPPI = try c.decodeIfPresent(Double.self, forKey: .minRasterPPI)
        expectedRoles = try c.decodeIfPresent([ProductionRole].self, forKey: .expectedRoles)
        supplierConfirmed = try c.decodeIfPresent(Bool.self, forKey: .supplierConfirmed) ?? false
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
        printerNotes = try c.decodeIfPresent(String.self, forKey: .printerNotes)
        specSource = try c.decodeIfPresent(String.self, forKey: .specSource)
        pdf = try c.decodeIfPresent(ProductionPDFSettings.self, forKey: .pdf)
    }
    func validated() throws -> ProductionSpec {
        guard schemaVersion == 1 else { throw ProductionError.invalidSpec("Unsupported production specification version.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
              [profileName, printerNotes, specSource].compactMap({ $0 }).allSatisfy({ $0.count <= 20_000 }) else {
            throw ProductionError.invalidSpec("Give the job a name of up to 160 characters and keep printer notes under 20,000 characters.")
        }
        guard name.unicodeScalars.allSatisfy({ scalar in
            let n = scalar.value
            return n == 9 || n == 10 || n == 13 || (0x20...0xD7FF).contains(n) || (0xE000...0xFFFD).contains(n) || (0x10000...0x10FFFF).contains(n)
        }) else { throw ProductionError.invalidSpec("The job name contains a control character that SVG XML cannot represent. Remove it before exporting.") }
        guard [trimWidthMM, trimHeightMM, bleedMM, safeMM].allSatisfy(\.isFinite),
              (1...5000).contains(trimWidthMM), (1...5000).contains(trimHeightMM),
              (0...300).contains(bleedMM), (0...300).contains(safeMM), safeMM * 2 < min(trimWidthMM, trimHeightMM) else {
            throw ProductionError.invalidSpec("Enter positive trim dimensions, nonnegative bleed, and a safe margin smaller than half the shortest trim edge.")
        }
        guard [(minTextPT, 200.0), (minStrokeMM, 100.0), (minRasterPPI, 5000.0)].allSatisfy({ value, maximum in
            value.map({ $0.isFinite && $0 > 0 && $0 <= maximum }) ?? true
        }) else {
            throw ProductionError.invalidSpec("Enter positive minimum requirements within the checker limits: 200 pt text, 100 mm stroke, or 5,000 PPI.")
        }
        if let pdf { _ = try pdf.validated() }
        return self
    }
    static let pointsPerMM = 72.0 / 25.4
    var bleedWidthMM: Double { trimWidthMM + bleedMM * 2 }
    var bleedHeightMM: Double { trimHeightMM + bleedMM * 2 }
    var trimRect: CGRect { CGRect(x: bleedMM, y: bleedMM, width: trimWidthMM, height: trimHeightMM) }
    var safeRect: CGRect { trimRect.insetBy(dx: safeMM, dy: safeMM) }
    func jobData() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    func layout(for project: VectorProject) throws -> ProductionLayout {
        _ = try validated(); _ = try project.validated()
        let target = placement == .fitTrim ? trimRect : CGRect(x: 0, y: 0, width: bleedWidthMM, height: bleedHeightMM)
        let pt = Self.pointsPerMM
        let sx = target.width * pt / project.width, sy = target.height * pt / project.height
        let scale = placement == .fitTrim ? min(sx, sy) : max(sx, sy)
        return ProductionLayout(scale: scale,
            x: target.midX * pt - project.width * scale / 2,
            y: target.midY * pt - project.height * scale / 2,
            width: project.width * scale, height: project.height * scale)
    }
}

struct ProductionLayout: Equatable {
    var scale: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum ProductionRole: String, Codable, CaseIterable, Identifiable {
    case artwork, cut, crease, perforation, glue, foil, emboss, deboss, varnish
    case whiteInk = "white_ink", registration, barcode, legend
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum ProductionError: LocalizedError {
    case invalidSpec(String), noSpec
    var errorDescription: String? { switch self {
        case .invalidSpec(let message): return message
        case .noSpec: return "Set the physical dimensions and printer requirements in File → Production Setup first."
    } }
}

struct ProductionProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var spec: ProductionSpec
}

enum ProductionProfiles {
    static let key = "production.customProfiles.v1"
    static func load(from defaults: UserDefaults = .standard) -> [ProductionProfile] {
        guard let data = defaults.data(forKey: key), let entries = try? JSONDecoder().decode([ProductionProfile].self, from: data) else { return [] }
        return entries.filter { (try? $0.spec.validated()) != nil }
    }
    static func save(_ entries: [ProductionProfile], to defaults: UserDefaults = .standard) throws {
        guard entries.count <= 100 else { throw ProductionError.invalidSpec("Keep up to 100 custom printer profiles.") }
        for entry in entries { _ = try entry.spec.validated() }
        defaults.set(try JSONEncoder().encode(entries), forKey: key)
    }
}
