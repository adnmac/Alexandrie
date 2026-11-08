import AlexandrieCore
import AppKit
import Foundation
import Observation

/// Détection de la liseuse (Kindle en disque ou en MTP, Kobo, liseuse USB ajoutée) et file d'envoi.
@MainActor @Observable
final class KindleMonitor {
    enum TransferState: Equatable {
        case queued, converting, sending, done
        case failed(String)
    }

    private(set) var device: (any KindleDevice)?
    private(set) var documents: [KindleDocument] = [] {
        didSet { documentNames = Set(documents.map(\.name)) }
    }
    private(set) var freeSpace: Int64?
    private(set) var transfers: [Book.ID: TransferState] = [:]
    private(set) var isBusy = false
    private(set) var isEjecting = false
    /// Nom de la liseuse qui vient d'être éjectée : « vous pouvez la débrancher ».
    private(set) var ejectedName: String?
    /// Fiches des livres de l'appareil, remplies progressivement.
    private(set) var infos: [KindleDocument.ID: KindleBookInfo] = [:] {
        didSet { deviceTitles = Set(infos.values.filter { !$0.isGuessed }.map { Self.normalize($0.title) }) }
    }
    /// Précalculés pour `isOnDevice`, appelé pour chaque ligne de la bibliothèque.
    private(set) var documentNames: Set<String> = []
    /// Titres normalisés des fiches lues sur l'appareil (fiches devinées exclues).
    private(set) var deviceTitles: Set<String> = []
    private(set) var catalogProgress: (done: Int, total: Int)?
    let catalog = KindleCatalog(directories: AppDirectories())
    @ObservationIgnored private let directories = AppDirectories()

    // MARK: - Notes et surlignages (My Clippings.txt)

    /// Tous les relevés importés des liseuses, conservés même après la suppression du livre de l'appareil.
    private(set) var clippings: [Clipping] = [] {
        didSet { clippingIndex = Dictionary(grouping: clippings.filter { !$0.isHidden }) { ShelfSync.normalize($0.title) } }
    }
    @ObservationIgnored private var clippingIndex: [String: [Clipping]] = [:]

    /// Notes et surlignages d'un livre (rapprochés par titre, comme les livres de la liseuse).
    func clippings(for books: [Book]) -> [Clipping] {
        var seen = Set<String>()
        return books.flatMap { clippingIndex[ShelfSync.normalize($0.title)] ?? [] }
            .filter { $0.kind != .bookmark && seen.insert($0.id).inserted }
    }

    /// Titres (normalisés) dont une note ou un surlignage contient `query` : la recherche les retrouve.
    func titleKeys(withClippingsMatching query: String) -> Set<String> {
        Set(clippings.filter { !$0.isHidden && $0.matches(query) }
            .map { ShelfSync.normalize($0.title) })
    }

    /// Livres annotés, pour la vue Notes (le plus récemment annoté en tête).
    var clippingBooks: [ClippingBook] { KindleClippings.books(clippings) }

    /// Demande de la fiche : ouvrir la vue Notes sur ce livre (titre normalisé).
    var notesRequest: String?

    /// Modifie le texte d'un relevé (le texte d'origine est gardé ; texte identique = retour à l'origine).
    func editClipping(_ id: Clipping.ID, text: String) {
        updateClipping(id) { c in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            c.editedText = trimmed == c.text ? nil : trimmed
        }
    }

    /// Note d'un surlignage (S-071) ; une note vide est retirée. Le relevé de la liseuse n'est pas touché.
    func setNote(_ id: Clipping.ID, _ note: String) {
        updateClipping(id) { c in
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            c.note = trimmed.isEmpty ? nil : trimmed
        }
    }

    func clipping(id: Clipping.ID) -> Clipping? { clippings.first { $0.id == id } }

    /// Couleur d'un surlignage (S-073) ; le jaune, couleur par défaut, n'est pas écrit.
    func setColor(_ id: Clipping.ID, _ color: HighlightColor) {
        updateClipping(id) { $0.apply(HighlightMark(color)) }
    }

    /// Couleur d'un surlignage (S-079) : de base ou ajoutée à une légende.
    func setMark(_ id: Clipping.ID, _ mark: HighlightMark) {
        updateClipping(id) { $0.apply(mark) }
    }

    /// Range un surlignage dans une thématique, ou l'en retire (S-079).
    func setThematic(_ id: Clipping.ID, _ thematic: String, on: Bool) {
        updateClipping(id) { $0.setThematic(thematic, on: on) }
    }

