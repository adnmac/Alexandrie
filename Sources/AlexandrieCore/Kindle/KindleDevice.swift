import CMTPShim
import CryptoKit
import Foundation

public struct KindleDocument: Identifiable, Hashable, Sendable {
    public let id: String
    /// Chemin relatif au dossier parcouru : `documents/` d'une Kindle (« Downloads/Items01/livre.kfx »),
    /// racine d'une Kobo, dossier des livres d'une liseuse générique.
    public let path: String
    public let size: Int64
    let mtpID: UInt32?

    public var name: String { (path as NSString).lastPathComponent }
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }
}

extension KindleDocument {
    /// Document hors appareil (captures d'écran, tests) : pas d'identifiant MTP.
    public init(id: String, path: String, size: Int64) {
        self.init(id: id, path: path, size: size, mtpID: nil)
    }
}

public enum KindleConnection: String, Sendable {
    case volume = "Disque USB"
    case mtp = "MTP"
}

public enum KindleError: LocalizedError {
    case notConnected
    case transferFailed(String)
    case insufficientSpace
    /// macOS refuse à l'app la lecture du disque de la Kindle (autorisation « volumes amovibles »).
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .notConnected: "La liseuse n'est plus connectée."
        case .transferFailed(let why): "Le transfert a échoué : \(why)."
        case .insufficientSpace: "Espace insuffisant sur la liseuse."
        case .accessDenied:
            "macOS ne laisse pas Alexandrie lire la liseuse. Autorisez-la dans Réglages Système › Confidentialité et sécurité › "
                + "Fichiers et dossiers › Alexandrie › Volumes amovibles, puis cliquez sur « Actualiser »."
        }
    }
}

/// Une liseuse branchée (Kindle, Kobo, liseuse USB), quel que soit le protocole.
public protocol KindleDevice: AnyObject, Sendable {
    var name: String { get }
    /// Marque : formats envoyés, dossier des livres, notes.
    var brand: ReaderBrand { get }
    /// Identifiant stable de l'appareil (« vol:… », « mtp:… ») : reconnaît une liseuse d'une connexion à l'autre.
    var identifier: String { get }
    var connection: KindleConnection { get }
    func freeSpace() -> Int64?
    func listDocuments() throws -> [KindleDocument]
    /// Copie `file` dans le dossier des livres et, si fourni (Kindle), la miniature de couverture.
    func send(file: URL, filename: String, thumbnail: (asin: String, jpeg: Data)?) throws
    func delete(_ document: KindleDocument) throws
    /// Donne accès au fichier sur le Mac : directement (disque) ou via une copie temporaire (MTP).
    func withLocalCopy<T>(of document: KindleDocument, _ body: (URL) throws -> T) throws -> T
    /// Miniature de couverture générée par la Kindle pour un ASIN, si accessible.
    func thumbnail(asin: String) -> Data?
    /// Remplace le contenu d'un livre de l'appareil (même emplacement, même nom), sans risque de perte.
    func replace(_ document: KindleDocument, with file: URL) throws
}

/// Fichier de la Kindle à présenter comme un livre (exclut le fichier de notes « My Clippings.txt »).
func isKindleBook(_ path: String) -> Bool { ReaderBrand.kindle.isBook(path) }

private func thumbnailName(_ asin: String) -> String { "thumbnail_\(asin)_EBOK_portrait.jpg" }

// MARK: - Disque monté (Kindle jusqu'aux modèles 2023, Kobo, liseuses USB)

