import Foundation

/// Étiquettes de l'utilisateur (S-106) : regroupées sans tenir compte des majuscules ni des accents,
/// pour la barre latérale. Les sujets lus dans les fichiers n'y figurent pas.
public enum TagNames {
    public struct Group: Identifiable, Hashable, Sendable {
        public var id: String { key }
        public let key: String
        /// Graphie la plus fréquente.
        public let name: String
        /// Nombre de livres (et non de fichiers).
        public let bookCount: Int
    }

    public static func key(_ tag: String) -> String { Matching.key(tag) }

    /// Nettoie une saisie : espaces retirés, vides et doublons (même clé) écartés, l'ordre gardé.
    public static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !key($0).isEmpty && seen.insert(key($0)).inserted }
    }

    /// Le livre porte-t-il cette étiquette (clé de regroupement) ?
    public static func has(_ book: Book, key k: String) -> Bool { book.labels.contains { key($0) == k } }

    public static func groups(_ books: [Book], identities: [Book.ID: String] = [:]) -> [Group] {
        var spellings: [String: [String: Int]] = [:]
        var members: [String: Set<String>] = [:]
        for b in books {
            for tag in clean(b.labels) {
                let k = key(tag)
                spellings[k, default: [:]][tag, default: 0] += 1
                members[k, default: []].insert(identities[b.id] ?? BookGroups.key(b))
            }
        }
        return spellings.map { k, variants in
            let name = variants.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
            return Group(key: k, name: name, bookCount: members[k]?.count ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