    /// Modifie plusieurs relevés d'un coup (thème supprimé, par exemple) ; `change` dit s'il a modifié.
    func modifyClippings(_ change: (inout Clipping) -> Bool) {
        var copy = clippings
        var changed = false
        for i in copy.indices where change(&copy[i]) { changed = true }
        guard changed else { return }
        clippings = copy
        saveClippings()
    }

    func revertClipping(_ id: Clipping.ID) { updateClipping(id) { $0.editedText = nil } }

    /// Supprime un relevé d'Alexandrie ; il ne revient pas au prochain import. Un surlignage fait
    /// dans l'app, qu'aucun import ne ramène, est retiré pour de bon.
    func deleteClipping(_ id: Clipping.ID) {
        if let i = clippings.firstIndex(where: { $0.id == id }), clippings[i].isFromApp {
            clippings.remove(at: i)
            saveClippings()
        } else {
            updateClipping(id) { $0.hidden = true }
        }
    }

    /// Surlignage fait dans la fenêtre de lecture (S-070) : rangé avec ceux de la liseuse.
    func addHighlight(_ clipping: Clipping) {
        clippings.append(clipping)
        saveClippings()
    }

    /// Surlignages faits dans l'app pour ce livre (même fichier, par son empreinte).
    func readerHighlights(of book: Book) -> [Clipping] {
        clippings.filter { $0.anchor?.book == book.fingerprint && !$0.isHidden }
    }

    private func updateClipping(_ id: Clipping.ID, _ change: (inout Clipping) -> Void) {
        guard let i = clippings.firstIndex(where: { $0.id == id }) else { return }
        change(&clippings[i])
        saveClippings()
    }

    private func saveClippings() {
        do {
            try KindleClippings.save(clippings, to: directories.clippings)
        } catch {
            lastError = "Impossible d'enregistrer les notes : \(error.localizedDescription)"
        }
    }

    /// Ajoute les nouveaux relevés de la liseuse : My Clippings.txt d'une Kindle en disque USB,
    /// base KoboReader.sqlite d'une Kobo. Une liseuse générique n'en donne pas.
    private func importClippings(from device: any KindleDevice) async {
        guard let volume = device as? VolumeKindle, volume.brand != .generic else { return }
        let root = volume.root
        let brand = volume.brand
        let found = await Task.detached(priority: .utility) { () -> [Clipping] in
            switch brand {
            case .kobo:
                return (try? KoboAnnotations.read(database: KoboAnnotations.database(onVolume: root))) ?? []
            default:
                guard let data = try? Data(contentsOf: root.appendingPathComponent("documents/My Clippings.txt")) else { return [] }
                return KindleClippings.parse(String(decoding: data, as: UTF8.self))
            }
        }.value
        let merged = KindleClippings.merge(clippings, found)
        guard merged.count != clippings.count else { return }
        clippings = merged
        saveClippings()
    }

    // MARK: - Liseuses connues

    private(set) var readers: [Reader] = []
    /// Identifiant de la liseuse branchée.
    private(set) var deviceID: String?
    /// Kindle inconnue que l'utilisateur a choisi de ne pas nommer pour cette connexion.
    @ObservationIgnored private var namingPostponed: String?

    /// Liseuse correspondant à la liseuse branchée, si elle est connue.
    var currentReader: Reader? { deviceID.flatMap { id in readers.first { $0.id == id } } }
    /// Kindle branchée et pas encore nommée : la feuille de nom s'affiche.
    var needsNaming: Bool { deviceID != nil && currentReader == nil && namingPostponed != deviceID }
    /// Nom affiché de la liseuse branchée : celui de la liseuse, sinon celui de l'appareil.
    var displayName: String? { currentReader?.name ?? device?.name }

    func nameCurrentReader(_ name: String) {
        guard let id = deviceID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let brand = device?.brand ?? .kindle
        let folder = brand == .generic ? (device as? VolumeKindle)?.booksFolder : nil
        readers.append(Reader(id: id, name: trimmed.isEmpty ? (device?.name ?? brand.label) : trimmed, brand: brand,
                              booksFolder: folder))
        saveReaders()
    }

    /// Marque de la liseuse branchée.
    var brand: ReaderBrand? { device?.brand }

