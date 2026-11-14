import FolunaCore
import AppKit
import Foundation
import Observation

/// État de la bibliothèque : dossiers de livres (lecture seule), imports, index JSON.
@MainActor @Observable
final class LibraryStore {
    let directories = AppDirectories()
    let covers: CoverStore
    private(set) var books: [Book] = [] {
        didSet {
            positions = nil; titleIndex = nil; publisherList = nil; duplicateIDs = nil; identityMap = nil
            visibleCache = nil; summaryCache = nil
            generation &+= 1
        }
    }
    /// Dossiers de livres, dans l'ordre d'ajout (voir `LibraryFolders`).
    private(set) var folders: [LibraryFolders.Entry] = []
    /// Dossiers introuvables au dernier parcours (disque débranché) : leurs livres restent, indisponibles.
    private(set) var unavailableFolders: Set<String> = []
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
    @ObservationIgnored private var visibleCache: [Book]?
    @ObservationIgnored private var summaryCache: LibrarySummary?
    /// Augmente à chaque modification de `books` : les vues s'en servent pour garder leurs listes calculées.
    @ObservationIgnored private(set) var generation = 0
    /// Identités tenues à jour titre par titre (voir `identities`).
    @ObservationIgnored private var identityCache = IdentityCache()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// File série : les écritures de l'index se font dans l'ordre, hors du thread principal.
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "foluna.index", qos: .utility)
    /// Signet du dossier unique d'avant M7, repris une fois dans `folders.json`.
    private static let legacyBookmarkKey = "libraryFolderBookmark"

    init() {
        covers = CoverStore(directory: directories.covers)
        do {
            books = try LibraryIndex.load(directories.index)
            // Copie du jour, faite avant tout changement : on peut revenir à l'état du matin.
            _ = try? IndexBackups.backUpToday(directories.index, to: directories.backups)
        } catch {
            // Index illisible : mis de côté plutôt qu'écrasé, la bibliothèque est réindexée.
            let moved = try? LibraryIndex.quarantine(directories.index)
            lastError = String(localized: "Index de la bibliothèque illisible (\(error.localizedDescription)). ")
                + (moved.map { String(localized: "Il a été mis de côté sous « \($0.lastPathComponent) ».") } ?? "")
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
        loadFolders()
        startWatching()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDuplicatesSetting() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        // Disque branché ou débranché : un dossier de livres revient ou devient indisponible.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshFolders()
                    Task { await self.rescan() }
                }
            }
        }
        Task { await rescan() }
    }

    var hasLibrary: Bool { !folders.isEmpty || !books.isEmpty }

    // MARK: - Copies en double (masquées, jamais supprimées)

    /// Affiche toutes les copies d'un même livre dans un même format (réglage) ; par défaut une seule est gardée.
    var showDuplicates: Bool {
        get { access(keyPath: \.showDuplicates); return UserDefaults.standard.bool(forKey: Self.showDuplicatesKey) }
        set {
            lastShowDuplicates = newValue
            visibleCache = nil; summaryCache = nil; generation &+= 1
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
        visibleCache = nil; summaryCache = nil; generation &+= 1
        withMutation(keyPath: \.showDuplicates) {}
    }

    /// « Rassembler les doublons » (menu Présentation, réglages) : une seule copie par livre et par format.
    var groupDuplicates: Bool {
        get { !showDuplicates }
        set { showDuplicates = !newValue }
    }

    /// Identité de chaque fichier (voir `BookGroups.identities`) : réunit les fichiers d'un même livre
    /// même quand leurs auteurs sont écrits différemment ou manquent.
    /// Toute modification de `books` vide `identityMap` ; `identityCache` ne recalcule ensuite que les titres
    /// touchés (aucun pour une étiquette, un favori ou la corbeille ; l'ancien et le nouveau pour un titre corrigé).
    var identities: [Book.ID: String] {
        let books = self.books  // lu d'abord : une vue qui lit les identités suit aussi les changements de livres
        if let identityMap { return identityMap }
        let map = identityCache.update(books)
        identityMap = map
        return map
    }

    func identity(of book: Book) -> String { identities[book.id] ?? BookGroups.key(book) }

    /// Nombre de livres d'une liste de fichiers : les fichiers d'un même livre comptent pour un (barre latérale).
    func bookCount(_ list: [Book]) -> Int {
        let identities = identities
        return Set(list.map { identities[$0.id] ?? BookGroups.key($0) }).count
    }

    /// Fichiers masqués : même livre, même format qu'un fichier gardé (voir `BookGroups.duplicates`).
    var hiddenDuplicates: Set<Book.ID> {
        let books = self.books
        if duplicateIDs == nil {
            duplicateIDs = BookGroups.duplicates(books.filter { $0.trashedAt == nil }, identities: identities)
        }
        return duplicateIDs ?? []
    }

    /// Livres affichés, comptés et vérifiés en ligne. L'envoi et la reconnaissance des livres
    /// de la liseuse passent, eux, par tous les fichiers.
    /// Gardés jusqu'à la prochaine modification : la barre latérale et la liste les relisent à chaque rendu.
    var visibleBooks: [Book] {
        let show = showDuplicates, books = self.books
        if let visibleCache { return visibleCache }
        let hidden = show ? [] : hiddenDuplicates
        let list = books.filter { $0.trashedAt == nil && !hidden.contains($0.id) }
        visibleCache = list
        return list
    }

    /// Compteurs et listes de la barre latérale, calculés une fois par modification de la bibliothèque
    /// (voir `LibrarySummary`).
    var summary: LibrarySummary {
        let visible = visibleBooks, folders = self.folders.map(\.path)
        if let summaryCache, summaryCache.folderPaths == folders { return summaryCache }
        let s = LibrarySummary(visible: visible, all: books, identities: identities, folders: folders)
        summaryCache = s
        return s
    }

    // MARK: - Corbeille de Foluna

    /// Fichiers dans la corbeille : masqués partout ailleurs, restaurables.
    var trashedBooks: [Book] { books.filter { $0.trashedAt != nil } }

    /// Met le livre entier à la corbeille (tous ses fichiers, copies masquées comprises) ; rien ne bouge sur le disque.
    func moveToTrash(_ book: Book) { moveToTrash([book]) }

    /// Met plusieurs livres à la corbeille en un seul passage : les identités sont lues une fois
    /// et `books` n'est réaffecté qu'une fois (chaque modification invalide leur cache, à recalculer
    /// sur toute la bibliothèque).
    func moveToTrash(_ selection: [Book]) {
        let ids = identities, now = Date()
        let keys = Set(selection.map { ids[$0.id] ?? BookGroups.key($0) })
        var copy = books
        for i in copy.indices where copy[i].trashedAt == nil && keys.contains(ids[copy[i].id] ?? BookGroups.key(copy[i])) {
            copy[i].trashedAt = now
            copy[i].pendingSendAt = nil
            copy[i].pendingFor = nil
        }
        books = copy
        save()
    }

    func restoreFromTrash(_ book: Book) { restoreFromTrash([book]) }

    /// Restaure plusieurs livres en un seul passage (voir `moveToTrash(_:)`).
    func restoreFromTrash(_ selection: [Book]) {
        let ids = identities
        let keys = Set(selection.map { ids[$0.id] ?? BookGroups.key($0) })
        var copy = books
        for i in copy.indices where copy[i].trashedAt != nil && keys.contains(ids[copy[i].id] ?? BookGroups.key(copy[i])) {
            copy[i].trashedAt = nil
        }
        books = copy
        save()
    }

    /// Fichiers d'un livre de la corbeille.
    func trashedFiles(of book: Book) -> [Book] {
        let ids = identities, key = identity(of: book)
        return books.filter { $0.trashedAt != nil && ids[$0.id] == key }
    }

    /// Place les fichiers dans la Corbeille de macOS et les retire de la bibliothèque.
    /// Un fichier qui ne peut pas être déplacé reste dans la corbeille de Foluna.
    func deletePermanently(_ files: [Book]) async {
        let files = files.filter { $0.trashedAt != nil }
        guard !files.isEmpty else { return }
        let result = await Task.detached(priority: .userInitiated) { LibraryTrash.empty(files) }.value
        let removed = Set(result.removed)
        books.removeAll { removed.contains($0.id) }
        save()
        if let first = result.failures.first {
            let name = (first.path as NSString).lastPathComponent
            lastError = String(localized: "\(result.failures.count) fichiers n'ont pas pu être placés dans la Corbeille de macOS et restent dans celle de Foluna.")
                + " " + String(localized: "Premier : « \(name) » — \(first.reason)")
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

    // MARK: - Dossiers de livres (S-060 à S-063)

    /// Lit `folders.json`. Données de test : sans liste enregistrée, les dossiers viennent de
    /// `FOLUNA_BOOKS` (chemins séparés par « : »), jamais du réglage de l'utilisateur.
    private func loadFolders() {
        if let test = AppDirectories.testStore.flatMap({ _ in ProcessInfo.processInfo.environment["FOLUNA_BOOKS"] }),
           !FileManager.default.fileExists(atPath: directories.folders.path) {
            folders = test.split(separator: ":").map { LibraryFolders.Entry(URL(fileURLWithPath: String($0), isDirectory: true)) }
        } else {
            let legacy = AppDirectories.testStore == nil ? UserDefaults.standard.data(forKey: Self.legacyBookmarkKey) : nil
            folders = LibraryFolders.load(directories.folders, legacy: legacy)
        }
        refreshFolders()
        if !folders.isEmpty, !FileManager.default.fileExists(atPath: directories.folders.path) { saveFolders() }
    }

    /// Suit les dossiers déplacés ou renommés (signets) et note ceux qui sont introuvables.
    private func refreshFolders() {
        var changed = false
        folders = folders.map { entry in
            let (resolved, didChange) = entry.resolved()
            changed = changed || didChange
            return resolved
        }
        if changed { saveFolders() }
        unavailableFolders = Set(folders.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
    }

    private func saveFolders() {
        do {
            try LibraryFolders.save(folders, to: directories.folders)
        } catch {
            lastError = String(localized: "Impossible d'enregistrer les dossiers de livres : \(error.localizedDescription)")
        }
    }

    /// Ajoute un dossier de livres ; ses livres rejoignent la bibliothèque au parcours qui suit.
    /// Renvoie la raison d'un refus (dossier déjà lu, en entier ou en partie).
    @discardableResult
    func addFolder(_ url: URL) -> String? {
        if let conflict = LibraryFolders.conflict(adding: url.path, to: folders.map(\.path)) { return conflict.message }
        folders.append(LibraryFolders.Entry(url))
        saveFolders()
        refreshFolders()
        startWatching()
        Task { await rescan() }
        return nil
    }

    /// Retire un dossier : ses livres quittent la bibliothèque (étagères et attente d'envoi comprises),
    /// ses fichiers restent sur le disque. Le dernier dossier ne se retire pas.
    func removeFolder(_ path: String) {
        guard folders.count > 1, folders.contains(where: { $0.path == path }) else { return }
        let prefix = LibraryFolders.prefix(path)
        folders.removeAll { $0.path == path }
        saveFolders()
        refreshFolders()
        books.removeAll { !$0.isImported && $0.path.hasPrefix(prefix) }
        save()
        startWatching()
    }

    /// Dossier de livres d'un fichier (nil : livre importé).
    func folder(of book: Book) -> String? {
        book.isImported ? nil : LibraryFolders.owner(of: book.path, among: folders.map(\.path))
    }

    /// Livres visibles d'un dossier de livres.
    func books(inFolder path: String) -> [Book] {
        let prefix = LibraryFolders.prefix(path)
        return visibleBooks.filter { !$0.isImported && $0.path.hasPrefix(prefix) }
    }

    /// Livre d'un dossier débranché : affiché, mais ni envoyé ni lu tant que le disque manque.
    func isUnavailable(_ book: Book) -> Bool {
        guard !unavailableFolders.isEmpty, let folder = folder(of: book) else { return false }
        return unavailableFolders.contains(folder)
    }

    private var roots: [URL] {
        folders.map { URL(fileURLWithPath: $0.path, isDirectory: true) } + [directories.imports]
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
        refreshFolders()
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
            StorageMaintenance.purgeReading(keeping: books, directories: directories)
            return StorageMaintenance.purge(keeping: books, directories: directories)
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

    /// Vérifie automatiquement les livres qui apparaissent dans la bibliothèque. Désactivé tant que l'utilisateur
    /// n'a pas répondu (accueil, ou feuille au lancement) : les titres lus sont une donnée sensible (audit, § 3 et 5).
    var autoCheckCatalog: Bool {
        get {
            access(keyPath: \.autoCheckCatalog)
            // Données de test : pas de requête vers la BnF ni Open Library.
            guard AppDirectories.testStore == nil else { return false }
            return UserDefaults.standard.object(forKey: "catalogAutoCheck") as? Bool ?? false
        }
        set { withMutation(keyPath: \.autoCheckCatalog) { UserDefaults.standard.set(newValue, forKey: "catalogAutoCheck") } }
    }

    /// L'utilisateur a dit oui ou non à la vérification en ligne.
    var catalogConsentAnswered: Bool {
        access(keyPath: \.autoCheckCatalog)
        return UserDefaults.standard.object(forKey: "catalogAutoCheck") != nil
    }

    var pendingSuggestionCount: Int { summary.toReview }

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

    /// Revue en lot : applique les propositions retenues, livre par livre, à tous les fichiers de chaque livre
    /// (même chemin que la fiche : fichier principal corrigé, corrections recopiées sur les autres).
    func applyReview(_ rows: [CatalogReview.Row]) {
        for (_, item) in CatalogReview.fieldsByBook(rows) {
            var book = item.book
            guard let record = book.catalogRecord else { continue }
            var edits = book.edits
            CatalogComparison.apply(item.fields, from: record, to: &edits)
            book.edits = edits
            update(book, propagatingTo: item.fileIDs)
        }
    }

    /// Revue en lot : écarte les propositions retenues (elles ne seront plus proposées pour cette notice).
    func dismissReview(_ rows: [CatalogReview.Row]) {
        for (id, item) in CatalogReview.fieldsByBook(rows) { dismissCatalog(item.fields, for: id) }
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
                let message = String(localized: "Impossible d'enregistrer l'index : \(error.localizedDescription)")
                Task { @MainActor in self?.lastError = message }
            }
        }
        if sync { writeQueue.sync(execute: work) } else { writeQueue.async(execute: work) }
    }

    // MARK: - Annulation (⌘Z)

    /// Gestionnaire d'annulation de la fenêtre principale (fourni par ContentView).
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Augmente à chaque annulation : la fiche ouverte recharge alors les informations du livre.
    private(set) var undoGeneration = 0

    /// Exécute une modification annulable : seuls les livres réellement changés sont mémorisés.
    /// Les ajouts et retraits de fichiers (rescan, corbeille vidée) ne s'annulent pas.
    func undoable(_ name: String, _ body: () -> Void) {
        let before = books
        body()
        guard books.count == before.count else { return }
        let changed = before.indices.filter { before[$0] != books[$0] && before[$0].id == books[$0].id }.map { before[$0] }
        registerUndo(name, restoring: changed)
    }

    /// Mémorise l'état actuel de ces fichiers avant une modification faite ailleurs (fiche ouverte).
    func prepareUndo(_ name: String, ids: [Book.ID]) {
        registerUndo(name, restoring: ids.compactMap { book(id: $0) })
    }

    private func registerUndo(_ name: String, restoring snapshot: [Book]) {
        guard let undoManager, !snapshot.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(snapshot, name: name) }
        }
        undoManager.setActionName(name)
    }

    /// Rétablit les fichiers mémorisés et inscrit l'opération inverse (« Rétablir »).
    private func restore(_ snapshot: [Book], name: String) {
        let current = snapshot.compactMap { book(id: $0.id) }
        let index = Dictionary(books.indices.map { (books[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        var copy = books
        for b in snapshot { if let i = index[b.id] { copy[i] = b } }
        books = copy
        save()
        undoGeneration += 1
        registerUndo(name, restoring: current)
    }

    // MARK: - Couvertures manquantes (Open Library)

    @ObservationIgnored private let coverFinder = CoverFinder()
    /// Recherche en cours : livres traités / à traiter.
    private(set) var coverSearch: (done: Int, total: Int)?
    /// Résultat de la dernière recherche (couvertures trouvées / livres cherchés).
    private(set) var lastCoverSearch: (found: Int, searched: Int)?

    /// Livres (un fichier principal par livre) sans couverture.
    var booksWithoutCover: [Book] {
        BookGroups.make(visibleBooks, identities: identities).filter { !$0.books.contains(where: \.hasCover) }.map(\.primary)
    }

    /// Cherche les couvertures sur Open Library, une requête par seconde au plus ; l'image trouvée sert
    /// à tous les fichiers du livre. Renvoie le nombre de couvertures trouvées.
    @discardableResult
    func findCovers(for selection: [Book]) async -> Int {
        guard coverSearch == nil, !selection.isEmpty else { return 0 }
        coverSearch = (0, selection.count)
        defer { coverSearch = nil }
        var found = 0
        for (i, book) in selection.enumerated() {
            let edits = book.isbn == nil ? { var e = book.edits; e.isbn = book.catalogRecord?.isbn; return e }() : book.edits
            if let data = await coverFinder.cover(for: edits) {
                let key = identity(of: book), ids = identities, covers = self.covers
                let files = books.filter { (ids[$0.id] ?? BookGroups.key($0)) == key && !$0.hasCover }
                let stored = await Task.detached { files.filter { covers.store(data, key: $0.fingerprint) }.map(\.id) }.value
                if !stored.isEmpty {
                    let set = Set(stored)
                    var copy = books
                    for j in copy.indices where set.contains(copy[j].id) { copy[j].hasCover = true }
                    books = copy
                    save()
                    found += 1
                }
            }
            coverSearch = (i + 1, selection.count)
            if i + 1 < selection.count { try? await Task.sleep(for: .seconds(1)) }
        }
        lastCoverSearch = (found, selection.count)
        return found
    }

    // MARK: - Sauvegardes de l'index

    var backups: [IndexBackups.Backup] { IndexBackups.list(directories.backups) }

    /// Revient à une sauvegarde ; l'état actuel est d'abord mis de côté (« library-avant-restauration-… »).
    func restoreBackup(_ backup: IndexBackups.Backup) async {
        saveNow()
        do {
            let restored = try LibraryIndex.load(backup.url)
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
                .timeSeparator(.omitted))
            let aside = directories.backups.appendingPathComponent("library-avant-restauration-\(stamp).json")
            try? FileManager.default.copyItem(at: directories.index, to: aside)
            books = restored
            saveNow()
            write(sync: true)
            await rescan()
        } catch {
            lastError = String(localized: "Impossible de restaurer la sauvegarde : \(error.localizedDescription)")
        }
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
        book.pendingFor = books[i].pendingFor
        book.sentTo = books[i].sentTo
        book.trashedAt = books[i].trashedAt
        book.shelves = books[i].shelves
        book.favoritedAt = books[i].favoritedAt
        books[i] = book
        for j in siblingPositions {
            books[j].edits = book.edits
            books[j].tags = book.tags
            books[j].userTags = book.userTags
        }
        save()
    }

    // MARK: - Étagères des liseuses

    /// Livres d'une étagère (copies en double et corbeille exclues).
    func shelfBooks(_ reader: Reader.ID) -> [Book] {
        visibleBooks.filter { $0.shelfIDs.contains(reader) }
    }

    /// Nombre de livres (et non de fichiers) d'une étagère.
    func shelfCount(_ reader: Reader.ID) -> Int { summary.shelves[reader] ?? 0 }

    /// Une étagère concerne le livre entier : tous ses fichiers, copies masquées comprises.
    func addToShelf(_ books: [Book], reader: Reader.ID) {
        setShelf(books, reader: reader, on: true)
    }

    /// Retire de l'étagère sans rien supprimer, ni de la bibliothèque ni de la liseuse.
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

    // MARK: - Favoris (S-107)

    /// Un favori concerne le livre entier : tous ses fichiers, copies masquées comprises.
    /// La date d'ajout est gardée si le livre l'était déjà.
    func setFavorite(_ selection: [Book], on: Bool) {
        let ids = identities
        let keys = Set(selection.map { ids[$0.id] ?? BookGroups.key($0) })
        let now = Date()
        var changed = false
        for i in books.indices where keys.contains(ids[books[i].id] ?? BookGroups.key(books[i]))
            && books[i].isFavorite != on {
            books[i].favoritedAt = on ? now : nil
            changed = true
        }
        if changed { save() }
    }

    /// Les livres choisis sont-ils tous favoris ? Sinon, la commande les y ajoute.
    func areFavorites(_ selection: [Book]) -> Bool {
        !selection.isEmpty && selection.allSatisfy { book(id: $0.id)?.isFavorite == true }
    }

    /// Ajoute aux favoris, ou retire si tous le sont déjà ; annulable (⌘Z).
    func toggleFavorite(_ selection: [Book]) {
        let on = !areFavorites(selection)
        undoable(on ? String(localized: "Ajouter aux favoris") : String(localized: "Retirer des favoris")) {
            setFavorite(selection, on: on)
        }
    }

    // MARK: - Étiquettes (S-106)

    /// Une étiquette concerne le livre entier : tous ses fichiers, copies masquées comprises.
    private func changeTags(of selection: [Book]?, _ change: ([String]) -> [String]) {
        let ids = identities
        let keys = selection.map { Set($0.map { ids[$0.id] ?? BookGroups.key($0) }) }
        var changed = false
        for i in books.indices where keys?.contains(ids[books[i].id] ?? BookGroups.key(books[i])) ?? true {
            let tags = TagNames.clean(change(books[i].labels))
            let new: [String]? = tags.isEmpty ? nil : tags
            if new != books[i].userTags {
                books[i].userTags = new
                changed = true
            }
        }
        if changed { save() }
    }

    /// Ajoute l'étiquette aux livres choisis (sans doublon, quelle que soit la graphie).
    func addTag(_ tag: String, to selection: [Book]) {
        changeTags(of: selection) { $0 + [tag] }
    }

    /// Retire l'étiquette (clé de regroupement) des livres choisis.
    func removeTag(key: String, from selection: [Book]) {
        changeTags(of: selection) { $0.filter { TagNames.key($0) != key } }
    }

    /// Renomme l'étiquette dans toute la bibliothèque ; ses graphies se fondent dans la nouvelle.
    func renameTag(key: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TagNames.key(name).isEmpty else { return }
        changeTags(of: nil) { tags in tags.map { TagNames.key($0) == key ? name : $0 } }
    }

    /// Retire l'étiquette de tous les livres ; les livres eux-mêmes restent.
    func deleteTag(key: String) {
        changeTags(of: nil) { $0.filter { TagNames.key($0) != key } }
    }

    // MARK: - File d'envoi (Kindle débranchée)

    /// Tous les livres en attente d'envoi, quelle que soit la liseuse.
    var pendingSends: [Book] { pendingSends(for: nil) }

    /// Livres à envoyer à cette liseuse dès qu'elle sera branchée (ou à n'importe laquelle si nil),
    /// dans l'ordre où ils ont été demandés.
    func pendingSends(for reader: Reader.ID?) -> [Book] {
        books.compactMap { b in b.trashedAt == nil ? b.pendingDate(for: reader).map { (b, $0) } : nil }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Met en attente pour une liseuse (qui reçoit aussi le livre sur son étagère), ou pour la prochaine
    /// Kindle branchée si aucune n'est choisie.
    func queueForKindle(_ books: [Book], reader: Reader.ID?) {
        let now = Date()
        let ids = books.filter { $0.canSendToAnyReader && $0.trashedAt == nil }.map(\.id)
        mutate(ids) { b in
            if let reader {
                var pending = b.pendingFor ?? [:]
                pending[reader] = pending[reader] ?? now
                b.pendingFor = pending
            } else {
                b.pendingSendAt = b.pendingSendAt ?? now
            }
        }
        if let reader { addToShelf(books, reader: reader) }
    }

    /// Retire de la file : pour une liseuse (et l'attente « n'importe laquelle »), ou entièrement si nil.
    func removeFromKindleQueue(_ ids: [Book.ID], reader: Reader.ID? = nil) {
        mutate(ids) { b in
            b.pendingSendAt = nil
            if let reader {
                b.pendingFor?[reader] = nil
                if b.pendingFor?.isEmpty == true { b.pendingFor = nil }
            } else {
                b.pendingFor = nil
            }
        }
    }

    func recordSent(_ id: Book.ID, reader: Reader.ID) {
        mutate([id]) { b in
            var sent = b.sentTo ?? [:]
            sent[reader] = Date()
            b.sentTo = sent
        }
    }

    /// Seuls les états d'envoi sont modifiés : les livres reçus peuvent être des fichiers principaux de groupe
    /// complétés par les autres fichiers, qu'il ne faut pas enregistrer tels quels.
    private func mutate(_ ids: [Book.ID], _ change: (inout Book) -> Void) {
        let targets = ids.compactMap(position(of:))
        guard !targets.isEmpty else { return }
        for i in targets { change(&books[i]) }
        save()
    }

    /// Retire un livre de la liste « Envoyés à la liseuse » (tous ses fichiers) ; rien n'est supprimé.
    /// Le nom du fichier envoyé est gardé : il sert à reconnaître le livre s'il est encore sur la liseuse.
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
        copyIntoImports(urls)
        Task { await rescan() }
    }

    /// Ajoute un livre téléchargé d'un catalogue OPDS : copié dans les imports, indexé.
    /// Rend le livre ajouté, une fois le parcours de la bibliothèque terminé.
    func importDownloaded(_ file: URL) async -> Book? {
        guard let target = copyIntoImports([file]).first else { return nil }
        let path = target.standardizedFileURL.path
        let suffix = "/Imports/" + target.lastPathComponent
        // `/tmp` et `/private/tmp` : le parcours peut rendre l'un ou l'autre.
        let matches: (Book) -> Bool = { $0.path == path || $0.path.hasSuffix(suffix) }
        for _ in 0..<300 {
            if let book = books.first(where: matches) { return book }
            if isScanning { try? await Task.sleep(for: .milliseconds(100)) } else { await rescan() }
        }
        return nil
    }

    /// Fichiers créés dans `Imports/` (un nom déjà pris reçoit « (2) », « (3) »…).
    @discardableResult
    private func copyIntoImports(_ urls: [URL]) -> [URL] {
        var imported: [URL] = []
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
                imported.append(target)
            } catch {
                lastError = String(localized: "Import impossible de « \(url.lastPathComponent) » : \(error.localizedDescription)")
            }
        }
        if imported.isEmpty && lastError == nil {
            lastError = String(localized: "Aucun fichier pris en charge (EPUB, MOBI, AZW3, AZW, PDF).")
        }
        return imported
    }

    func coverURL(_ book: Book) -> URL? {
        book.hasCover ? covers.url(for: book.fingerprint) : nil
    }
}
