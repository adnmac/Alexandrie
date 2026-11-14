import Foundation

/// Rang de chaque fichier dans l'ordre des titres et dans l'ordre des auteurs (`localizedStandardCompare`,
/// comme le Finder). Calculé hors du thread principal après chaque modification de la bibliothèque : la liste
/// affichée n'a plus qu'à ranger ses livres par rang (comparaison d'entiers) au lieu de comparer des chaînes,
/// 1,5 s à 100 000 livres.
public struct SortRanks: Sendable {
    public var title: [Book.ID: Int] = [:]
    public var author: [Book.ID: Int] = [:]
    /// Augmente à chaque nouveau calcul : les listes gardées savent qu'il faut se remettre en ordre.
    public var generation = 0

    /// Sous ce nombre de livres, le tri direct est assez rapide (quelques dizaines de ms) et toujours exact.
    public static let directSortLimit = 2000
    /// Au-delà de ce nombre de livres sans rang (premier calcul pas encore fini), ils restent dans l'ordre
    /// d'arrivée jusqu'au calcul suivant plutôt que de bloquer le thread principal.
    public static let pendingLimit = 5000

    public init() {}

    public init(_ books: [Book], generation: Int = 0) {
        title = Self.rank(books, key: \.title)
        author = Self.rank(books, key: \.authorLine)
        self.generation = generation
    }

    static func rank(_ books: [Book], key: (Book) -> String) -> [Book.ID: Int] {
        let keyed = books.map { (id: $0.id, key: key($0)) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        var out: [Book.ID: Int] = [:]
        out.reserveCapacity(keyed.count)
        for (i, item) in keyed.enumerated() { out[item.id] = i }
        return out
    }

    /// `list` du plus récent au plus ancien selon `date` (ajout), en triant des indices.
    public static func newestFirst(_ list: [Book], date: (Book) -> Date) -> [Book] {
        list.indices.map { (date(list[$0]), $0) }.sorted { $0.0 > $1.0 }.map { list[$0.1] }
    }

    /// `list` dans l'ordre de `key`. Les livres classés suivent leur rang ; les autres (ajoutés depuis le
    /// dernier calcul) sont insérés à leur place par recherche dichotomique. Un livre retouché depuis garde
    /// son ancien rang jusqu'au calcul suivant, une fraction de seconde plus tard.
    public static func ordered(_ list: [Book], ranks: [Book.ID: Int], key: (Book) -> String) -> [Book] {
        func before(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        if list.count <= directSortLimit { return list.sorted { before(key($0), key($1)) } }
        // Des indices plutôt que des `Book` : un tri déplace ses éléments, et un `Book` est gros.
        var ranked: [(rank: Int, index: Int)] = [], pending: [Book] = []
        ranked.reserveCapacity(list.count)
        for (i, b) in list.enumerated() {
            if let r = ranks[b.id] { ranked.append((r, i)) } else { pending.append(b) }
        }
        ranked.sort { $0.rank < $1.rank }
        let sorted = ranked.map { list[$0.index] }
        guard !pending.isEmpty else { return sorted }
        guard pending.count <= pendingLimit else { return sorted + pending }
        pending.sort { before(key($0), key($1)) }
        // Place de chaque livre sans rang : premier livre classé qui le suit.
        var out: [Book] = []
        out.reserveCapacity(list.count)
        var next = 0
        for b in pending {
            let k = key(b)
            var lo = next, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if before(key(sorted[mid]), k) { lo = mid + 1 } else { hi = mid }
            }
            out.append(contentsOf: sorted[next..<lo])
            out.append(b)
            next = lo
        }
        out.append(contentsOf: sorted[next...])
        return out
    }
}
