import Foundation

/// Regroupement des livres par genre (« roman » = « Roman »), pour la barre latérale.
public enum GenreNames {
    public struct Group: Identifiable, Hashable, Sendable {
        public var id: String { key }
        public let key: String
        /// Graphie la plus fréquente.
        public let name: String
        /// Nombre de livres (et non de fichiers).
        public let bookCount: Int
    }

    public static func key(_ genre: String) -> String { Matching.key(genre) }

    public static func groups(_ books: [Book], identities: [Book.ID: String] = [:]) -> [Group] {
        var spellings: [String: [String: Int]] = [:]
        var members: [String: Set<String>] = [:]
        for b in books {
            guard let genre = b.genre?.trimmingCharacters(in: .whitespaces), !genre.isEmpty else { continue }
            let k = key(genre)
            spellings[k, default: [:]][genre, default: 0] += 1
            members[k, default: []].insert(identities[b.id] ?? BookGroups.key(b))
        }
        return spellings.map { k, variants in
            let name = variants.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
            return Group(key: k, name: name, bookCount: members[k]?.count ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