    /// Le livre peut partir sur la liseuse branchée ; sans liseuse, sur au moins une marque (file d'attente).
    func canSend(_ book: Book) -> Bool {
        guard let brand else { return book.canSendToAnyReader }
        return book.canSend(to: brand)
    }

    // MARK: - Liseuses USB génériques (S-098)

    /// Disques amovibles qui pourraient être une liseuse : ni Kindle ni Kobo, pas encore ajoutés, avec des livres.
    func genericCandidates(excludingFolders folders: [URL]) async -> [VolumeKindle] {
        let known = Set(readers.map(\.id))
        return await Task.detached(priority: .userInitiated) { VolumeKindle.candidates(excluding: known, folders: folders) }.value
    }

    /// Ajoute un disque comme liseuse : reconnu ensuite à chaque branchement, livres envoyés dans `folder`.
    func addGenericReader(_ volume: VolumeKindle, folder: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        readers.removeAll { $0.id == volume.identifier }
        readers.append(Reader(id: volume.identifier, name: trimmed.isEmpty ? volume.name : trimmed,
                              brand: .generic, booksFolder: folder))
        saveReaders()
        await refresh()
    }

    /// Liseuses génériques connues : identifiant du volume → dossier des livres.
    private var genericFolders: [String: String] {
        Dictionary(readers.filter { $0.brand == .generic }.map { ($0.id, $0.booksFolder ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func postponeNaming() { namingPostponed = deviceID }

    func rename(_ reader: Reader.ID, to name: String) {
        guard let i = readers.firstIndex(where: { $0.id == reader }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        readers[i].name = trimmed
        saveReaders()
    }

    func forget(_ reader: Reader.ID) {
        readers.removeAll { $0.id == reader }
        saveReaders()
    }

    private func saveReaders() {
        do {
            try ReaderList.save(readers, to: directories.readers)
        } catch {
            lastError = "Impossible d'enregistrer les liseuses : \(error.localizedDescription)"
        }
    }
    let mtpAvailable = MTPKindle.isLibraryAvailable
    var lastError: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        // Les Kindle MTP ne déclenchent pas de notification de montage : sondage léger.
        if mtpAvailable {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollMTP() }
            }
        }
        clippings = KindleClippings.load(directories.clippings)
        // Copie du jour des notes (modifiées dans l'app : elles n'existent nulle part ailleurs).
        _ = try? IndexBackups.backUpToday(directories.clippings, to: directories.backups, name: "clippings")
        do {
            readers = try ReaderList.load(directories.readers)
        } catch {
            lastError = "Liste des liseuses illisible : \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    var isConnected: Bool { device != nil }

    /// Self-test et captures : une liseuse simulée par un dossier, à la place des appareils branchés.
    /// Sans effet hors du dossier de test (`ALEXANDRIE_STORE`).
    @ObservationIgnored private var simulated: (any KindleDevice)?

    func simulate(_ device: (any KindleDevice)?) async {
        guard AppDirectories.testStore != nil else { return }
        simulated = device
        await refresh()
    }

    func refresh() async {
        if let simulated {
            device = simulated
            deviceID = simulated.identifier
            await reloadDocuments()
            return
        }
        // L'identifiant MTP demande une session : il est lu hors du fil principal, avec la détection.
        let generic = genericFolders
        let (found, id): ((any KindleDevice)?, String?) = await Task.detached {
            let device: (any KindleDevice)? = VolumeKindle.detect(generic: generic).first ?? MTPKindle.detect()
            return (device, device?.identifier)
        }.value
        device = found
        deviceID = id
        if found != nil { ejectedName = nil }
        if let id, let i = readers.firstIndex(where: { $0.id == id }) {
            readers[i].lastSeenAt = Date()
            saveReaders()
        }
        await reloadDocuments()
    }

    private func pollMTP() async {
        guard !isBusy, device == nil || device?.connection == .mtp else { return }
        let present = await Task.detached { MTPKindle.detect() != nil }.value
        if present != (device != nil) { await refresh() }
    }

    func reloadDocuments() async {
        guard let device else {
            documents = []
            freeSpace = nil
            return
        }
        do {
            let (docs, free) = try await Task.detached {
                (try device.listDocuments(), device.freeSpace())
            }.value
            documents = docs
            freeSpace = free
            await importClippings(from: device)
        } catch {
            documents = []
            lastError = error.localizedDescription
        }
        readCatalog()
    }

    /// Fiches en cache tout de suite, puis analyse des nouveaux fichiers un par un.
    private func readCatalog() {
        catalogTask?.cancel()
        infos = Dictionary(uniqueKeysWithValues: documents.compactMap { d in self.catalog.cached(d).map { (d.id, $0) } })
        let missing = documents.filter { infos[$0.id] == nil }
        guard let device, !missing.isEmpty else {
            catalogProgress = nil
            return
        }
        catalogProgress = (0, missing.count)
        let catalog = self.catalog
        catalogTask = Task {
            for (i, doc) in missing.enumerated() {
                if Task.isCancelled { break }
                let info = await Task.detached(priority: .utility) { catalog.info(for: doc, on: device) }.value
                infos[doc.id] = info
                catalogProgress = (i + 1, missing.count)
            }
            catalog.save()
            catalogProgress = nil
        }
    }

    /// Livre de la bibliothèque correspondant à un document de la liseuse (nom de fichier, ou titre + auteur).
    func libraryBook(for doc: KindleDocument, in library: LibraryStore) -> Book? {
        if let b = library.books.first(where: { $0.sentFilename == doc.name || $0.kindleFilename == doc.name }) { return b }
        guard let info = infos[doc.id], !info.isGuessed else { return nil }
        return library.books(titleKey: Self.normalize(info.title)).first { b in
            info.authors.isEmpty || b.authors.isEmpty
                || Set(b.authors.map(Self.normalize)).intersection(info.authors.map(Self.normalize)).count > 0
        }
    }

    static func normalize(_ s: String) -> String { ShelfSync.normalize(s) }

    func isOnDevice(_ book: Book) -> Bool {
        ShelfSync.isOnDevice([book], documentNames: documentNames, deviceTitles: deviceTitles)
    }

    /// Livres de l'étagère de la liseuse branchée qui n'y sont pas encore (attend la lecture des fiches).
    func missingFromShelf(in library: LibraryStore) -> [Book] {
        guard let reader = currentReader, catalogProgress == nil else { return [] }
        let groups = BookGroups.make(library.shelfBooks(reader.id), identities: library.identities)
        return ShelfSync.missing(groups, documentNames: documentNames, deviceTitles: deviceTitles)
    }

    // MARK: - Envoi

    func send(_ books: [Book], library: LibraryStore) async {
        guard let device else {
            lastError = KindleError.notConnected.localizedDescription
            return
        }
        // Livre d'un dossier débranché (S-062) : il reste en attente, il partira quand le disque reviendra.
        let unavailable = books.filter { library.isUnavailable($0) }
        if let first = unavailable.first {
            lastError = unavailable.count == 1
                ? "« \(first.title) » est indisponible : son dossier de livres est introuvable (disque débranché ?)."
                : "\(unavailable.count) livres sont indisponibles : leur dossier de livres est introuvable (disque débranché ?)."
        }
        let brand = device.brand
        let refused = books.filter { !$0.canSend(to: brand) }
        if let first = refused.first {
            lastError = refused.count == 1
                ? "« \(first.title) » est protégé par DRM : il ne peut pas être lu sur cette \(brand.label)."
                : "\(refused.count) livres sont protégés par DRM : ils ne peuvent pas être lus sur cette \(brand.label)."
        }
        let sendable = books.filter { $0.canSend(to: brand) && $0.trashedAt == nil && !library.isUnavailable($0) }
        for b in sendable { transfers[b.id] = .queued }
        isBusy = true
        defer { isBusy = false }
        let directories = library.directories
        let covers = library.covers
        for book in sendable {
            transfers[book.id] = book.needsConversion(for: brand) ? .converting : .sending
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try KindleTransfer.prepare(book, directories: directories, brand: brand)
                }.value
                transfers[book.id] = .sending
                let filename = book.filename(for: brand)
                // Miniature de couverture : seulement pour un AZW3 produit pour une Kindle.
                let asin = brand.sendsThumbnails && book.becomesAZW3 ? book.asin : nil
                try await Task.detached(priority: .userInitiated) {
                    let thumbnail = asin.flatMap { a in covers.kindleThumbnail(key: book.fingerprint).map { (a, $0) } }
                    try device.send(file: file, filename: filename, thumbnail: thumbnail)
                }.value
                var updated = book
                updated.lastSentAt = Date()
                updated.sentFilename = filename
                library.update(updated)
                library.removeFromKindleQueue([book.id], reader: deviceID)
                if let reader = currentReader {
                    library.recordSent(book.id, reader: reader.id)
                    library.addToShelf([book], reader: reader.id)
                }
                transfers[book.id] = .done
            } catch {
                transfers[book.id] = .failed(error.localizedDescription)
            }
        }
        await reloadDocuments()
    }

    /// Envoie tout de suite si la liseuse est branchée, sinon met les livres en attente de connexion
    /// de la liseuse choisie (la seule connue, à défaut la prochaine Kindle branchée).
    func sendOrQueue(_ books: [Book], library: LibraryStore, reader: Reader.ID? = nil) async {
        if isConnected {
            await send(books, library: library)
        } else {
            library.queueForKindle(books, reader: reader ?? (readers.count == 1 ? readers[0].id : nil))
        }
    }

    /// Envoie la file d'attente ; appelé quand la liseuse vient d'être branchée.
    /// Un livre dont l'envoi échoue reste en attente pour la prochaine connexion.
    func sendPending(library: LibraryStore) async {
        guard isConnected, !isBusy else { return }
        let pending = library.pendingSends(for: deviceID)
        guard !pending.isEmpty else { return }
        await send(pending, library: library)
        // Notification : l'app peut être en arrière-plan quand la liseuse est branchée.
        let sent = pending.filter { transfers[$0.id] == .done }.map(\.title)
        let failed = pending.filter { if case .failed = transfers[$0.id] { true } else { false } }.count
        SendNotifier.post(sent: sent, failed: failed, reader: currentReader?.name)
    }

    /// Réécrit les informations d'un livre sur l'appareil. Renvoie un message d'erreur, ou nil si succès.
    func update(_ document: KindleDocument, with edits: MetadataEdits) async -> String? {
        guard let device else { return KindleError.notConnected.localizedDescription }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try KindleEditor.update(document, with: edits, on: device)
            }.value
        } catch {
            return error.localizedDescription
        }
        await reloadDocuments()
        return nil
    }

