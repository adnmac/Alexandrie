import Foundation
import PDFKit

/// Texte d'un livre pour la recherche dans le contenu (S-081) : un morceau par chapitre (EPUB, MOBI,
/// AZW3) ou par page (PDF), sans balises. Gardé dans les données de l'app, jamais dans le dossier de livres.
public struct BookText: Equatable, Sendable {
    /// Chapitres (fichiers du spine) ou pages d'un PDF, dans l'ordre de lecture.
    public var sections: [String]

    public init(sections: [String]) {
        self.sections = sections
    }

    /// Formats dont le texte est lu (un livre protégé ne l'est pas).
    public static func canExtract(_ book: Book) -> Bool {
        !book.isDRMProtected && [.epub, .mobi, .azw3, .pdf].contains(book.format)
    }

    /// Un seul fichier par livre (S-081) : parmi les fichiers lisibles d'un même livre, l'EPUB d'abord
    /// (pas de conversion), puis AZW3, MOBI et PDF. Les livres sans fichier lisible n'en donnent aucun.
    public static func filesToIndex(_ books: [Book], identities: [Book.ID: String]) -> [Book] {
        let rank: [BookFormat: Int] = [.epub: 0, .azw3: 1, .mobi: 2, .pdf: 3]
        return BookGroups.make(books, identities: identities).compactMap { group in
            group.books.filter(canExtract).min { (rank[$0.format] ?? 9, $0.path) < (rank[$1.format] ?? 9, $1.path) }
        }
    }

