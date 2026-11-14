import FolunaCore
import Foundation

/// Liste de livres d'une page : filtre de la page, recherche dans les fiches, tri, regroupement des fichiers
/// d'un même livre. Sans état ni accès à l'interface : sur une grande bibliothèque, `ContentView` la calcule
/// hors du thread principal (filtrer 100 000 livres à chaque lettre tapée prenait près d'une seconde).
struct LibraryListing: Sendable {
    /// Au-delà de ce nombre de livres, la liste est calculée en arrière-plan ; en deçà, directement
    /// (quelques dizaines de ms au plus, et l'affichage ne passe jamais par une liste périmée).
    static let directLimit = 5000

    var books: [Book]
    var page: SidebarItem?
    var query: String
    var scope: SearchScope
    var sort: SortOrder
    /// Titres normalisés des livres dont une note Kindle contient la recherche.
    var withNotes: Set<String>
    var identities: [Book.ID: String]
    var ranks: SortRanks
    var now = Date()

    func groups() -> [BookGroup] { BookGroups.make(filtered(), identities: identities) }

    func filtered() -> [Book] {
        var list = books
        switch page {
        case .recent:
            let limit = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
            list = list.filter { $0.addedAt >= limit }
        case .sent: list = list.filter { $0.lastSentAt != nil }
        case .favorites: list = list.filter(\.isFavorite)
        case .pending: list = list.filter(\.isPendingSend)
        case .shelf(let reader): list = list.filter { $0.shelfIDs.contains(reader) }
        case .genre(let key): list = list.filter { $0.genre.map(GenreNames.key) == key }
        case .tag(let key): list = list.filter { TagNames.has($0, key: key) }
        case .toReview: list = list.filter { !$0.catalogSuggestions.isEmpty }
        case .series(let key):
            // Classement par numéro de tome, les livres sans numéro à la fin.
            return list.filter { $0.series.map(SeriesNames.key) == key }
                .sorted { ($0.seriesIndex ?? .infinity, $0.title) < ($1.seriesIndex ?? .infinity, $1.title) }
        case .format(let f): list = list.filter { $0.format == f }
        case .author(let key): list = list.filter { AuthorNames.keys(of: $0).contains(key) }
        case .folder(let path):
            let prefix = LibraryFolders.prefix(path)
            list = list.filter { !$0.isImported && $0.path.hasPrefix(prefix) }
        default: break
        }
        let query = query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty && scope == .titles {
            // Aussi les livres dont une note ou un surlignage Kindle contient le texte cherché.
            list = list.filter { b in
                [b.title, b.authorLine, b.series ?? "", b.genre ?? "", b.labels.joined(separator: " "), b.tags.joined(separator: " ")]
                    .contains { $0.localizedStandardContains(query) }
                    || (!withNotes.isEmpty && withNotes.contains(ShelfSync.normalize(b.title)))
            }
        }
        // « Ajoutés récemment » : toujours les derniers ajouts en tête, quel que soit le tri choisi.
        if page == .recent { return SortRanks.newestFirst(list, date: \.addedAt) }
        switch sort {
        case .title: return SortRanks.ordered(list, ranks: ranks.title, key: \.title)
        case .author: return SortRanks.ordered(list, ranks: ranks.author, key: \.authorLine)
        case .added: return SortRanks.newestFirst(list, date: \.addedAt)
        }
    }
}