public final class VolumeKindle: KindleDevice, @unchecked Sendable {
    public let root: URL
    public let connection = KindleConnection.volume
    public let brand: ReaderBrand
    /// Dossier des livres, relatif à la racine (« documents », « Books », ou celui choisi ; vide : la racine).
    public let booksFolder: String
    public var name: String {
        (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? root.lastPathComponent
    }

    public init(root: URL, brand: ReaderBrand = .kindle, booksFolder: String? = nil) {
        self.root = root
        self.brand = brand
        self.booksFolder = booksFolder ?? brand.defaultBooksFolder
    }

    /// UUID du volume (les disques FAT des Kindle en ont un, stable tant que l'appareil n'est pas réinitialisé) ;
    /// à défaut, nom et capacité.
    public var identifier: String {
        let v = try? root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeNameKey])
        if let uuid = v?.volumeUUIDString, !uuid.isEmpty { return "vol:" + uuid }
        return "vol:\(v?.volumeName ?? root.lastPathComponent)-\(v?.volumeTotalCapacity ?? 0)"
    }

    /// Dossier où vont les livres envoyés.
    var documents: URL { booksFolder.isEmpty ? root : root.appendingPathComponent(booksFolder, isDirectory: true) }
    /// Dossier parcouru pour la liste des livres présents.
    var listRoot: URL {
        let folder = brand.listFolder(booksFolder: booksFolder)
        return folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
    }

    /// Marque reconnue d'après le contenu du disque : Kindle (`documents/` et `system/`), Kobo (`.kobo/`).
    /// Un autre disque n'est jamais pris pour une liseuse : seule une liseuse générique déjà ajoutée l'est.
    public static func brand(of root: URL) -> ReaderBrand? {
        let fm = FileManager.default
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDir) && isDir.boolValue
        }
        if isDirectory(".kobo") && (fm.fileExists(atPath: root.appendingPathComponent(".kobo/KoboReader.sqlite").path)
                                    || fm.fileExists(atPath: root.appendingPathComponent(".kobo/version").path)) {
            return .kobo
        }
        if isDirectory("documents") && fm.fileExists(atPath: root.appendingPathComponent("system").path) { return .kindle }
        return nil
    }

    /// Liseuses branchées : Kindle et Kobo reconnues, plus les liseuses génériques déjà ajoutées
    /// (identifiant du volume → dossier des livres).
    public static func detect(generic: [String: String] = [:]) -> [VolumeKindle] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { v in
            if let brand = brand(of: v) { return VolumeKindle(root: v, brand: brand) }
            let volume = VolumeKindle(root: v, brand: .generic)
            return generic[volume.identifier].map { VolumeKindle(root: v, brand: .generic, booksFolder: $0) }
        }
    }

    /// Disques amovibles qui pourraient être une liseuse générique : ni Kindle ni Kobo, pas encore ajoutés,
    /// avec au moins un livre lisible. Les volumes du système et les dossiers exclus ne sont pas proposés.
    public static func candidates(excluding known: Set<String>, folders: [URL] = []) -> [VolumeKindle] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { v -> VolumeKindle? in
            let r = try? v.resourceValues(forKeys: Set(keys))
            guard r?.volumeIsRootFileSystem != true, r?.volumeIsInternal != true,
                  r?.volumeIsRemovable == true || r?.volumeIsEjectable == true, brand(of: v) == nil else { return nil }
            let device = VolumeKindle(root: v, brand: .generic)
            guard !known.contains(device.identifier),
                  !folders.contains(where: { $0.standardizedFileURL.path.hasPrefix(v.standardizedFileURL.path) }) else { return nil }
            return device.hasBooks ? device : nil
        }
    }

    /// Au moins un livre lisible dans les premiers niveaux du disque.
    var hasBooks: Bool {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if ReaderBrand.generic.isBook(url.path) { return true }
        }
        return false
    }

    /// Dossier des livres proposé pour une liseuse générique : `Books`, `Documents`, `eBooks` s'il existe, sinon la racine.
    public var suggestedBooksFolder: String {
        for name in ["Books", "books", "Documents", "documents", "eBooks", "Livres"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                return name
            }
        }
        return ""
    }

    public func freeSpace() -> Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    /// Démonte et éjecte le disque (comme ⏏ dans le Finder) : la Kindle peut ensuite être débranchée.
    /// Échoue si un fichier de l'appareil est encore ouvert.
    public func eject() async throws {
        let root = self.root
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            FileManager.default.unmountVolume(at: root, options: [.allPartitionsAndEjectDisk]) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Parcours récursif : les achats récents d'une Kindle sont rangés dans `documents/Downloads/Items01/…`,
    /// les livres d'une Kobo n'importe où sur le disque.
    public func listDocuments() throws -> [KindleDocument] {
        let documents = listRoot
        // Le parcours ignore les erreurs : sans autorisation, il ne trouverait simplement rien.
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: documents.path)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw KindleError.accessDenied
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && [1, 13].contains(error.code) {
            throw KindleError.accessDenied
        }
        guard let e = FileManager.default.enumerator(at: documents, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else {
            throw KindleError.notConnected
        }
        let base = documents.standardizedFileURL.path + "/"
        var docs: [KindleDocument] = []
        for case let url as URL in e {
            if url.pathExtension.lowercased() == "sdr" || brand.hiddenFolders.contains(url.lastPathComponent) {
                e.skipDescendants()
                continue
            }
            guard brand.isBook(url.path) else { continue }
            let full = url.standardizedFileURL.path
            docs.append(KindleDocument(id: full, path: String(full.dropFirst(base.count)),
                                       size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                                       mtpID: nil))
        }
        return docs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func withLocalCopy<T>(of document: KindleDocument, _ body: (URL) throws -> T) throws -> T {
        try body(URL(fileURLWithPath: document.id))
    }

    public func replace(_ document: KindleDocument, with file: URL) throws {
        let target = URL(fileURLWithPath: document.id)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).alexandrie-tmp")
        let fm = FileManager.default
        try? fm.removeItem(at: temp)
        do {
            // Copie complète d'abord : l'original n'est remplacé que si elle a réussi.
            try fm.copyItem(at: file, to: temp)
            do {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } catch {
                // FAT32 ne gère pas toujours l'échange atomique.
                try fm.removeItem(at: target)
                try fm.moveItem(at: temp, to: target)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw KindleError.transferFailed(error.localizedDescription)
        }
    }

    public func thumbnail(asin: String) -> Data? {
        let dir = root.appendingPathComponent("system/thumbnails", isDirectory: true)
        for type in ["EBOK", "PDOC", "EBSP"] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent("thumbnail_\(asin)_\(type)_portrait.jpg")) {
                return d
            }
        }
        return nil
    }

    public func send(file: URL, filename: String, thumbnail: (asin: String, jpeg: Data)?) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { throw KindleError.notConnected }
        // Dossier des livres d'une Kobo (« Books ») ou d'une liseuse générique : créé s'il manque.
        if !FileManager.default.fileExists(atPath: documents.path) {
            guard brand != .kindle else { throw KindleError.notConnected }
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let free = freeSpace(), free < size { throw KindleError.insufficientSpace }
        let target = documents.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: file, to: target)
        } catch {
            throw KindleError.transferFailed(error.localizedDescription)
        }
        if let thumbnail, brand.sendsThumbnails {
            let dir = root.appendingPathComponent("system/thumbnails", isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.path) {
                try? thumbnail.jpeg.write(to: dir.appendingPathComponent(thumbnailName(thumbnail.asin)))
            }
        }
    }

    public func delete(_ document: KindleDocument) throws {
        try FileManager.default.removeItem(atPath: document.id)
        // La Kindle crée un dossier .sdr (position de lecture, notes) à côté du livre.
        let sdr = URL(fileURLWithPath: document.id).deletingPathExtension().appendingPathExtension("sdr")
        try? FileManager.default.removeItem(at: sdr)
    }
}

