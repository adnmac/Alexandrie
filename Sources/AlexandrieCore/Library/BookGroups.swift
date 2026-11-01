import Foundation

/// Fichiers d'un même livre (même titre, mêmes auteurs) présents en plusieurs formats ou exemplaires.
public struct BookGroup: Identifiable, Hashable, Sendable {
    /// Identifiant de ligne : celui du livre s'il est seul, sinon `group:<chemin du fichier principal>`
    /// (stable pendant la correction du titre, qui s'applique à tous les fichiers du groupe).
    public let id: String
    public let books: [Book]

    public var isGroup: Bool { books.count > 1 }

    /// Fichier représentant le groupe (fiche, envoi à la Kindle) : le plus directement lisible par la Kindle.
    /// Les informations qui lui manquent sont complétées par celles des autres fichiers du livre
    /// (une série ou un ISBN présents seulement dans l'EPUB, par exemple).
    public var primary: Book {
        var p = books.min { BookGroups.rank($0) < BookGroups.rank($1) }!
        for other in books where other.id != p.id {
            if p.series == nil, other.series != nil { (p.series, p.seriesIndex) = (other.series, other.seriesIndex) }
            if p.seriesIndex == nil, p.series == other.series { p.seriesIndex = other.seriesIndex }
            p.isbn = p.isbn ?? other.isbn
            p.publisher = p.publisher ?? other.publisher
            p.publishedDate = p.publishedDate ?? other.publishedDate
            p.language = p.language ?? other.language
            p.summary = p.summary ?? other.summary
        }
        return p
    }

    /// Formats distincts, dans l'ordre de préférence.
    public var formats: [BookFormat] {
        var seen = Set<BookFormat>()
        return books.sorted { BookGroups.rank($0) < BookGroups.rank($1) }.map(\.format).filter { seen.insert($0).inserted }
    }
}

public enum BookGroups {
    static let groupPrefix = "group:"

    /// Clé de regroupement : titre (casse, accents et ponctuation ignorés) + auteurs (graphies regroupées).
    public static func key(_ book: Book) -> String {
        Matching.key(book.title) + "|" + AuthorNames.keys(of: book).sorted().joined(separator: ";")
    }

    /// Regroupe en conservant l'ordre de la liste (position du premier fichier de chaque livre).
    public static func make(_ books: [Book]) -> [BookGroup] {
        var order: [String] = []
        var members: [String: [Book]] = [:]
        for b in books {
            let k = key(b)
            if members[k] == nil { order.append(k) }
            members[k, default: []].append(b)
        }
        return order.map { k in
            let list = members[k]!
            guard list.count > 1 else { return BookGroup(id: list[0].id, books: list) }
            let primary = list.min { rank($0) < rank($1) }!
            return BookGroup(id: groupPrefix + primary.id, books: list)
        }
    }

    public static func isGroupID(_ id: String) -> Bool { id.hasPrefix(groupPrefix) }

    static func rank(_ book: Book) -> Int {
        switch book.format {
        case .azw3: 0
        case .mobi: 1
        case .azw: 2
        case .epub: 3
        case .pdf: 4
        }
    }
}