    /// Seul un disque USB s'éjecte ; une Kindle en MTP se débranche directement.
    var canEject: Bool { device is VolumeKindle }

    func eject() async {
        guard let volume = device as? VolumeKindle else {
            lastError = isConnected ? "Cette Kindle (MTP) n'a pas besoin d'être éjectée : vous pouvez la débrancher."
                                    : "Aucune liseuse à éjecter."
            return
        }
        guard !isBusy else {
            lastError = "Un transfert est en cours : attendez qu'il se termine avant d'éjecter la liseuse."
            return
        }
        isBusy = true
        isEjecting = true
        defer { isBusy = false; isEjecting = false }
        // La lecture des fiches garde des fichiers de l'appareil ouverts : elle est arrêtée d'abord.
        catalogTask?.cancel()
        catalogProgress = nil
        do {
            try await volume.eject()
            ejectedName = displayName ?? volume.name
            device = nil
            deviceID = nil
            documents = []
            freeSpace = nil
        } catch {
            lastError = "Impossible d'éjecter la liseuse : \(error.localizedDescription) Fermez les fichiers ouverts sur l'appareil, puis réessayez."
        }
    }

    /// Livres de la liseuse branchée qui sont dans la bibliothèque mais plus sur l'étagère de sa liseuse.
    /// Les livres inconnus de la bibliothèque (achats Amazon…) ne sont jamais proposés.
    func offShelfDocuments(in library: LibraryStore) -> [(document: KindleDocument, book: Book)] {
        guard let reader = currentReader, catalogProgress == nil else { return [] }
        return documents.compactMap { d in
            guard let b = libraryBook(for: d, in: library), !b.shelfIDs.contains(reader.id) else { return nil }
            return (d, b)
        }
    }

    /// Supprime plusieurs livres de l'appareil (la bibliothèque n'est pas touchée).
    func delete(_ documents: [KindleDocument]) async {
        guard let device, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var failures = 0
        for d in documents {
            do { try await Task.detached { try device.delete(d) }.value } catch { failures += 1 }
        }
        if failures > 0 { lastError = "\(failures) livre(s) n'ont pas pu être retirés de la liseuse." }
        await reloadDocuments()
    }

    func delete(_ document: KindleDocument) async {
        guard let device else { return }
        do {
            try await Task.detached { try device.delete(document) }.value
        } catch {
            lastError = error.localizedDescription
        }
        await reloadDocuments()
    }

    func clearFinishedTransfers() {
        transfers = transfers.filter {
            if case .done = $0.value { return false }
            if case .failed = $0.value { return false }
            return true
        }
    }
}