// MARK: - MTP (Kindle depuis fin 2024), via libmtp

public final class MTPKindle: KindleDevice, @unchecked Sendable {
    public let connection = KindleConnection.mtp
    public let brand = ReaderBrand.kindle
    public private(set) var name = "Kindle"
    private var serial = ""

    /// Numéro de série MTP, lu à la première session (« mtp:kindle » tant qu'il est inconnu).
    public var identifier: String {
        if serial.isEmpty { _ = try? withSession { _ in () } }
        return "mtp:" + (serial.isEmpty ? "kindle" : serial)
    }
    /// libmtp n'est pas réentrante : toutes les opérations passent par cette file.
    private static let queue = DispatchQueue(label: "alexandrie.mtp")

    public static var isLibraryAvailable: Bool { alx_mtp_available() == 1 }

    /// Détecte une Kindle MTP (opération légère, sans ouvrir de session).
    public static func detect() -> MTPKindle? {
        queue.sync {
            guard alx_mtp_available() == 1, alx_mtp_detect_kindles() > 0 else { return nil }
            return MTPKindle()
        }
    }

    private init() {}

    private func withSession<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try Self.queue.sync {
            guard let session = alx_mtp_open() else {
                throw KindleError.transferFailed(
                    "impossible d'ouvrir la Kindle en MTP (fermez Android File Transfer ou tout autre outil MTP)")
            }
            defer { alx_mtp_close(session) }
            var buffer = [CChar](repeating: 0, count: 256)
            alx_mtp_name(session, &buffer, buffer.count)
            let n = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !n.isEmpty { name = n }
            var serialBuffer = [CChar](repeating: 0, count: 256)
            alx_mtp_serial(session, &serialBuffer, serialBuffer.count)
            let s = String(decoding: serialBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !s.isEmpty { serial = s }
            return try body(session)
        }
    }

