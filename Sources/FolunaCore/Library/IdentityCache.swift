import Foundation

/// Identités de la bibliothèque (voir `BookGroups.identities`), tenues à jour titre par titre.
///
/// Les identités d'un fichier ne dépendent que des fichiers de même titre (`BookGroups.titleKey`), et pour
/// chacun de son chemin, de son titre et de ses auteurs. Après une modification, seuls les titres touchés
/// (ancien et nouveau titre d'un livre corrigé, fichiers ajoutés ou disparus) sont recalculés ; une étiquette,
/// un favori ou la corbeille n'en touchent aucun.
public struct IdentityCache: Sendable {
    private struct Entry: Sendable, Equatable {
        var title: String
        var authors: [String]
        var titleKey: String
    }

    public private(set) var map: [Book.ID: String] = [:]
    private var entries: [Book.ID: Entry] = [:]

    public init() {}

    /// Rien encore de calculé.
    public var isEmpty: Bool { entries.isEmpty }

    /// Met les identités à jour pour `books` et les renvoie ; identiques à `BookGroups.identities(books)`.
    /// Cas courant (aucun titre ni auteur changé) : une recherche par fichier, rien n'est recopié.
    @discardableResult
    public mutating func update(_ books: [Book]) -> [Book.ID: String] {
        if entries.isEmpty {
            // Premier calcul : chaque clé de titre une seule fois, sans suivre les titres touchés (tous le sont).
            let keys = books.map { BookGroups.titleKey($0.title) }
            entries.reserveCapacity(books.count)
            for (i, b) in books.enumerated() { entries[b.id] = Entry(title: b.title, authors: b.authors, titleKey: keys[i]) }
            map = BookGroups.identities(books, titleKeys: keys)
            return map
        }
        var touched = Set<String>()
        for b in books {
            if let e = entries[b.id] {
                if e.title == b.title && e.authors == b.authors { continue }
                touched.insert(e.titleKey)
            }
            let key = BookGroups.titleKey(b.title)
            touched.insert(key)
            entries[b.id] = Entry(title: b.title, authors: b.authors, titleKey: key)
        }
        // Fichiers disparus (un chemin changé compte aussi : l'identifiant est le chemin). Les fichiers nouveaux
        // sont déjà ajoutés : sans disparu, il y a autant d'entrées que de fichiers.
        if entries.count != books.count {
            let present = Set(books.lazy.map(\.id))
            for (id, e) in entries where !present.contains(id) {
                touched.insert(e.titleKey)
                entries[id] = nil
                map[id] = nil
            }
        }
        guard !touched.isEmpty else { return map }
        let affected = books.filter { touched.contains(entries[$0.id]!.titleKey) }
        // Beaucoup de fichiers touchés (premier calcul, gros parcours) : le calcul complet est aussi rapide.
        if affected.count * 2 > books.count {
            map = BookGroups.identities(books, titleKeys: books.map { entries[$0.id]!.titleKey })
            return map
        }
        // Tous les fichiers des titres touchés sont recalculés : un fichier renommé quitte son ancien groupe.
        for (id, value) in BookGroups.identities(affected, titleKeys: affected.map { entries[$0.id]!.titleKey }) { map[id] = value }
        return map
    }
}
