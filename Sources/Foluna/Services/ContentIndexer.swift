import FolunaCore
import Foundation
import Observation

/// Livre trouvé par son contenu (S-082) : le nombre de passages et quelques extraits.
struct ContentResult: Identifiable, Sendable {
    let book: Book
    let count: Int
    let snippets: [ContentSearch.Snippet]
    var id: Book.ID { book.id }
}

/// Indexe en arrière-plan le texte des livres de la bibliothèque (S-081), puis y cherche (S-082).
/// Le texte de chaque livre est gardé dans `Texte/` pour les extraits ; l'index SearchKit dans `Recherche/`.
@MainActor @Observable
final class ContentIndexer {
    /// Empreintes des livres déjà indexés (ou illisibles, pour ne pas les relire à chaque lancement).
    private(set) var indexed: Set<String>
    /// Livres qui restent à lire.
    private(set) var remaining = 0
    var isIndexing: Bool { remaining > 0 }
    @ObservationIgnored private let directories: AppDirectories
    @ObservationIgnored private let index: ContentIndex?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// File d'attente, le prochain livre à la fin (`popLast` : retirer le premier d'un grand tableau recopie tout).
    @ObservationIgnored private var queued: [Book] = []

    init(directories: AppDirectories) {
        self.directories = directories
        index = try? ContentIndex(url: directories.contentIndex)
        let saved = (try? Data(contentsOf: directories.contentIndexState))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        // Sans index (fichier abîmé, recréé vide), tout est à refaire.
        indexed = FileManager.default.fileExists(atPath: directories.contentIndex.path) ? Set(saved) : []
    }

    /// Met l'index à jour avec la bibliothèque, un seul fichier par livre (`BookText.filesToIndex`) : les livres
    /// nouveaux sont lus en arrière-plan ; les fichiers qui ne sont plus retenus (livre disparu, autre fichier
    /// préféré) quittent l'index et leur texte est effacé.
    func refresh(books: [Book], identities: [Book.ID: String]) {
        guard let index else { return }
        let chosen = BookText.filesToIndex(books, identities: identities)
        let current = Dictionary(chosen.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        let gone = indexed.subtracting(current.keys)
        if !gone.isEmpty {
            for fingerprint in gone {
                index.remove(id: fingerprint)
                try? FileManager.default.removeItem(at: BookText.url(of: fingerprint, in: directories))
            }
            indexed.subtract(gone)
            index.flush()
            saveState()
        }
        queued.removeAll { current[$0.fingerprint] == nil }
        let waiting = Set(queued.map(\.fingerprint))
        // Les nouveaux passent après ceux qui attendent déjà, par ordre de titre.
        queued.insert(contentsOf: current.values.filter { !indexed.contains($0.fingerprint) && !waiting.contains($0.fingerprint) }
            .sorted { $0.title > $1.title }, at: 0)
        remaining = queued.count
        guard task == nil, !queued.isEmpty else { return }
        task = Task { [weak self] in await self?.work() }
    }

    /// Lit les livres un par un, à basse priorité. L'index et la liste des livres indexés sont écrits hors du
    /// thread principal, tous les 50 livres ou toutes les 5 secondes (à chaque livre, l'écriture finissait par
    /// occuper le thread principal plus que tout le reste sur une grande bibliothèque).
    private func work() async {
        guard let index else { return }
        let directories = directories
        var sinceFlush = 0
        var lastFlush = ContinuousClock.now
        while let book = queued.popLast() {
            await Task.detached(priority: .background) {
                guard BookText.canExtract(book), let text = try? BookText.extract(book) else { return }
                try? text.save(to: BookText.url(of: book.fingerprint, in: directories))
                index.add(id: book.fingerprint, text: text.joined)
            }.value
            indexed.insert(book.fingerprint)
            remaining = queued.count
            sinceFlush += 1
            if sinceFlush >= 50 || ContinuousClock.now - lastFlush > .seconds(5) || queued.isEmpty {
                let snapshot = indexed, state = directories.contentIndexState
                await Task.detached(priority: .background) {
                    index.flush()
                    Self.write(snapshot, to: state)
                }.value
                sinceFlush = 0
                lastFlush = .now
            }
        }
        task = nil
    }

    /// Attend la fin de l'indexation en cours (selftest).
    func waitUntilIdle(timeout: TimeInterval = 120) async {
        let end = Date().addingTimeInterval(timeout)
        while isIndexing && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Livres dont le texte contient la recherche, ceux qui en ont le plus de passages d'abord. L'index ignore
    /// majuscules et accents ; en écriture `exact` (S-084), seuls restent les livres où elle est écrite à l'identique.
    func search(_ query: String, in books: [Book], exact: Bool = false, limit: Int = 60) async -> [ContentResult] {
        guard let index, !ContentSearch.terms(query).isEmpty else { return [] }
        let byFingerprint = Dictionary(books.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        let directories = directories
        return await Task.detached(priority: .userInitiated) {
            let found = index.search(query).compactMap { byFingerprint[$0] }.prefix(limit)
            return found.compactMap { book -> ContentResult? in
                guard let text = BookText.load(BookText.url(of: book.fingerprint, in: directories)) else { return nil }
                let match = ContentSearch.matches(in: text, query: query, exact: exact)
                return match.count == 0 ? nil : ContentResult(book: book, count: match.count, snippets: match.snippets)
            }
            .sorted { $0.count > $1.count }
        }.value
    }

    /// Tous les passages d'un livre pour une recherche (S-085), dans l'ordre : texte gardé, ou lu à défaut.
    func passages(of book: Book, query: String, exact: Bool) async -> [ContentSearch.Snippet] {
        let directories = directories
        return await Task.detached(priority: .userInitiated) {
            let text = BookText.load(BookText.url(of: book.fingerprint, in: directories)) ?? (try? BookText.extract(book))
            guard let text else { return [] }
            return ContentSearch.matches(in: text, query: query, limit: .max, context: 60, exact: exact).snippets
        }.value
    }

    private func saveState() { Self.write(indexed, to: directories.contentIndexState) }

    nonisolated private static func write(_ indexed: Set<String>, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(indexed.sorted()).write(to: url, options: .atomic)
    }
}
