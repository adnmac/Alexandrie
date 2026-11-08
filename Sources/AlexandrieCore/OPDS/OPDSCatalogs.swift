import Foundation

/// Catalogue OPDS connu de l'app : proposé d'office ou ajouté par l'utilisateur.
public struct OPDSCatalog: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    /// Proposé d'office (peut être masqué, puis rétabli).
    public var isSuggested: Bool

    public init(id: String = UUID().uuidString, name: String, url: URL, isSuggested: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.isSuggested = isSuggested
    }

    /// Catalogues publics, gratuits et sans compte, vérifiés le 8 novembre 2026.
    public static let suggested: [OPDSCatalog] = [
        OPDSCatalog(id: "gutenberg", name: "Project Gutenberg",
                    url: URL(string: "https://www.gutenberg.org/ebooks.opds/")!, isSuggested: true),
        OPDSCatalog(id: "ebooksgratuits", name: "Ebooks libres et gratuits",
                    url: URL(string: "https://www.ebooksgratuits.com/opds/")!, isSuggested: true),
        OPDSCatalog(id: "bnr", name: "Bibliothèque numérique romande",
                    url: URL(string: "https://ebooks-bnr.com/opds/")!, isSuggested: true),
    ]
}

/// Catalogues de l'utilisateur et livres déjà téléchargés, enregistrés dans `opds.json`.
public struct OPDSCatalogList: Codable, Equatable, Sendable {
    /// Catalogues ajoutés par l'utilisateur (les catalogues proposés n'y sont pas).
    public var added: [OPDSCatalog] = []
    /// Catalogues proposés que l'utilisateur a retirés.
    public var hiddenSuggestions: Set<String> = []
    /// Noms donnés par l'utilisateur aux catalogues proposés.
    public var renamed: [String: String] = [:]
    /// Livres téléchargés : identifiant de l'entrée OPDS → chemin du fichier dans la bibliothèque.
    public var downloads: [String: String] = [:]

    public init() {}

    /// Catalogues affichés : les proposés encore visibles, puis ceux de l'utilisateur.
    public var catalogs: [OPDSCatalog] {
        let suggested = OPDSCatalog.suggested.filter { !hiddenSuggestions.contains($0.id) }.map { c -> OPDSCatalog in
            var c = c
            if let name = renamed[c.id], !name.isEmpty { c.name = name }
            return c
        }
        return suggested + added
    }

    public func catalog(id: String) -> OPDSCatalog? { catalogs.first { $0.id == id } }

    /// Ajoute un catalogue ; une adresse déjà connue n'est pas ajoutée deux fois (le catalogue existant est rendu).
    @discardableResult
    public mutating func add(name: String, url: URL) -> OPDSCatalog {
        if let known = catalogs.first(where: { Self.sameAddress($0.url, url) }) { return known }
        if let hidden = OPDSCatalog.suggested.first(where: { Self.sameAddress($0.url, url) }) {
            hiddenSuggestions.remove(hidden.id)
            return hidden
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = OPDSCatalog(name: trimmed.isEmpty ? (url.host ?? "Catalogue") : trimmed, url: url)
        added.append(catalog)
        return catalog
    }

    public mutating func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let i = added.firstIndex(where: { $0.id == id }) {
            added[i].name = trimmed
        } else if OPDSCatalog.suggested.contains(where: { $0.id == id }) {
            renamed[id] = trimmed
        }
    }

    public mutating func remove(_ id: String) {
        if OPDSCatalog.suggested.contains(where: { $0.id == id }) {
            hiddenSuggestions.insert(id)
        } else {
            added.removeAll { $0.id == id }
        }
    }

    public mutating func restoreSuggestions() {
        hiddenSuggestions = []
        renamed = [:]
    }

    /// Même adresse, au `/` final et à la casse de l'hôte près.
    static func sameAddress(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String {
            var s = u.absoluteString.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return key(a) == key(b)
    }

    public static func load(_ url: URL) -> OPDSCatalogList {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(OPDSCatalogList.self, from: data) else { return OPDSCatalogList() }
        return list
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
