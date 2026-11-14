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
    /// `titleKeys` : clés de titre déjà calculées, dans l'ordre de `books` (voir `IdentityCache`).
    public static func identities(_ books: [Book], titleKeys: [String]? = nil) -> [Book.ID: String] {
        var out: [Book.ID: String] = [:]
        out.reserveCapacity(books.count)
        var byTitle: [String: [Book]] = [:]
        if let titleKeys {
            for (i, b) in books.enumerated() { byTitle[titleKeys[i], default: []].append(b) }
        } else {
            for b in books { byTitle[titleKey(b.title), default: []].append(b) }
        }
        for (title, files) in byTitle {
            // Groupes stricts (même clé), réunis de proche en proche (voir `related`).
            var clusters = files.count == 1 ? [files] : components(files, title: title)
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

    /// Clé du titre qui partage la bibliothèque pour `identities(_:)` : seuls les fichiers de même clé
    /// peuvent être le même livre.
    public static func titleKey(_ title: String) -> String { Matching.key(Matching.withoutGenre(title)) }

    /// Groupes de fichiers d'un même titre, réunis tant que deux groupes sont liés (`related`) : ce sont les
    /// composantes connexes du graphe « même clé, même dossier de livre, auteur contenu dans l'autre ».
    /// Calculées par union-find, en comparant les ensembles de mots d'auteur distincts une seule fois
    /// (des centaines de « Mémoires » d'auteurs différents ne coûtent plus des secondes).
    static func components(_ files: [Book], title: String) -> [[Book]] {
        var parent = Array(files.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[rb] = ra }
        }
        var byKey: [String: Int] = [:], byFolder: [String: Int] = [:], byWords: [Set<String>: Int] = [:]
        for (i, b) in files.enumerated() {
            if let j = byKey[key(b)] { union(i, j) } else { byKey[key(b)] = i }
            if let dir = bookFolder(b) {
                if let j = byFolder[dir] { union(i, j) } else { byFolder[dir] = i }
            }
            if hasReliableAuthor(b, title: title) {
                for words in authorWordSets(b) {
                    if let j = byWords[words] { union(i, j) } else { byWords[words] = i }
                }
            }
        }
        // Un auteur contenu dans un autre (« Soljénitsyne » ⊂ « Alexandre Soljénitsyne ») : même livre.
        let sets = Array(byWords)
        for x in sets.indices {
            for y in sets.indices where y > x && (sets[x].key.isSubset(of: sets[y].key) || sets[y].key.isSubset(of: sets[x].key)) {
                union(sets[x].value, sets[y].value)
            }
        }
        var order: [Int] = [], members: [Int: [Book]] = [:]
        for (i, b) in files.enumerated() {
            let root = find(i)
            if members[root] == nil { order.append(root) }
            members[root, default: []].append(b)
        }
        return order.map { members[$0]! }
    }

    /// Règle de rapprochement appliquée par `components` (gardée telle quelle comme référence des tests).
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