    public func freeSpace() -> Int64? {
        let v = try? withSession { alx_mtp_free_space($0) }
        return v.flatMap { $0 >= 0 ? $0 : nil }
    }

    public func listDocuments() throws -> [KindleDocument] {
        final class Box { var docs: [KindleDocument] = [] }
        let box = Box()
        try withSession { session in
            _ = alx_mtp_list_documents(session, { ctx, id, path, size in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                box.docs.append(KindleDocument(id: "mtp:\(id)", path: String(cString: path!), size: Int64(size), mtpID: id))
            }, Unmanaged.passUnretained(box).toOpaque())
        }
        return box.docs.filter { isKindleBook($0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func send(file: URL, filename: String, thumbnail: (asin: String, jpeg: Data)?) throws {
        let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try withSession { session in
            // Remplace une version précédente du même nom.
            var existing: UInt32?
            final class Box { var id: UInt32?; let name: String; init(_ n: String) { name = n } }
            let box = Box(filename)
            _ = alx_mtp_list_documents(session, { ctx, id, name, _ in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                if String(cString: name!) == box.name { box.id = id }
            }, Unmanaged.passUnretained(box).toOpaque())
            existing = box.id
            if let existing { _ = alx_mtp_delete(session, existing) }
            guard alx_mtp_send(session, file.path, filename, size) == 0 else {
                throw KindleError.transferFailed("l'appareil a refusé le fichier")
            }
            if let thumbnail {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(thumbnailName(thumbnail.asin))
                if (try? thumbnail.jpeg.write(to: tmp)) != nil {
                    _ = alx_mtp_send_thumbnail(session, tmp.path, thumbnailName(thumbnail.asin), UInt64(thumbnail.jpeg.count))
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
        }
    }

    public func withLocalCopy<T>(of document: KindleDocument, _ body: (URL) throws -> T) throws -> T {
        guard let id = document.mtpID else { throw KindleError.notConnected }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alexandrie-mtp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("\(id)-\(document.name)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try withSession { session in
            guard alx_mtp_download(session, id, tmp.path) == 0 else {
                throw KindleError.transferFailed("lecture impossible de « \(document.name) »")
            }
        }
        return try body(tmp)
    }

    /// Les miniatures MTP ne sont pas lues (il faudrait parcourir system/thumbnails à chaque livre).
    public func thumbnail(asin: String) -> Data? { nil }

    public func replace(_ document: KindleDocument, with file: URL) throws {
        guard let id = document.mtpID else { throw KindleError.notConnected }
        let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try withSession { session in
            guard alx_mtp_replace(session, id, file.path, size) == 0 else {
                throw KindleError.transferFailed("l'appareil a refusé la nouvelle version")
            }
        }
    }

    public func delete(_ document: KindleDocument) throws {
        guard let id = document.mtpID else { return }
        try withSession { session in
            guard alx_mtp_delete(session, id) == 0 else { throw KindleError.transferFailed("suppression refusée") }
        }
    }
}

// MARK: - Préparation de l'envoi

public enum KindleTransfer {
    /// Fichier à copier sur la liseuse, avec les corrections de l'app. Les fichiers produits sont mis en cache.
    /// - Kindle : AZW3 converti pour un EPUB, copie aux métadonnées réécrites pour un MOBI/AZW3, PDF tel quel,
    ///   rogné ou en texte redimensionnable (AZW3), original pour un livre sous DRM.
    /// - Kobo et liseuse générique : EPUB aux métadonnées réécrites, EPUB converti pour un MOBI/AZW3,
    ///   PDF tel quel, rogné ou en texte redimensionnable (EPUB), original pour un livre sous DRM.
    public static func prepare(_ book: Book, directories: AppDirectories, brand: ReaderBrand = .kindle) throws -> URL {
        if book.isDRMProtected { return book.url }
        if book.format == .pdf && (book.pdfMode ?? .asIs) == .asIs { return book.url }
        let out = cachedCopy(of: book, directories: directories, brand: brand)
        if !FileManager.default.fileExists(atPath: out.path) {
            if book.format == .pdf, book.pdfMode == .cropped {
                try PDFCrop.write(book.url, to: out, edits: book.edits)
            } else if book.format == .pdf {
                if brand.readsEPUB {
                    try PDFReflow.writeEPUB(book.url, to: out, edits: book.edits)
                } else {
                    let epub = directories.conversions.appendingPathComponent("\(book.fingerprint)-texte.epub")
                    defer { try? FileManager.default.removeItem(at: epub) }
                    try PDFReflow.writeEPUB(book.url, to: epub, edits: book.edits)
                    try EPUBToAZW3.convert(input: epub, output: out, edits: book.edits, asin: book.asin)
                }
            } else if book.format == .epub {
                if brand.readsEPUB {
                    try EPUBMetadataWriter.rewrite(book.url, with: book.edits, to: out)
                } else {
                    try EPUBToAZW3.convert(input: book.url, output: out, edits: book.edits, asin: book.asin)
                }
            } else if brand.readsEPUB {
                try MobiToEPUB.convert(input: book.url, output: out, edits: book.edits)
            } else {
                try MobiMetadataWriter.rewrite(book.url, with: book.edits, to: out)
            }
        }
        return out
    }

    /// Copie en cache pour la liseuse. Clé stable : toute correction des informations force une nouvelle copie.
    /// La Kobo et les liseuses génériques reçoivent la même copie (EPUB).
    public static func cachedCopy(of book: Book, directories: AppDirectories, brand: ReaderBrand = .kindle) -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var key = (try? encoder.encode(book.edits)) ?? Data(book.title.utf8)
        // Un PDF rogné et le même en texte redimensionnable sont deux copies distinctes.
        if book.format == .pdf, let mode = book.pdfMode, mode != .asIs {
            key += Data("\(mode.rawValue)-\(mode == .cropped ? PDFCrop.version : PDFReflow.version)".utf8)
        }
        // Copie pour une liseuse EPUB : distincte de celle de la Kindle (la clé de la Kindle ne change pas).
        if brand.readsEPUB { key += Data("liseuse-epub".utf8) }
        let variant = SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
        return directories.conversions.appendingPathComponent("\(book.fingerprint)-\(variant).\(book.sentExtension(for: brand))")
    }

    public static func exportedEPUB(of book: Book, directories: AppDirectories) -> URL {
        directories.conversions.appendingPathComponent("\(book.fingerprint).epub")
    }

    /// Conversion MOBI/AZW3 → EPUB vers un fichier temporaire du cache.
    public static func exportEPUB(_ book: Book, directories: AppDirectories) throws -> URL {
        let out = exportedEPUB(of: book, directories: directories)
        try MobiToEPUB.convert(input: book.url, output: out, edits: book.edits)
        return out
    }
}

// MARK: - Correction des livres de la Kindle

public enum KindleEditor {
    /// Formats dont les informations peuvent être réécrites dans le fichier.
    public static func canEdit(_ document: KindleDocument, info: KindleBookInfo?) -> Bool {
        ["mobi", "azw", "azw3", "prc"].contains(document.fileExtension)
            && info?.isGuessed != true && info?.isDRMProtected != true
    }

    /// Réécrit les informations d'un livre directement sur l'appareil.
    public static func update(_ document: KindleDocument, with edits: MetadataEdits, on device: any KindleDevice) throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("alexandrie-edit-\(UUID().uuidString).\(document.fileExtension)")
        defer { try? FileManager.default.removeItem(at: out) }
        try device.withLocalCopy(of: document) { try MobiMetadataWriter.rewrite($0, with: edits, to: out) }
        try device.replace(document, with: out)
    }
}
