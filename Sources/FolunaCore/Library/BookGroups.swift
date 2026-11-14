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
            p.genre = p.genre ?? other.genre
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

    /// Clé de regroupement : titre (casse, accents, ponctuation et mention de genre « : roman » ignorés)
    /// + auteurs (graphies regroupées).
    public static func key(_ book: Book) -> String {
        Matching.key(Matching.withoutGenre(book.title)) + "|" + AuthorNames.keys(of: book).sorted().joined(separator: ";")
    }

    /// Regroupe en conservant l'ordre de la liste (position du premier fichier de chaque livre).
    /// `identities` (voir `identities(_:)`, calculées sur toute la bibliothèque) rapproche aussi les fichiers
    /// d'un même livre dont les auteurs sont écrits différemment ou manquent.
    public static func make(_ books: [Book], identities: [Book.ID: String]? = nil) -> [BookGroup] {
        var order: [String] = []
        var members: [String: [Book]] = [:]
        for b in books {
            let k = identities?[b.id] ?? key(b)
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

    // MARK: - Identité d'un livre (même titre, auteurs rapprochés)

    /// Identité de chaque fichier : les fichiers d'un même titre sont réunis quand leurs auteurs concordent
    /// (« Soljénitsyne » ⊂ « Alexandre Soljénitsyne »), quand ils sont rangés dans le même dossier, ou quand
    /// l'auteur manque (vide, « Unknown », titre recopié…) et qu'un seul auteur connu existe pour ce titre.
    /// Des livres de même titre et d'auteurs différents (« Les Enchanteurs » de Gary et d'Ellroy) restent séparés.
    public static func identities(_ books: [Book]) -> [Book.ID: String] {
        var out: [Book.ID: String] = [:]
        let byTitle = Dictionary(grouping: books) { Matching.key(Matching.withoutGenre($0.title)) }
        for (title, files) in byTitle {
            // Groupes stricts (même clé), puis rapprochements successifs.
            var clusters = Dictionary(grouping: files, by: key).map(\.value)
            var merged = true
            while merged {
                merged = false
                search: for i in clusters.indices {
                    for j in clusters.indices where j > i && related(clusters[i], clusters[j], title: title) {
                        clusters[i] += clusters[j]
                        clusters.remove(at: j)
                        merged = true
                        break search
                    }
                }
            }
            // Fichiers sans auteur fiable : rattachés au seul livre de ce titre qui en a un, ou réunis entre eux.
            let reliable = clusters.filter { $0.contains { hasReliableAuthor($0, title: title) } }
            let unreliable = clusters.filter { !$0.contains { hasReliableAuthor($0, title: title) } }
            if !unreliable.isEmpty, reliable.count <= 1 {
                clusters = [(reliable.first ?? []) + unreliable.flatMap { $0 }]
            }
            for cluster in clusters {
                // Clé stable : celle d'un fichier à l'auteur fiable si possible, la plus petite à défaut.
                let reliableKeys = cluster.filter { hasReliableAuthor($0, title: title) }.map(key)
                let id = (reliableKeys.isEmpty ? cluster.map(key) : reliableKeys).min()!
                for b in cluster { out[b.id] = id }
            }
        }
        return out
    }

    /// Empreinte de ce dont dépendent `identities(_:)` : chemin, titre et auteurs de chaque fichier, dans l'ordre.
    /// Une étiquette, un favori, la corbeille ou un envoi ne la changent pas : les identités calculées restent bonnes.
    public static func identitySignature(_ books: [Book]) -> Int {
        var h = Hasher()
        h.combine(books.count)
        for b in books {
            h.combine(b.path)
            h.combine(b.title)
            h.combine(b.authors)
        }
        return h.finalize()
    }

    /// Deux groupes d'un même titre sont le même livre : un auteur de l'un est contenu dans un auteur de l'autre,
    /// ou un fichier de chacun est rangé dans le même dossier de livre (« Titre (528) », à la Calibre ; un dossier
    /// thématique comme « Poutine » peut réunir plusieurs livres de même titre).
    static func related(_ a: [Book], _ b: [Book], title: String) -> Bool {
        let dirsA = Set(a.compactMap(bookFolder))
        if b.contains(where: { bookFolder($0).map(dirsA.contains) == true }) { return true }
        let wordsA = a.filter { hasReliableAuthor($0, title: title) }.flatMap(authorWordSets)
        let wordsB = b.filter { hasReliableAuthor($0, title: title) }.flatMap(authorWordSets)
        return wordsA.contains { x in wordsB.contains { y in x.isSubset(of: y) || y.isSubset(of: x) } }
    }

    /// Dossier propre à un livre (nom terminé par « (numéro) ») ; nil pour un dossier ordinaire.
    static func bookFolder(_ book: Book) -> String? {
        let dir = (book.path as NSString).deletingLastPathComponent
        let name = (dir as NSString).lastPathComponent
        return name.range(of: #" \(\d+\)$"#, options: .regularExpression) != nil ? dir : nil
    }

    /// Mots significatifs de chaque auteur (sans dates ni initiales, lettres doublées ignorées).
    static func authorWordSets(_ book: Book) -> [Set<String>] {
        book.authors.flatMap(AuthorNames.individuals).map { name in
            Set(AuthorNames.key(name).split(separator: " ").map(String.init)
                .filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) })
        }.filter { !$0.isEmpty }
    }

    private static let unknownAuthors: Set<String> = ["unknown", "inconnu", "inconnu e", "inconnue", "anonyme",
                                                      "anonymous", "auteur inconnu"]

    /// Faux si l'auteur manque ou n'en est pas un : « Unknown », titre recopié, nom de fichier téléchargé.
    static func hasReliableAuthor(_ book: Book, title: String) -> Bool {
        book.authors.contains { author in
            let k = Matching.key(author)
            guard !k.isEmpty, !unknownAuthors.contains(k), !k.contains("z lib") else { return false }
            return !(k.count > 8 && (k.contains(title) || title.contains(k)))
        }
    }

    /// Fichiers en double : pour un même livre et un même format, un seul fichier est gardé, les autres sont
    /// renvoyés ici (pour être masqués, jamais supprimés). Gardé : le contenu le plus récent ; entre copies
    /// identiques, celle du dossier source plutôt qu'un import, la moins profonde (pas un sous-dossier
    /// d'un autre livre), puis la plus récente.
    public static func duplicates(_ books: [Book], identities: [Book.ID: String]? = nil) -> Set<Book.ID> {
        var out = Set<Book.ID>()
        let ids = identities ?? self.identities(books)
        let sameBookAndFormat = Dictionary(grouping: books) { (ids[$0.id] ?? key($0)) + "|" + $0.format.rawValue }
        for files in sameBookAndFormat.values where files.count > 1 {
            // Date d'un contenu : la plus récente de ses copies (une copie peut porter une date plus ancienne).
            let contentDate = Dictionary(files.map { ($0.fingerprint, $0.modifiedAt) }, uniquingKeysWith: max)
            let kept = files.min { a, b in
                let (ca, cb) = (contentDate[a.fingerprint]!, contentDate[b.fingerprint]!)
                if ca != cb { return ca > cb }
                if a.isImported != b.isImported { return !a.isImported }
                let (da, db) = (a.path.split(separator: "/").count, b.path.split(separator: "/").count)
                if da != db { return da < db }
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
                return a.path < b.path
            }!
            out.formUnion(files.lazy.filter { $0.id != kept.id }.map(\.id))
        }
        return out
    }

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