    /// Lit le texte du livre. MOBI et AZW3 passent par une conversion en EPUB dans un dossier temporaire.
    public static func extract(_ book: Book) throws -> BookText {
        guard canExtract(book) else {
            throw book.isDRMProtected ? BookError.drmProtected : BookError.unsupported("format \(book.format.label)")
        }
        if book.format == .pdf {
            guard let document = PDFDocument(url: book.url) else { throw BookError.unsupported("PDF illisible") }
            return BookText(sections: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" })
        }
        var url = book.url
        var temporary: URL?
        if book.format != .epub {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("foluna-texte-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            temporary = folder
            url = folder.appendingPathComponent("livre.epub")
            try MobiToEPUB.convert(input: book.url, output: url)
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let epub = try EPUBReader(url: url)
        return BookText(sections: epub.spine.map { item in (try? epub.data(item.path)).map(plainText) ?? "" })
    }

    /// Texte d'un fichier XHTML : celui que la page affiche (`textContent` du corps), sans balises,
    /// scripts ni styles, entités décodées. Les blancs sont gardés : les passages se retrouvent ainsi
    /// dans le même ordre que dans la fenêtre de lecture.
    public static func plainText(_ data: Data) -> String {
        var html = String(decoding: data, as: UTF8.self)
        if let body = html.range(of: "<body", options: .caseInsensitive) { html = String(html[body.lowerBound...]) }
        var out = ""
        out.reserveCapacity(html.utf8.count / 2)
        var i = html.startIndex
        while i < html.endIndex {
            let c = html[i]
            if c == "<" {
                // Script, style : tout le contenu est sauté.
                for tag in ["script", "style"] {
                    let open = "<" + tag
                    if html[i...].prefix(open.count).lowercased() == open,
                       let close = html.range(of: "</" + tag, options: .caseInsensitive, range: i..<html.endIndex) {
                        i = close.lowerBound
                        break
                    }
                }
                guard let end = html[i...].firstIndex(of: ">") else { break }
                i = html.index(after: end)
            } else if c == "&", let semi = html[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(html[html.index(after: i)..<semi])
                if let decoded = decode(entity) {
                    out.append(decoded)
                    i = html.index(after: semi)
                } else {
                    out.append(c)
                    i = html.index(after: i)
                }
            } else {
                out.append(c)
                i = html.index(after: i)
            }
        }
        return out
    }

    static func decode(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{A0}"
        default:
            if let named = named[entity] { return named }
            let number: UInt32?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") { number = UInt32(entity.dropFirst(2), radix: 16) }
            else if entity.hasPrefix("#") { number = UInt32(entity.dropFirst()) }
            else { return nil }
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    /// Entités nommées du HTML que l'on croise dans les livres français (les autres restent telles quelles).
    static let named: [String: String] = {
        var table = ["laquo": "«", "raquo": "»", "hellip": "…", "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”",
                     "mdash": "—", "ndash": "–", "oelig": "œ", "OElig": "Œ", "aelig": "æ", "AElig": "Æ", "thinsp": "\u{2009}",
                     "deg": "°", "copy": "©", "shy": "\u{AD}"]
        for (base, accents) in [("a", "grave:à acute:á circ:â uml:ä tilde:ã"), ("e", "grave:è acute:é circ:ê uml:ë"),
                                ("i", "grave:ì acute:í circ:î uml:ï"), ("o", "grave:ò acute:ó circ:ô uml:ö tilde:õ"),
                                ("u", "grave:ù acute:ú circ:û uml:ü"), ("y", "acute:ý uml:ÿ"), ("n", "tilde:ñ"), ("c", "cedil:ç")] {
            for pair in accents.split(separator: " ") {
                let parts = pair.split(separator: ":").map(String.init)
                table[base + parts[0]] = parts[1]
                table[base.uppercased() + parts[0]] = parts[1].uppercased()
            }
        }
        return table
    }()

    // MARK: Enregistrement

    /// Séparateur des sections dans le fichier (caractère « séparateur d'enregistrements », absent des livres).
    static let separator = "\u{1E}"

    public static func url(of fingerprint: String, in directories: AppDirectories) -> URL {
        directories.texts.appendingPathComponent(fingerprint + ".txt")
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sections.joined(separator: Self.separator).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func load(_ url: URL) -> BookText? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return BookText(sections: text.components(separatedBy: separator))
    }

    /// Tout le texte, pour l'index.
    public var joined: String { sections.joined(separator: "\n") }
}

/// Recherche dans le contenu : forme de comparaison et extraits (S-082).
public enum ContentSearch {
    /// Forme indexée et cherchée : sans accents ni majuscules, apostrophes typographiques ramenées à « ' ».
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Mots d'une recherche (au moins deux lettres), repliés.
    public static func terms(_ query: String) -> [String] {
        fold(query).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    }

    /// Requête SearchKit : tous les mots, le dernier aussi en début de mot (on tape encore).
    public static func indexQuery(_ query: String) -> String? {
        let words = terms(query)
        guard let last = words.last else { return nil }
        return (words.dropLast() + [last + "*"]).joined(separator: " ")
    }

    /// Un passage trouvé : la section, le texte autour, et de quoi le retrouver dans la page.
    public struct Snippet: Hashable, Sendable {
        public let section: Int
        public let before: String
        /// Le texte trouvé, tel qu'écrit dans le livre.
        public let match: String
        public let after: String
        /// Rang de ce même texte (`match`, à l'identique) dans la section : la fenêtre de lecture y saute.
        public let occurrence: Int
    }

    public struct Match: Sendable {
        public let count: Int
        public let snippets: [Snippet]
    }

    /// Passages d'un livre : l'expression entière si elle s'y trouve, sinon son premier mot.
    /// Sans tenir compte des accents ni des majuscules, sauf en écriture `exact` (S-084) où « Odyssée »
    /// ne trouve pas « odyssée » ; `limit` extraits au plus, dans l'ordre du livre.
    public static func matches(in text: BookText, query: String, limit: Int = 3, context: Int = 70,
                               exact: Bool = false) -> Match {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return Match(count: 0, snippets: []) }
        let options: String.CompareOptions = exact ? [] : [.caseInsensitive, .diacriticInsensitive]
        let needle = text.sections.contains { $0.range(of: phrase, options: options) != nil } ? phrase
            : (phrase.components(separatedBy: .whitespaces).first { $0.count >= 2 } ?? phrase)
        var count = 0
        var snippets: [Snippet] = []
        for (index, section) in text.sections.enumerated() {
            var start = section.startIndex
            var seen: [String: Int] = [:]
            while let r = section.range(of: needle, options: options, range: start..<section.endIndex) {
                count += 1
                let match = String(section[r])
                // Rang exact dans la section, compté sur les occurrences identiques qui précèdent.
                let occurrence = seen[match, default: 0]
                seen[match] = occurrence + 1
                if snippets.count < limit {
                    let from = section.index(r.lowerBound, offsetBy: -context, limitedBy: section.startIndex) ?? section.startIndex
                    let to = section.index(r.upperBound, offsetBy: context, limitedBy: section.endIndex) ?? section.endIndex
                    snippets.append(Snippet(section: index, before: tidy(section[from..<r.lowerBound], leading: from > section.startIndex),
                                            match: match, after: tidy(section[r.upperBound..<to], trailing: to < section.endIndex),
                                            occurrence: occurrence))
                }
                start = r.upperBound
            }
        }
        return Match(count: count, snippets: snippets)
    }

    /// Blancs ramenés à une espace, points de suspension là où l'extrait coupe le texte.
    static func tidy(_ s: Substring, leading: Bool = false, trailing: Bool = false) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let spaced = (s.first?.isWhitespace == true ? " " : "") + flat + (s.last?.isWhitespace == true ? " " : "")
        return (leading ? "…" : "") + spaced + (trailing ? "…" : "")
    }
}
