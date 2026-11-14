import FolunaCore
import Foundation

/// Ce que la barre latérale affiche : compteurs de livres (les fichiers d'un même livre comptent pour un)
/// et listes des séries, genres, étiquettes, auteurs, formats. Calculé en un passage par `LibraryStore.summary`,
/// gardé jusqu'à la modification suivante : sans lui, chaque changement de page refaisait tout (plus d'une
/// seconde à 100 000 livres).
struct LibrarySummary: Sendable {
    var all = 0, favorites = 0, sent = 0, trash = 0, pending = 0, toReview = 0
    var formats: [(format: BookFormat, count: Int)] = []
    var series: [SeriesNames.Group] = []
    var genres: [GenreNames.Group] = []
    var tags: [TagNames.Group] = []
    var authors: [AuthorNames.Group] = []
    /// Livres par auteur (clé de regroupement).
    var authorCounts: [String: Int] = [:]
    /// Livres par étagère (identifiant de liseuse).
    var shelves: [String: Int] = [:]
    /// Livres par dossier de livres (chemin), quand il y en a plusieurs.
    var folderCounts: [String: Int] = [:]
    let folderPaths: [String]

    /// En attendant les identités (premier calcul en arrière-plan) : le nombre de fichiers, rien d'autre.
    init(waitingFor visible: [Book], folders: [String]) {
        folderPaths = folders
        all = visible.count
    }

    init(visible: [Book], all files: [Book], identities: [Book.ID: String], folders: [String]) {
        folderPaths = folders
        func identity(_ b: Book) -> String { identities[b.id] ?? BookGroups.key(b) }
        var all = Set<String>(), favorites = Set<String>(), sent = Set<String>(), review = 0
        var formatCounts: [BookFormat: Int] = [:]
        var perAuthor: [String: Set<String>] = [:], perShelf: [String: Set<String>] = [:], perFolder: [String: Set<String>] = [:]
        let prefixes = folders.count > 1 ? folders.map { ($0, LibraryFolders.prefix($0)) } : []
        for b in visible {
            let id = identity(b)
            all.insert(id)
            if b.isFavorite { favorites.insert(id) }
            if b.lastSentAt != nil { sent.insert(id) }
            if !b.catalogSuggestions.isEmpty { review += 1 }
            formatCounts[b.format, default: 0] += 1
            for key in AuthorNames.keys(of: b) { perAuthor[key, default: []].insert(id) }
            for shelf in b.shelfIDs { perShelf[shelf, default: []].insert(id) }
            if !b.isImported {
                for (path, prefix) in prefixes where b.path.hasPrefix(prefix) { perFolder[path, default: []].insert(id) }
            }
        }
        self.all = all.count
        self.favorites = favorites.count
        self.sent = sent.count
        toReview = review
        trash = Set(files.lazy.filter { $0.trashedAt != nil }.map(identity)).count
        pending = Set(files.lazy.filter { $0.trashedAt == nil && $0.isPendingSend }.map(identity)).count
        formats = BookFormat.allCases.compactMap { f in formatCounts[f].map { (f, $0) } }
        series = SeriesNames.groups(visible)
        genres = GenreNames.groups(visible, identities: identities)
        tags = TagNames.groups(visible, identities: identities)
        authors = AuthorNames.groups(visible)
        authorCounts = perAuthor.mapValues(\.count)
        shelves = perShelf.mapValues(\.count)
        folderCounts = perFolder.mapValues(\.count)
    }
}
