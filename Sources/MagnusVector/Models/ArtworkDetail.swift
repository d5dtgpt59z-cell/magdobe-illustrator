import Foundation

enum ArtworkDetail: String, CaseIterable, Identifiable {
    case simple = "Simple", balanced = "Balanced", detailed = "Detailed", ultra = "Ultra"
    var id: Self { self }
    var explanation: String {
        switch self {
        case .simple: "Fewer shapes for bold, graphic artwork. Small details are simplified."
        case .balanced: "Smaller files and easier editing, with simplified texture and shading."
        case .detailed: "Keeps more small shapes and shading. Recommended for illustrated SVGs."
        case .ultra: "Keeps tiny accents and subtle color changes. Can create tens of thousands of objects; larger files and slower editing."
        }
    }
}

enum ArtworkHistory {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["MAGDOBE_ARTWORK_DIRECTORY"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Magdobe Illustrator/Artwork", isDirectory: true)
    }
    static func latestSource(in directory: URL) -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let jobs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return jobs.compactMap { job -> (URL, Date)? in
            guard let values = try? job.resourceValues(forKeys: keys), values.isDirectory == true else { return nil }
            let source = job.appendingPathComponent("source.png")
            guard FileManager.default.fileExists(atPath: source.path),
                  FileManager.default.fileExists(atPath: job.appendingPathComponent("artwork.mvector").path) else { return nil }
            return (source, values.contentModificationDate ?? .distantPast)
        }.max { $0.1 < $1.1 }?.0
    }
}
