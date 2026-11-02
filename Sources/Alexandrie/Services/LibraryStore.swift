import AlexandrieCore
import AppKit
import Foundation
import Observation

/// État de la bibliothèque : dossier source (lecture seule), imports, index JSON.
@MainActor @Observable
final class LibraryStore {
    let directories = AppDirectories()
    let covers: CoverStore
    private(set) var books: [Book] = [] {
        didSet { positions = nil; titleIndex = nil; publisherList = nil; duplicateIDs = nil; identityMap = nil }
    }
    private(set) var rootURL: URL?
    private(set) var isScanning = false
    private(set) var progress: (done: Int, total: Int)?
    /// Taille des couvertures et des conversions, calculée à la demande (réglages).
    private(set) var cacheSize: (covers: Int64, conversions: Int64)?
    var lastError: String?

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var rescanPending = false
    /// Index reconstruits à la demande après chaque changement de `books`.
    @ObservationIgnored private var positions: [Book.ID: Int]?
    @ObservationIgnored private var titleIndex: [String: [Int]]?
    @ObservationIgnored private var publisherList: [String]?
    @ObservationIgnored private var duplicateIDs: Set<Book.ID>?
    @ObservationIgnored private var identityMap: [Book.ID: String]?
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
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDuplicatesSetting() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        Task { await rescan() }
    }

    var hasLibrary: Bool { rootURL != nil || !books.isEmpty }

    // MARK: - Copies en double (masquées, jamais supprimées)

    /// Affiche toutes les copies d'un même livre dans un même format (réglage) ; par défaut une seule est gardée.
    var showDuplicates: Bool {
        get { access(keyPath: \.showDuplicates); return UserDefaults.standard.bool(forKey: Self.showDuplicatesKey) }
        set {
            lastShowDuplicates = newValue
            withMutation(keyPath: \.showDuplicates) { UserDefaults.standard.set(newValue, forKey: Self.showDuplicatesKey) }
        }
    }
    static let showDuplicatesKey = "showDuplicates"
    @ObservationIgnored private var lastShowDuplicates = UserDefaults.standard.bool(forKey: "showDuplicates")

    /// Le menu Présentation modifie le réglage directement (les menus ne suivent pas l'état de l'app) :
    /// la bibliothèque se met à jour quand il change.
    private func syncDuplicatesSetting() {
        let value = UserDefaults.standard.bool(forKey: Self.showDuplicatesKey)
        guard value != lastShowDuplicates else { return }
        lastShowDuplicates = value
        withMutation(keyPath: \.showDuplicates) {}
    }

    /// « Rassembler les doublons » (menu Présentation, réglages) : une seule copie par livre et par format.
    var groupDuplicates: Bool {
        get { !showDuplicates }
        set { showDuplicates = !newValue }
    }

    /// Identité de chaque fichier (voir `BookGroups.identities`) : réunit les fichiers d'un même livre
    /// même quand leurs auteurs sont écrits différemment ou manquent.
    var identities: [Book.ID: String] {
        let books = self.books
        if identityMap == nil { identityMap = BookGroups.identities(books) }
        return identityMap ?? [:]
    }

    func identity(of book: Book) -> String { identities[book.id] ?? BookGroups.key(book) }

    /// Fichiers masqués : même livre, même format qu'un fichier gardé (voir `BookGroups.duplicates`).
    var hiddenDuplicates: Set<Book.ID> {
        let books = self.books
        if duplicateIDs == nil {
            duplicateIDs = BookGroups.duplicates(books.filter { $0.trashedAt == nil }, identities: identities)
        }
        return duplicateIDs ?? []
    }

    /// Livres affichés, comptés et vérifiés en ligne. L'envoi et la reconnaissance des livres
    /// de la Kindle passent, eux, par tous les fichiers.
    var visibleBooks: [Book] {
        let hidden = showDuplicates ? [] : hiddenDuplicates
        return books.filter { $0.trashedAt == nil && !hidden.contains($0.id) }
    }

    // MARK: - Corbeille d'Alexandrie

    /// Fichiers dans la corbeille : masqués partout ailleurs, restaurables.
    var trashedBooks: [Book] { books.filter { $0.trashedAt != nil } }

    /// Met le livre entier à la corbeille (tous ses fichiers, copies masquées comprises) ; rien ne bouge sur le disque.
    func moveToTrash(_ book: Book) {
        // Identités lues une fois : chaque modification de `books` invalide leur cache.
        let ids = identities, key = identity(of: book), now = Date()
        for i in books.indices where books[i].trashedAt == nil && ids[books[i].id] == key {
            books[i].trashedAt = now
            books[i].pendingSendAt = nil
        }
        save()
    }

    func restoreFromTrash(_ book: Book) {
        let ids = identities, key = identity(of: book)
        for i in books.indices where books[i].trashedAt != nil && ids[books[i].id] == key {
            books[i].trashedAt = nil
        }
        save()
    }

    /// Fichiers d'un livre de la corbeille.
    func trashedFiles(of book: Book) -> [Book] {
        let ids = identities, key = identity(of: book)
        return books.filter { $0.trashedAt != nil && ids[$0.id] == key }
    }

    /// Place les fichiers dans la Corbeille de macOS et les retire de la bibliothèque.
    /// Un fichier qui ne peut pas être déplacé reste dans la corbeille d'Alexandrie.
    func deletePermanently(_ files: [Book]) async {
        let files = files.filter { $0.trashedAt != nil }
        guard !files.isEmpty else { return }
        let result = await Task.detached(priority: .userInitiated) { LibraryTrash.empty(files) }.value
        let removed = Set(result.removed)
        books.removeAll { removed.contains($0.id) }
        save()
        if let first = result.failures.first {
            lastError = "\(result.failures.count) fichier(s) n'ont pas pu être placés dans la Corbeille de macOS "
                + "et restent dans celle d'Alexandrie. Premier : « \((first.path as NSString).lastPathComponent) » — \(first.reason)"
        }
    }

    func emptyTrash() async {
        await deletePermanently(trashedBooks)
    }

    /// Copies masquées d'un livre (même clé de regroupement).
    func hiddenCopies(of book: Book) -> [Book] {
        guard !showDuplicates else { return [] }
        let hidden = hiddenDuplicates, ids = identities, key = identity(of: book)
        return books.filter { hidden.contains($0.id) && ids[$0.id] == key }
    }

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
        // Dossier injoignable (disque débranché, partage absent) : ses livres sont gardés tels quels.
        let unreachable = self.roots.filter { !FileManager.default.fileExists(atPath: $0.path) }.map { $0.path + "/" }
        let roots = self.roots.filter { !unreachable.contains($0.path + "/") }
        let isOffline: (Book) -> Bool = { b in unreachable.contains { b.path.hasPrefix($0) } }
        let offline = books.filter(isOffline)
        let known = books.filter { !isOffline($0) }
        let importsPath = directories.imports.path
        let plan = await Task.detached {
            LibraryMerge.plan(files: FolderScanner.scan(roots), known: known, importsPath: importsPath)
        }.value
        // Publie tout de suite les livres connus (avec les retouches faites pendant le parcours), puis complète au fil de l'extraction.
        let current = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        books = offline.map { current[$0.id] ?? $0 } + plan.kept.map { b in
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
        // Une copie en double d'un livre déjà connu n'est pas revérifiée en ligne.
        let duplicates = hiddenDuplicates
        checkCatalog(newBooks.filter { !duplicates.contains($0) })
        if unreachable.isEmpty { await purgeStorage() }
    }

    // MARK: - Stockage de l'app

    private func purgeStorage() async {
        let books = self.books
        let directories = self.directories
        _ = await Task.detached(priority: .background) {
            StorageMaintenance.purge(keeping: books, directories: directories)
        }.value
        if cacheSize != nil { await refreshCacheSize() }
    }

    func refreshCacheSize() async {
        let directories = self.directories
        cacheSize = await Task.detached(priority: .utility) {
            (StorageMaintenance.size(of: directories.covers), StorageMaintenance.size(of: directories.conversions))
        }.value
    }

    /// Les conversions sont refaites au prochain envoi.
    func clearConversions() async {
        let directory = directories.conversions
        await Task.detached(priority: .utility) { StorageMaintenance.clear(directory) }.value
        await refreshCacheSize()
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

    var pendingSuggestionCount: Int { visibleBooks.filter { !$0.catalogSuggestions.isEmpty }.count }

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
                    catalogErrors[id] = CatalogClient.describe(error)
                }
                catalogChecking = nil
                // Ménage les services publics : une requête par seconde au plus.
                try? await Task.sleep(for: .seconds(1))
            }
            catalogTask = nil
        }
    }

    func checkUncheckedBooks() {
        checkCatalog(visibleBooks.filter { $0.catalogCheckedAt == nil }.map(\.id))
    }

    // MARK: - Lecture des couvertures (vérification des propositions)

    /// Texte lu sur les couvertures, par empreinte ; rempli à la demande.
    private(set) var coverTexts: [String: CoverText] = [:]
    /// Couvertures en cours de lecture (la première lecture charge le modèle de reconnaissance de macOS).
    private(set) var coverReading: Set<String> = []

    func readCover(_ book: Book) async {
        let key = book.fingerprint
        guard book.hasCover, coverTexts[key] == nil, coverReading.insert(key).inserted,
              let url = coverURL(book) else { return }
        defer { coverReading.remove(key) }
        if let text = await Task.detached(priority: .utility, operation: { try? CoverText.recognize(imageAt: url) }).value {
            coverTexts[key] = text
        }
    }

    /// Éditeurs présents dans la bibliothèque : aident à reconnaître celui écrit sur une couverture.
    var publisherNames: [String] {
        let books = self.books
        if publisherList == nil {
            publisherList = Array(Set(books.compactMap(\.publisher)))
        }
        return publisherList ?? []
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
        guard let id, let i = position(of: id) else { return nil }
        return books[i]
    }

    private func position(of id: Book.ID) -> Int? {
        // Lire `books` enregistre la dépendance des vues, même quand l'index est déjà construit.
        let books = self.books
        if positions == nil {
            positions = Dictionary(books.indices.map { (books[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return positions?[id]
    }

    /// Livres dont le titre normalisé (cf. `KindleMonitor.normalize`) est `key`.
    func books(titleKey key: String) -> [Book] {
        let books = self.books
        if titleIndex == nil {
            titleIndex = Dictionary(grouping: books.indices) { KindleMonitor.normalize(books[$0].title) }
        }
        return titleIndex?[key]?.map { books[$0] } ?? []
    }

    func update(_ book: Book) {
        update(book, propagatingTo: [])
    }

    /// Enregistre un livre et recopie ses informations corrigées sur les autres fichiers du même livre,
    /// pour que le groupe (même titre, mêmes auteurs) reste uni.
    func update(_ book: Book, propagatingTo siblings: [Book.ID]) {
        guard let i = position(of: book.id) else { return }
        let siblingPositions = siblings.filter { $0 != book.id }.compactMap(position(of:))
        // L'attente d'envoi et la corbeille ne changent que par leurs propres actions, jamais par une fiche ouverte avant.
        var book = book
        book.pendingSendAt = books[i].pendingSendAt
        book.trashedAt = books[i].trashedAt
        book.shelves = books[i].shelves
        books[i] = book
        for j in siblingPositions {
            books[j].edits = book.edits
            books[j].tags = book.tags
        }
        save()
    }

    // MARK: - Étagères des liseuses

    /// Livres d'une étagère (copies en double et corbeille exclues).
    func shelfBooks(_ reader: Reader.ID) -> [Book] {
        visibleBooks.filter { $0.shelfIDs.contains(reader) }
    }

    /// Nombre de livres (et non de fichiers) d'une étagère.
    func shelfCount(_ reader: Reader.ID) -> Int {
        let ids = identities
        return Set(shelfBooks(reader).map { ids[$0.id] ?? BookGroups.key($0) }).count
    }

    /// Une étagère concerne le livre entier : tous ses fichiers, copies masquées comprises.
    func addToShelf(_ books: [Book], reader: Reader.ID) {
        setShelf(books, reader: reader, on: true)
    }

    /// Retire de l'étagère sans rien supprimer, ni de la bibliothèque ni de la Kindle.
    func removeFromShelf(_ books: [Book], reader: Reader.ID) {
        setShelf(books, reader: reader, on: false)
    }

    /// Liseuse oubliée : son étagère disparaît.
    func clearShelf(_ reader: Reader.ID) {
        for i in books.indices where books[i].shelfIDs.contains(reader) {
            books[i].shelves?.remove(reader)
        }
        save()
    }

    private func setShelf(_ selection: [Book], reader: Reader.ID, on: Bool) {
        let ids = identities
        let keys = Set(selection.map { ids[$0.id] ?? BookGroups.key($0) })
        var changed = false
        for i in books.indices where keys.contains(ids[books[i].id] ?? BookGroups.key(books[i]))
            && books[i].shelfIDs.contains(reader) != on {
            var shelves = books[i].shelfIDs
            if on { shelves.insert(reader) } else { shelves.remove(reader) }
            books[i].shelves = shelves.isEmpty ? nil : shelves
            changed = true
        }
        if changed { save() }
    }

    // MARK: - File d'envoi (Kindle débranchée)

    /// Livres à envoyer dès que la Kindle sera branchée, dans l'ordre où ils ont été demandés.
    var pendingSends: [Book] {
        books.filter { $0.pendingSendAt != nil && $0.trashedAt == nil }.sorted { $0.pendingSendAt! < $1.pendingSendAt! }
    }

    func queueForKindle(_ books: [Book]) {
        let now = Date()
        setPending(books.filter { $0.canSendToKindle && $0.trashedAt == nil }.map(\.id)) { $0 ?? now }
    }

    func removeFromKindleQueue(_ ids: [Book.ID]) {
        setPending(ids) { _ in nil }
    }

    /// Seul l'état d'envoi est modifié : les livres reçus peuvent être des fichiers principaux de groupe
    /// complétés par les autres fichiers, qu'il ne faut pas enregistrer tels quels.
    private func setPending(_ ids: [Book.ID], _ change: (Date?) -> Date?) {
        let targets = ids.compactMap(position(of:))
        guard !targets.isEmpty else { return }
        for i in targets { books[i].pendingSendAt = change(books[i].pendingSendAt) }
        save()
    }

    /// Retire un livre de la liste « Envoyés à la Kindle » (tous ses fichiers) ; rien n'est supprimé.
    /// Le nom du fichier envoyé est gardé : il sert à reconnaître le livre s'il est encore sur la Kindle.
    func forgetSent(_ book: Book) {
        let ids = identities, key = identity(of: book)
        var changed = false
        for i in books.indices where books[i].lastSentAt != nil && ids[books[i].id] == key {
            books[i].lastSentAt = nil
            changed = true
        }
        if changed { save() }
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

    func coverURL(_ book: Book) -> URL? {
        book.hasCover ? covers.url(for: book.fingerprint) : nil
    }
}
