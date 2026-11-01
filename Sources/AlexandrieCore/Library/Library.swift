import CryptoKit
import Foundation

/// Livre indexé. Les champs `title`, `authors`, `tags` peuvent être modifiés dans l'app
/// sans jamais toucher au fichier source.
public struct Book: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var format: BookFormat
    public var fingerprint: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var addedAt: Date

    public var title: String
    public var authors: [String]
    public var language: String?
    public var publisher: String?
    public var summary: String?
    public var publishedDate: String?
    public var isbn: String?
    public var series: String?
    public var seriesIndex: Double?
    public var tags: [String]
    public var hasCover: Bool
    public var isDRMProtected: Bool
    public var isImported: Bool

    /// Identifiant stable utilisé comme ASIN lors de la conversion AZW3.
    public var asin: String
    public var lastSentAt: Date?
    public var sentFilename: String?
    /// Version de l'extraction : un livre indexé par une version antérieure est relu.
    public var metadataVersion: Int?

    /// Dernière notice trouvée en ligne (BnF / Open Library) et date de la vérification.
    public var catalogRecord: CatalogRecord?
    public var catalogCheckedAt: Date?
    /// Propositions écartées par l'utilisateur pour cette notice.
    public var catalogDismissed: Set<CatalogField>?
    /// Proposition de série lue dans le titre, écartée par l'utilisateur.
    public var seriesHintDismissed: Bool?

    /// Série et numéro lisibles dans le titre, s'ils diffèrent de ceux enregistrés.
    public var seriesHint: SeriesNames.TitleHint? {
        guard seriesHintDismissed != true,
              let h = SeriesNames.hint(title: title, currentSeries: series) else { return nil }
        let sameSeries = h.series.map { series.map(SeriesNames.key) == SeriesNames.key($0) } ?? true
        return sameSeries && seriesIndex == h.index ? nil : h
    }

    /// Propositions du catalogue encore en attente de décision.
    public var catalogSuggestions: [CatalogDifference] {
        guard let r = catalogRecord else { return [] }
        let dismissed = catalogDismissed ?? []
        return CatalogComparison.differences(edits, r).filter { !dismissed.contains($0.field) }
    }

    public static let currentMetadataVersion = 4

    public var url: URL { URL(fileURLWithPath: path) }
    public var authorLine: String { authors.isEmpty ? "Auteur inconnu" : authors.joined(separator: ", ") }

    /// Informations corrigeables, appliquées aux copies envoyées sur la Kindle.
    public var edits: MetadataEdits {
        get {
            MetadataEdits(title: title, authors: authors, publisher: publisher, language: language,
                          summary: summary, publishedDate: publishedDate, isbn: isbn,
                          series: series, seriesIndex: seriesIndex)
        }
        set {
            let e = newValue
            title = e.title
            authors = e.authors
            publisher = e.publisher
            language = e.language
            summary = e.summary
            publishedDate = e.publishedDate
            isbn = e.isbn
            series = e.series
            seriesIndex = e.seriesIndex
        }
    }

    /// Nom proposé pour la copie sur la Kindle.
    public var kindleFilename: String {
        let ext = format == .epub ? "azw3" : format.rawValue
        let author = authors.first.map { " - \($0)" } ?? ""
        return "\(title)\(author)".safeFilename + ".\(ext)"
    }
}

/// Fichier trouvé sur disque, avant extraction des métadonnées.
public struct ScannedFile: Sendable {
    public let url: URL
    public let size: Int64
    public let modifiedAt: Date
    /// Arrivée du fichier dans son dossier (copie, téléchargement, import) : sert de date d'ajout.
    public var addedAt = Date()
}

public enum FolderScanner {
    /// Parcours récursif, sans suivre les paquets ni les fichiers cachés.
    public static func scan(_ roots: [URL]) -> [ScannedFile] {
        var out: [ScannedFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                      .addedToDirectoryDateKey, .creationDateKey]
        for root in roots {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                guard BookFormat(url: url) != nil,
                      let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                out.append(ScannedFile(url: url.standardizedFileURL, size: Int64(v.fileSize ?? 0),
                                       modifiedAt: v.contentModificationDate ?? .distantPast,
                                       addedAt: v.addedToDirectoryDate ?? v.creationDate ?? Date()))
            }
        }
        return out
    }

    /// Empreinte rapide : taille + SHA-256 des 64 premiers Ko.
    public static func fingerprint(_ url: URL, size: Int64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "\(size)" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 65_536)) ?? Data()
        let digest = SHA256.hash(data: head).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-\(size)"
    }

    public static func makeBook(_ file: ScannedFile, imported: Bool, coverStore: CoverStore) -> Book {
        let format = BookFormat(url: file.url)!
        let fingerprint = fingerprint(file.url, size: file.size)
        let meta = (try? MetadataExtractor.extract(from: file.url))
            ?? BookMetadata(title: file.url.deletingPathExtension().lastPathComponent)
        var hasCover = false
        if let cover = meta.coverData {
            hasCover = coverStore.store(cover, key: fingerprint)
        }
        return Book(path: file.url.path, format: format, fingerprint: fingerprint, fileSize: file.size,
                    modifiedAt: file.modifiedAt, addedAt: file.addedAt, title: meta.title, authors: meta.authors,
                    language: meta.language, publisher: meta.publisher, summary: meta.summary,
                    publishedDate: meta.publishedDate, isbn: meta.isbn, series: meta.series, seriesIndex: meta.seriesIndex, tags: meta.subjects,
                    hasCover: hasCover, isDRMProtected: meta.isDRMProtected, isImported: imported,
                    asin: EPUBToAZW3.makeASIN(), metadataVersion: Book.currentMetadataVersion)
    }
}

/// Dossiers de travail de l'app (jamais dans le dossier de livres de l'utilisateur).
public struct AppDirectories: Sendable {
    public let base: URL

    public init(base: URL? = nil) {
        self.base = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alexandrie", isDirectory: true)
        for d in [covers, conversions, imports] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    public var index: URL { base.appendingPathComponent("library.json") }
    public var covers: URL { base.appendingPathComponent("Covers", isDirectory: true) }
    public var conversions: URL { base.appendingPathComponent("Conversions", isDirectory: true) }
    /// Livres ajoutés par glisser-déposer : copiés ici, pas dans le dossier source.
    public var imports: URL { base.appendingPathComponent("Imports", isDirectory: true) }
}

public struct CoverStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func url(for key: String) -> URL { directory.appendingPathComponent("\(key).jpg") }

    /// Stocke une couverture réduite (600 px) ; renvoie false si l'image est illisible.
    @discardableResult
    public func store(_ data: Data, key: String) -> Bool {
        let target = url(for: key)
        if FileManager.default.fileExists(atPath: target.path) { return true }
        guard let jpeg = ImageTools.jpeg(data, maxPixelSize: 600) else { return false }
        return (try? jpeg.write(to: target, options: .atomic)) != nil
    }

    /// Miniature au format attendu par la Kindle (system/thumbnails).
    public func kindleThumbnail(key: String) -> Data? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return ImageTools.jpeg(data, maxPixelSize: 500, quality: 0.9)
    }
}

/// Persistance de l'index en JSON.
public enum LibraryIndex {
    public static func load(_ url: URL) -> [Book] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([Book].self, from: data)) ?? []
    }

    public static func save(_ books: [Book], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(books).write(to: url, options: .atomic)
    }
}
