import AlexandrieCore
import AppKit
import Foundation
import Observation

/// Détection de la Kindle (disque monté ou MTP) et file d'envoi.
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
    /// Nom de la Kindle qui vient d'être éjectée : « vous pouvez la débrancher ».
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

    /// Tous les relevés importés des Kindle, conservés même après la suppression du livre de l'appareil.
    private(set) var clippings: [Clipping] = [] {
        didSet { clippingIndex = Dictionary(grouping: clippings) { ShelfSync.normalize($0.title) } }
    }
    @ObservationIgnored private var clippingIndex: [String: [Clipping]] = [:]

    /// Notes et surlignages d'un livre (rapprochés par titre, comme les livres de la Kindle).
    func clippings(for books: [Book]) -> [Clipping] {
        var seen = Set<String>()
        return books.flatMap { clippingIndex[ShelfSync.normalize($0.title)] ?? [] }
            .filter { $0.kind != .bookmark && seen.insert($0.id).inserted }
    }

    /// Titres (normalisés) dont une note ou un surlignage contient `query` : la recherche les retrouve.
    func titleKeys(withClippingsMatching query: String) -> Set<String> {
        Set(clippings.filter { $0.text.localizedStandardContains(query) }.map { ShelfSync.normalize($0.title) })
    }

    /// Lit My Clippings.txt sur une Kindle en disque USB et ajoute les nouveaux relevés.
    private func importClippings(from device: any KindleDevice) async {
        guard let volume = device as? VolumeKindle else { return }
        let file = volume.root.appendingPathComponent("documents/My Clippings.txt")
        let found = await Task.detached(priority: .utility) { () -> [Clipping] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            return KindleClippings.parse(String(decoding: data, as: UTF8.self))
        }.value
        let merged = KindleClippings.merge(clippings, found)
        guard merged.count != clippings.count else { return }
        clippings = merged
        try? KindleClippings.save(merged, to: directories.clippings)
    }

    // MARK: - Liseuses connues

    private(set) var readers: [Reader] = []
    /// Identifiant de la Kindle branchée.
    private(set) var deviceID: String?
    /// Kindle inconnue que l'utilisateur a choisi de ne pas nommer pour cette connexion.
    @ObservationIgnored private var namingPostponed: String?

    /// Liseuse correspondant à la Kindle branchée, si elle est connue.
    var currentReader: Reader? { deviceID.flatMap { id in readers.first { $0.id == id } } }
    /// Kindle branchée et pas encore nommée : la feuille de nom s'affiche.
    var needsNaming: Bool { deviceID != nil && currentReader == nil && namingPostponed != deviceID }
    /// Nom affiché de la Kindle branchée : celui de la liseuse, sinon celui de l'appareil.
    var displayName: String? { currentReader?.name ?? device?.name }

    func nameCurrentReader(_ name: String) {
        guard let id = deviceID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        readers.append(Reader(id: id, name: trimmed.isEmpty ? (device?.name ?? "Kindle") : trimmed))
        saveReaders()
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
        do {
            readers = try ReaderList.load(directories.readers)
        } catch {
            lastError = "Liste des liseuses illisible : \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    var isConnected: Bool { device != nil }

    func refresh() async {
        // L'identifiant MTP demande une session : il est lu hors du fil principal, avec la détection.
        let (found, id): ((any KindleDevice)?, String?) = await Task.detached {
            let device: (any KindleDevice)? = VolumeKindle.detect().first ?? MTPKindle.detect()
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

    /// Livre de la bibliothèque correspondant à un document de la Kindle (nom de fichier, ou titre + auteur).
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

    /// Livres de l'étagère de la Kindle branchée qui n'y sont pas encore (attend la lecture des fiches).
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
        let sendable = books.filter { $0.canSendToKindle && $0.trashedAt == nil }
        for b in sendable { transfers[b.id] = .queued }
        isBusy = true
        defer { isBusy = false }
        let directories = library.directories
        let covers = library.covers
        for book in sendable {
            transfers[book.id] = book.format == .epub ? .converting : .sending
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try KindleTransfer.prepare(book, directories: directories)
                }.value
                transfers[book.id] = .sending
                let filename = book.kindleFilename
                let asin = book.format == .epub ? book.asin : nil
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

    /// Envoie tout de suite si la Kindle est branchée, sinon met les livres en attente de connexion
    /// de la liseuse choisie (la seule connue, à défaut la prochaine Kindle branchée).
    func sendOrQueue(_ books: [Book], library: LibraryStore, reader: Reader.ID? = nil) async {
        if isConnected {
            await send(books, library: library)
        } else {
            library.queueForKindle(books, reader: reader ?? (readers.count == 1 ? readers[0].id : nil))
        }
    }

    /// Envoie la file d'attente ; appelé quand la Kindle vient d'être branchée.
    /// Un livre dont l'envoi échoue reste en attente pour la prochaine connexion.
    func sendPending(library: LibraryStore) async {
        guard isConnected, !isBusy else { return }
        let pending = library.pendingSends(for: deviceID)
        guard !pending.isEmpty else { return }
        await send(pending, library: library)
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
                                    : "Aucune Kindle à éjecter."
            return
        }
        guard !isBusy else {
            lastError = "Un transfert est en cours : attendez qu'il se termine avant d'éjecter la Kindle."
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
            lastError = "Impossible d'éjecter la Kindle : \(error.localizedDescription) Fermez les fichiers ouverts sur l'appareil, puis réessayez."
        }
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
