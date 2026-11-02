import Foundation

/// Liseuse connue : une Kindle reconnue par son identifiant, nommée par l'utilisateur.
public struct Reader: Codable, Identifiable, Hashable, Sendable {
    /// Identifiant de l'appareil (`KindleDevice.identifier`).
    public var id: String
    public var name: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(id: String, name: String, seenAt: Date = Date()) {
        self.id = id
        self.name = name
        firstSeenAt = seenAt
        lastSeenAt = seenAt
    }
}

/// Persistance des liseuses en JSON (readers.json, dossier de l'app).
public enum ReaderList {
    public static func load(_ url: URL) throws -> [Reader] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Reader].self, from: Data(contentsOf: url))
    }

    public static func save(_ readers: [Reader], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(readers).write(to: url, options: .atomic)
    }
}
