import Foundation

public enum BookFormat: String, Codable, CaseIterable, Sendable {
    case epub, mobi, azw3, azw, pdf

    public init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }

    public var label: String { rawValue.uppercased() }

    /// Formats lisibles par une Kindle chargée par USB.
    public var isKindleNative: Bool { self != .epub }
}

public enum BookError: LocalizedError, Equatable {
    case unreadable(String)
    case drmProtected
    case unsupported(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): String(localized: "Fichier illisible : \(why).")
        case .drmProtected: String(localized: "Ce livre est protégé par DRM : il ne peut pas être converti.")
        case .unsupported(let why): String(localized: "Non pris en charge : \(why).")
        case .conversionFailed(let why): String(localized: "La conversion a échoué : \(why).")
        }
    }
}

/// Métadonnées extraites d'un fichier de livre.
public struct BookMetadata: Sendable, Equatable {
    public var title: String
    public var authors: [String]
    public var language: String?
    public var publisher: String?
    public var summary: String?
    public var identifier: String?
    /// Date de publication brute (« 1759 », « 2024-03-15 »…).
    public var publishedDate: String?
    /// ISBN-13 valide trouvé dans les identifiants du fichier.
    public var isbn: String?
    public var subjects: [String] = []
    public var series: String?
    public var seriesIndex: Double?
    public var coverData: Data?
    public var isDRMProtected = false

    public var edits: MetadataEdits {
        MetadataEdits(title: title, authors: authors, publisher: publisher, language: language,
                      summary: summary, publishedDate: publishedDate, isbn: isbn,
                      series: series, seriesIndex: seriesIndex)
    }

    public mutating func apply(_ e: MetadataEdits) {
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

    public init(title: String, authors: [String] = [], language: String? = nil,
                publisher: String? = nil, summary: String? = nil, identifier: String? = nil) {
        self.title = title
        self.authors = authors
        self.language = language
        self.publisher = publisher
        self.summary = summary
        self.identifier = identifier
    }
}

/// Point d'entrée unique : extrait les métadonnées selon l'extension.
public enum MetadataExtractor {
    public static func extract(from url: URL) throws -> BookMetadata {
        guard let format = BookFormat(url: url) else {
            throw BookError.unsupported(String(localized: "extension .\(url.pathExtension)"))
        }
        var meta: BookMetadata
        switch format {
        case .epub: meta = try EPUBReader(url: url).bookMetadata()
        case .mobi, .azw3, .azw: meta = try MobiBook(url: url).metadata()
        case .pdf: meta = try PDFMetadata.extract(from: url)
        }
        if meta.title.trimmingCharacters(in: .whitespaces).isEmpty {
            meta.title = url.deletingPathExtension().lastPathComponent
        }
        meta.summary = meta.summary.map(stripHTML)
        (meta.series, meta.seriesIndex) = SeriesNames.normalized(meta.series, meta.seriesIndex)
        // « 2003-11-01T05:00:00+00:00 » → « 2003-11-01 » : l'heure n'a pas de sens pour une publication.
        if let d = meta.publishedDate, let t = d.firstIndex(of: "T"), d.distance(from: d.startIndex, to: t) == 10 {
            meta.publishedDate = String(d[..<t])
        }
        return meta
    }

    static func stripHTML(_ s: String) -> String {
        // Les balises de bloc séparent des mots ; les balises en ligne non.
        let blocks = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6])[^>]*>", with: " ",
                                            options: [.regularExpression, .caseInsensitive])
        let noTags = blocks.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = HTMLEntities.decode(noTags)
        return decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
