import CryptoKit
import Foundation

/// Fiche d'un livre présent sur la Kindle.
public struct KindleBookInfo: Codable, Hashable, Sendable {
    public var title: String
    public var authors: [String]
    public var format: String
    public var language: String?
    public var publisher: String?
    public var summary: String?
    public var publishedDate: String?
    public var isbn: String?
    public var isDRMProtected: Bool
    public var asin: String?
    /// Type de document Kindle (EBOK : livre acheté ou converti, PDOC : document personnel…).
    public var cdeType: String?
    public var coverKey: String?
    /// Vrai si le fichier n'a pas pu être analysé (KFX, format inconnu) : titre déduit du nom.
    public var isGuessed: Bool

    public var authorLine: String { authors.isEmpty ? "Auteur inconnu" : authors.joined(separator: ", ") }

    public var edits: MetadataEdits {
        MetadataEdits(title: title, authors: authors, publisher: publisher, language: language,
                      summary: summary, publishedDate: publishedDate, isbn: isbn)
    }
}

/// Lit les fiches des livres de la Kindle et les met en cache (clé : chemin + taille).
public final class KindleCatalog: @unchecked Sendable {
    public let covers: CoverStore
    private let cacheURL: URL
    private var cache: [String: KindleBookInfo]
    private let lock = NSLock()

    public init(directories: AppDirectories) {
        let coverDir = directories.base.appendingPathComponent("KindleCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        covers = CoverStore(directory: coverDir)
        // v3 : ajout du résumé, de la date de publication et de l'ISBN.
        cacheURL = directories.base.appendingPathComponent("kindle-catalog-v3.json")
        for old in ["kindle-catalog.json", "kindle-catalog-v2.json"] {
            try? FileManager.default.removeItem(at: directories.base.appendingPathComponent(old))
        }
        cache = (try? JSONDecoder().decode([String: KindleBookInfo].self, from: Data(contentsOf: cacheURL))) ?? [:]
    }

    static func key(_ doc: KindleDocument) -> String { "\(doc.path)|\(doc.size)" }

    public func cached(_ doc: KindleDocument) -> KindleBookInfo? {
        lock.withLock { cache[Self.key(doc)] }
    }

    /// Analyse un document (ou renvoie la fiche en cache).
    public func info(for doc: KindleDocument, on device: any KindleDevice) -> KindleBookInfo {
        if let hit = cached(doc) { return hit }
        var (info, cover): (KindleBookInfo, Data?) = (Self.guess(doc), nil)
        if Self.parsableExtensions.contains(doc.fileExtension),
           let read = try? device.withLocalCopy(of: doc, { try Self.read($0, format: doc.fileExtension) }) {
            (info, cover) = read
        }
        let coverKey = "k-" + Self.digest(Self.key(doc))
        if cover == nil, let asin = info.asin { cover = device.thumbnail(asin: asin) }
        if let cover, covers.store(cover, key: coverKey) { info.coverKey = coverKey }
        lock.withLock { cache[Self.key(doc)] = info }
        return info
    }

    public func save() {
        let snapshot = lock.withLock { cache }
        try? JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
    }

    public func coverURL(_ info: KindleBookInfo) -> URL? {
        info.coverKey.map(covers.url(for:))
    }

    // MARK: - Lecture

    static let parsableExtensions: Set<String> = ["mobi", "azw", "azw3", "prc", "pdf", "epub"]

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Fiche + image de couverture d'un fichier local.
    static func read(_ url: URL, format: String) throws -> (KindleBookInfo, Data?) {
        // Livre d'une Kobo ou d'une liseuse générique.
        if format == "epub" {
            let m = try EPUBReader(url: url).bookMetadata()
            let info = KindleBookInfo(title: m.title.isEmpty ? url.deletingPathExtension().lastPathComponent : m.title,
                                      authors: m.authors, format: "EPUB", language: m.language, publisher: m.publisher,
                                      summary: m.summary.map(MetadataExtractor.stripHTML), publishedDate: m.publishedDate,
                                      isbn: m.isbn, isDRMProtected: m.isDRMProtected, asin: nil, cdeType: nil,
                                      coverKey: nil, isGuessed: false)
            return (info, m.coverData)
        }
        if format == "pdf" {
            let m = try PDFMetadata.extract(from: url)
            let info = KindleBookInfo(title: m.title.isEmpty ? url.deletingPathExtension().lastPathComponent : m.title,
                                      authors: m.authors, format: "PDF", language: nil, publisher: nil,
                                      summary: nil, publishedDate: nil, isbn: nil,
                                      isDRMProtected: m.isDRMProtected, asin: nil, cdeType: nil,
                                      coverKey: nil, isGuessed: false)
            return (info, m.coverData)
        }
        // Les métadonnées EXTH et les images restent lisibles même sous DRM (seul le texte est chiffré).
        let book = try MobiBook(url: url)
        let m = book.metadata()
        let info = KindleBookInfo(title: m.title, authors: m.authors,
                                  format: book.hasKF8 ? "AZW3" : format.uppercased(), language: m.language,
                                  publisher: m.publisher, summary: m.summary.map(MetadataExtractor.stripHTML),
                                  publishedDate: m.publishedDate, isbn: m.isbn,
                                  isDRMProtected: m.isDRMProtected, asin: book.asin,
                                  cdeType: book.cdeType, coverKey: nil, isGuessed: false)
        return (info, m.coverData)
    }

    private static let asinPattern = try! NSRegularExpression(pattern: "(B0[0-9A-Z]{8})")

    /// Titre déduit du nom de fichier (ex. « Le_Titre-B0ABCDEFGH.kfx »), ASIN si présent.
    static func guess(_ doc: KindleDocument) -> KindleBookInfo {
        let base = (doc.name as NSString).deletingPathExtension
        let asin = asinPattern.firstGroups(in: doc.path)?[1]
        var title = base
        if let asin { title = title.replacingOccurrences(of: asin, with: "") }
        title = title.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        return KindleBookInfo(title: title.isEmpty ? base : title, authors: [], format: doc.fileExtension.uppercased(),
                              language: nil, publisher: nil, summary: nil, publishedDate: nil, isbn: nil, isDRMProtected: false,
                              asin: asin, cdeType: nil, coverKey: nil, isGuessed: true)
    }
}
