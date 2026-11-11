import Foundation

/// Liseuse connue (Kindle, Kobo, liseuse USB) : reconnue par son identifiant, nommée par l'utilisateur.
public struct Reader: Codable, Identifiable, Hashable, Sendable {
    /// Identifiant de l'appareil (`KindleDevice.identifier`).
    public var id: String
    public var name: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    /// Marque enregistrée ; absente dans les `readers.json` d'avant les Kobo : une Kindle.
    private var storedBrand: ReaderBrand?
    /// Dossier des livres d'une liseuse générique (relatif à la racine du disque ; vide : la racine).
    public var booksFolder: String?

    enum CodingKeys: String, CodingKey {
        case id, name, firstSeenAt, lastSeenAt, booksFolder
        case storedBrand = "brand"
    }

    public var brand: ReaderBrand {
        get { storedBrand ?? .kindle }
        set { storedBrand = newValue }
    }

    public init(id: String, name: String, seenAt: Date = Date(), brand: ReaderBrand = .kindle, booksFolder: String? = nil) {
        self.id = id
        self.name = name
        firstSeenAt = seenAt
        lastSeenAt = seenAt
        storedBrand = brand
        self.booksFolder = booksFolder
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
