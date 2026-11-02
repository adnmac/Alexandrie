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
        Task { await refresh() }
    }

    var isConnected: Bool { device != nil }

    func refresh() async {
        let found: (any KindleDevice)? = await Task.detached {
            if let volume = VolumeKindle.detect().first { return volume }
            return MTPKindle.detect()
        }.value
        device = found
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

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    func isOnDevice(_ book: Book) -> Bool {
        if documentNames.contains(book.kindleFilename) || book.sentFilename.map(documentNames.contains) == true { return true }
        return !deviceTitles.isEmpty && deviceTitles.contains(Self.normalize(book.title))
    }

    // MARK: - Envoi

    func send(_ books: [Book], library: LibraryStore) async {
        guard let device else {
            lastError = KindleError.notConnected.localizedDescription
            return
        }
        let sendable = books.filter { !$0.isDRMProtected || $0.format.isKindleNative }
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
                transfers[book.id] = .done
            } catch {
                transfers[book.id] = .failed(error.localizedDescription)
            }
        }
        await reloadDocuments()
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
