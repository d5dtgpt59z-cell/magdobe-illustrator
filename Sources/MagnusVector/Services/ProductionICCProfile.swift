import Foundation
import CoreGraphics
import ColorSync
import CryptoKit

enum ProductionICCProfile {
    static let maximumBytes = 16 * 1_024 * 1_024
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ data: Data, name: String? = nil, expected: ProductionICCDescriptor? = nil) throws -> ProductionICCDescriptor {
        guard data.count >= 132, data.count <= maximumBytes else { throw ProductionPDFError.invalidProfile }
        let declared = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        func signature(_ range: Range<Int>) -> String { String(decoding: data[range], as: UTF8.self) }
        guard declared == data.count, [2,4].contains(data[8]), signature(12..<16) == "prtr", signature(16..<20) == "CMYK", ["XYZ ", "Lab "].contains(signature(20..<24)),
              signature(36..<40) == "acsp", let space = CGColorSpace(iccData: data as CFData), space.model == .cmyk, space.numberOfComponents == 4,
              let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(), ColorSyncProfileVerify(profile, nil, nil) else {
            throw ProductionPDFError.invalidProfile
        }
        let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
        let readable = (name ?? description ?? "Printer CMYK profile").trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = try ProductionICCDescriptor(sha256: sha256(data), name: String(readable.prefix(256))).validated()
        if let expected {
            _ = try expected.validated()
            guard descriptor.sha256 == expected.sha256.lowercased() else { throw ProductionPDFError.invalidProfile }
            return expected
        }
        return descriptor
    }
    static func read(_ url: URL) throws -> (Data, ProductionICCDescriptor) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let bytes = info.fileSize, bytes <= maximumBytes else { throw ProductionPDFError.invalidProfile }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return (data, try validate(data))
    }
}

struct ProductionICCLibrary {
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Magdobe Illustrator/Printer Profiles", isDirectory: true)
    func save(_ data: Data, descriptor: ProductionICCDescriptor) throws {
        _ = try ProductionICCProfile.validate(data, expected: descriptor)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(descriptor.sha256.lowercased() + ".icc")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func load(_ descriptor: ProductionICCDescriptor) throws -> Data {
        _ = try descriptor.validated()
        let url = directory.appendingPathComponent(descriptor.sha256.lowercased() + ".icc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProductionPDFError.missingProfile }
        let (data, _) = try ProductionICCProfile.read(url)
        _ = try ProductionICCProfile.validate(data, expected: descriptor)
        return data
    }
}
