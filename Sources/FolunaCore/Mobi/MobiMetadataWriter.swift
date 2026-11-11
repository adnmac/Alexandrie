import Foundation

/// Informations corrigeables d'un livre (bibliothèque ou Kindle).
public struct MetadataEdits: Codable, Hashable, Sendable {
    public var title: String
    public var authors: [String]
    public var publisher: String?
    public var language: String?
    public var summary: String?
    /// Date de publication telle que saisie (ex. « 1759 », « 2024-03-15 »).
    public var publishedDate: String?
    public var isbn: String?
    public var series: String?
    public var seriesIndex: Double?
    /// Genre (« Roman », « Roman policier »…), conservé dans Foluna.
    public var genre: String?

    public init(title: String, authors: [String], publisher: String? = nil, language: String? = nil,
                summary: String? = nil, publishedDate: String? = nil, isbn: String? = nil,
                series: String? = nil, seriesIndex: Double? = nil, genre: String? = nil) {
        self.title = title
        self.authors = authors
        self.publisher = publisher
        self.language = language
        self.summary = summary
        self.publishedDate = publishedDate
        self.isbn = isbn
        self.series = series
        self.seriesIndex = seriesIndex
        self.genre = genre
    }

    /// Valeurs vides → nil, espaces superflus retirés.
    public var normalized: MetadataEdits {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        return MetadataEdits(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                             authors: authors.compactMap(clean), publisher: clean(publisher),
                             language: clean(language), summary: clean(summary), publishedDate: clean(publishedDate),
                             isbn: clean(isbn).map { ISBN.normalized($0) ?? $0 },
                             series: clean(series), seriesIndex: clean(series) == nil ? nil : seriesIndex)
    }
}

/// Réécrit les métadonnées (EXTH, titre complet, langue) d'un MOBI/AZW/AZW3 sans toucher au texte.
public enum MobiMetadataWriter {
    /// Types EXTH remplacés par les corrections ; les autres (ASIN, couverture, type…) sont conservés.
    static let editedTypes: Set<Int> = [100, 101, 103, 104, 106, 503, 524]

    public static func rewrite(_ url: URL, with edits: MetadataEdits, to output: URL) throws {
        let data = try rewrite([UInt8](Data(contentsOf: url)), with: edits)
        try Data(data).write(to: output, options: .atomic)
    }

    public static func rewrite(_ bytes: [UInt8], with edits: MetadataEdits) throws -> [UInt8] {
        let book = try MobiBook(data: Data(bytes))
        // Sous DRM, l'enregistrement 0 contient les clés : le modifier rendrait le livre illisible.
        guard !book.isDRMProtected else { throw BookError.drmProtected }
        let e = edits.normalized
        guard !e.title.isEmpty else { throw BookError.conversionFailed(String(localized: "le titre ne peut pas être vide")) }

        var records = book.records
        var headers = [book.kf7]
        if let kf8 = book.kf8, kf8.start != book.kf7.start { headers.append(kf8) }
        for h in headers {
            records[h.start] = rewriteHeader(h, edits: e)
        }
        return rebuildDatabase(original: bytes, records: records, title: e.title)
    }

    private static func rewriteHeader(_ h: MobiHeader, edits e: MetadataEdits) -> [UInt8] {
        var exth: [(Int, [UInt8])] = []
        // Ordre d'origine conservé pour les types non modifiés.
        let base = 16 + h.headerLength
        if h.raw.u32(0x80) & 0x40 != 0, h.raw.slice(base, 4) == Array("EXTH".utf8) {
            var pos = base + 12
            for _ in 0..<h.raw.u32(base + 8) {
                let type = h.raw.u32(pos), len = h.raw.u32(pos + 4)
                guard len >= 8 else { break }
                if !editedTypes.contains(type) { exth.append((type, h.raw.slice(pos + 8, len - 8))) }
                pos += len
            }
        }
        func add(_ type: Int, _ value: String?) {
            if let v = value, !v.isEmpty { exth.append((type, Array(v.utf8))) }
        }
        for a in e.authors { add(100, a) }
        add(101, e.publisher)
        add(103, e.summary)
        add(104, e.isbn)
        add(106, e.publishedDate)
        add(503, e.title)
        add(524, e.language)

        var body: [UInt8] = []
        for (type, value) in exth {
            body.appendBE32(type)
            body.appendBE32(8 + value.count)
            body += value
        }
        var exthBlock = Array("EXTH".utf8)
        exthBlock.appendBE32(12 + body.count)
        exthBlock.appendBE32(exth.count)
        exthBlock += body
        exthBlock += [UInt8](repeating: 0, count: 4 - exthBlock.count % 4)

        // En-tête PalmDoc + MOBI inchangé, puis EXTH, titre complet et remplissage.
        var header = Array(h.raw.prefix(base))
        let title = h.isUTF8 ? Array(e.title.utf8)
            : [UInt8](e.title.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(e.title.utf8))
        let titleOffset = base + exthBlock.count
        set32(&header, 0x54, titleOffset)
        set32(&header, 0x58, title.count)
        set32(&header, 0x80, h.raw.u32(0x80) | 0x40)
        if let lang = e.language, h.headerLength + 16 > 0x60 {
            set32(&header, 0x5C, MobiLanguage.code(lang))
        }
        var out = header + exthBlock + title + [0, 0]
        out += [UInt8](repeating: 0, count: (4 - out.count % 4) % 4)
        // Marge habituelle (kindlegen/calibre) pour les outils qui enrichissent l'en-tête.
        return out + [UInt8](repeating: 0, count: 1024)
    }

    private static func set32(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        b[o] = UInt8((v >> 24) & 0xFF); b[o + 1] = UInt8((v >> 16) & 0xFF)
        b[o + 2] = UInt8((v >> 8) & 0xFF); b[o + 3] = UInt8(v & 0xFF)
    }

    /// Recopie l'en-tête PalmDB (nom mis à jour) et recalcule les offsets des enregistrements.
    private static func rebuildDatabase(original: [UInt8], records: [[UInt8]], title: String) -> [UInt8] {
        var out = Array(original.prefix(78))
        let ascii = title.folding(options: .diacriticInsensitive, locale: nil).unicodeScalars
            .map { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil) ? String($0) : "_" }
            .joined()
        var name = Array(ascii.utf8.prefix(31))
        name += [UInt8](repeating: 0, count: 32 - name.count)
        out.replaceSubrange(0..<32, with: name)
        var offset = 78 + 8 * records.count + 2
        for (i, r) in records.enumerated() {
            out.appendBE32(offset)
            out += original.slice(78 + 8 * i + 4, 4)   // attributs + identifiant d'origine
            offset += r.count
        }
        out += [0, 0]
        for r in records { out += r }
        return out
    }
}

/// Code de langue MOBI (LCID simplifié).
enum MobiLanguage {
    static func code(_ lang: String?) -> Int {
        let primary = (lang ?? "").lowercased().split(separator: "-").first.map(String.init) ?? ""
        let table: [String: Int] = [
            "en": 9, "fr": 12, "de": 7, "es": 10, "it": 16, "nl": 19, "pt": 22, "ru": 25, "ja": 17,
            "zh": 4, "ko": 18, "sv": 29, "da": 6, "fi": 11, "no": 20, "nb": 20, "pl": 21, "cs": 5,
            "el": 8, "tr": 31, "ca": 3, "ar": 1, "he": 13, "hu": 14,
        ]
        return table[primary] ?? 0
    }
}
