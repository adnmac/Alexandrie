import AlexandrieCore
import AppKit
import Foundation
import Observation

/// État de la bibliothèque : dossier source (lecture seule), imports, index JSON.
@MainActor @Observable
final class LibraryStore {
    let directories = AppDirectories()
    let covers: CoverStore
    private(set) var books: [Book] = []
    private(set) var rootURL: URL?
    private(set) var isScanning = false
    private(set) var progress: (done: Int, total: Int)?
    var lastError: String?

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// File série : les écritures de l'index se font dans l'ordre, hors du thread principal.
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "alexandrie.index", qos: .utility)
    private static let bookmarkKey = "libraryFolderBookmark"

    init() {
        covers = CoverStore(directory: directories.covers)
        do {
            books = try LibraryIndex.load(directories.index)
        } catch {
            // Index illisible : mis de côté plutôt qu'écrasé, la bibliothèque est réindexée.
            let moved = try? LibraryIndex.quarantine(directories.index)
            lastError = "Index de la bibliothèque illisible (\(error.localizedDescription)). "
                + (moved.map { "Il a été mis de côté sous « \($0.lastPathComponent) »." } ?? "")
        }
        // Séries enregistrées avec leur numéro (« Brunetti 8 ») : nom et numéro séparés une fois pour toutes.
        var changed = false
        for i in books.indices {
            let (name, index) = SeriesNames.normalized(books[i].series, books[i].seriesIndex)
            if name != books[i].series || index != books[i].seriesIndex {
                (books[i].series, books[i].seriesIndex) = (name, index)
                changed = true
            }
        }
        if changed { save() }
        rootURL = Self.restoreBookmark()
        startWatching()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        Task { await rescan() }
    }

    var hasLibrary: Bool { rootURL != nil || !books.isEmpty }

    // MARK: - Dossier source

    func chooseFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        rootURL = url
        books.removeAll { !$0.isImported }
        startWatching()
        Task { await rescan() }
    }

    private static func restoreBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        // Dossier déplacé ou renommé : le signet est renouvelé pour rester valable.
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    private var roots: [URL] {
        [rootURL, directories.imports].compactMap { $0 }
    }

    private func startWatching() {
        watcher = FolderWatcher(paths: roots.map(\.path)) { [weak self] in
            Task { @MainActor in await self?.rescan() }
        }
    }

    // MARK: - Indexation

    /// Rescan incrémental : seuls les fichiers nouveaux ou modifiés sont relus.
    func rescan() async {
        guard !isScanning else {
            rescanPending = true
            return
        }
        isScanning = true
        defer {
            isScanning = false
            progress = nil
            if rescanPending {
                rescanPending = false
                Task { await rescan() }
            }
        }
        let roots = self.roots
        let known = books
        let importsPath = directories.imports.path
        let plan = await Task.detached {
            LibraryMerge.plan(files: FolderScanner.scan(roots), known: known, importsPath: importsPath)
        }.value
        // Publie tout de suite les livres connus (avec les retouches faites pendant le parcours), puis complète au fil de l'extraction.
        let current = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        books = plan.kept.map { b in
            guard var edited = current[b.id] else { return b }
            edited.addedAt = b.addedAt
            return edited
        }
        progress = plan.changed.isEmpty ? nil : (0, plan.changed.count)
        let covers = self.covers
        var newBooks: [Book.ID] = []
        for (i, item) in plan.changed.enumerated() {
            let f = item.file
            let imported = f.url.path.hasPrefix(importsPath)
            var book = await Task.detached(priority: .utility) {
                FolderScanner.makeBook(f, imported: imported, coverStore: covers)
            }.value
            if let previous = item.previous {
                LibraryMerge.carryOver(from: previous, to: &book)
            } else if autoCheckCatalog {
                newBooks.append(book.id)
            }
            books.append(book)
            progress = (i + 1, plan.changed.count)
        }
        save()
        checkCatalog(newBooks)
    }

    // MARK: - Vérification en ligne (BnF, Open Library)

    @ObservationIgnored private let catalogClient = CatalogClient()
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    private(set) var catalogQueue: [Book.ID] = []
    private(set) var catalogChecking: Book.ID?
    private(set) var catalogErrors: [Book.ID: String] = [:]

    /// Vérifie automatiquement les livres qui apparaissent dans la bibliothèque.
    var autoCheckCatalog: Bool {
        get { access(keyPath: \.autoCheckCatalog); return UserDefaults.standard.object(forKey: "catalogAutoCheck") as? Bool ?? true }
        set { withMutation(keyPath: \.autoCheckCatalog) { UserDefaults.standard.set(newValue, forKey: "catalogAutoCheck") } }
    }

    var pendingSuggestionCount: Int { books.filter { !$0.catalogSuggestions.isEmpty }.count }

    func checkCatalog(_ ids: [Book.ID]) {
        let fresh = ids.filter { !catalogQueue.contains($0) && catalogChecking != $0 }
        guard !fresh.isEmpty else { return }
        catalogQueue += fresh
        guard catalogTask == nil else { return }
        catalogTask = Task {
            while !catalogQueue.isEmpty {
                let id = catalogQueue.removeFirst()
                guard let book = book(id: id) else { continue }
                catalogChecking = id
                catalogErrors[id] = nil
                do {
                    let record = try await catalogClient.lookup(book.edits)
                    if var current = self.book(id: id) {
                        if record != current.catalogRecord { current.catalogDismissed = nil }
                        current.catalogRecord = record
                        current.catalogCheckedAt = Date()
                        update(current)
                    }
                } catch {
                    // Hors ligne ou service indisponible : le livre pourra être revérifié plus tard.
                    catalogErrors[id] = "Vérification impossible : \(error.localizedDescription)"
                }
                catalogChecking = nil
                // Ménage les services publics : une requête par seconde au plus.
                try? await Task.sleep(for: .seconds(1))
            }
            catalogTask = nil
        }
    }

    func checkUncheckedBooks() {
        checkCatalog(books.filter { $0.catalogCheckedAt == nil }.map(\.id))
    }

    func applyCatalog(_ fields: Set<CatalogField>, to id: Book.ID) {
        guard var book = book(id: id), let record = book.catalogRecord else { return }
        var edits = book.edits
        CatalogComparison.apply(fields, from: record, to: &edits)
        book.edits = edits
        update(book)
    }

    func dismissCatalog(_ fields: Set<CatalogField>, for id: Book.ID) {
        guard var book = book(id: id) else { return }
        book.catalogDismissed = (book.catalogDismissed ?? []).union(fields)
        update(book)
    }

    /// Enregistrement différé : une saisie dans la fiche ne réécrit l'index qu'après une courte pause.
    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.write(sync: false)
        }
    }

    /// Écrit tout de suite un enregistrement en attente (fermeture de l'app).
    func saveNow() {
        if let pending = saveTask {
            pending.cancel()
            saveTask = nil
            write(sync: true)
        } else {
            writeQueue.sync {}  // laisse finir une écriture déjà lancée
        }
    }

    private func write(sync: Bool) {
        let books = self.books
        let url = directories.index
        let work: @Sendable () -> Void = { [weak self] in
            do {
                try LibraryIndex.save(books, to: url)
            } catch {
                let message = "Impossible d'enregistrer l'index : \(error.localizedDescription)"
                Task { @MainActor in self?.lastError = message }
            }
        }
        if sync { writeQueue.sync(execute: work) } else { writeQueue.async(execute: work) }
    }

    func book(id: Book.ID?) -> Book? {
        guard let id else { return nil }
        return books.first { $0.id == id }
    }

    func update(_ book: Book) {
        update(book, propagatingTo: [])
    }

    /// Enregistre un livre et recopie ses informations corrigées sur les autres fichiers du même livre,
    /// pour que le groupe (même titre, mêmes auteurs) reste uni.
    func update(_ book: Book, propagatingTo siblings: [Book.ID]) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i] = book
        for id in siblings where id != book.id {
            guard let j = books.firstIndex(where: { $0.id == id }) else { continue }
            books[j].edits = book.edits
            books[j].tags = book.tags
        }
        save()
    }

    // MARK: - Imports

    /// Copie les fichiers dans le dossier d'imports de l'app (le dossier source n'est jamais modifié).
    func importFiles(_ urls: [URL]) {
        var imported = 0
        for url in urls where BookFormat(url: url) != nil {
            var target = directories.imports.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = url.deletingPathExtension().lastPathComponent
                target = directories.imports.appendingPathComponent("\(base) (\(n)).\(url.pathExtension)")
                n += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: target)
                imported += 1
            } catch {
                lastError = "Import impossible de « \(url.lastPathComponent) » : \(error.localizedDescription)"
            }
        }
        if imported == 0 && lastError == nil {
            lastError = "Aucun fichier pris en charge (EPUB, MOBI, AZW3, AZW, PDF)."
        }
        Task { await rescan() }
    }

    /// Retire un livre importé (seuls les imports, propriété de l'app, peuvent être supprimés).
    func removeImported(_ book: Book) {
        guard book.isImported else { return }
        do {
            try FileManager.default.removeItem(at: book.url)
        } catch CocoaError.fileNoSuchFile {
            // Déjà absent : il suffit de le retirer de l'index.
        } catch {
            lastError = "Suppression impossible de « \(book.url.lastPathComponent) » : \(error.localizedDescription)"
            return
        }
        books.removeAll { $0.id == book.id }
        save()
    }

    func coverURL(_ book: Book) -> URL? {
        book.hasCover ? covers.url(for: book.fingerprint) : nil
    }
}
