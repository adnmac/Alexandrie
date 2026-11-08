import Foundation

/// Note Zotero (HTML) des passages d'un livre : citation, note, puis couleur, thématiques, position et date.
/// Même contenu que l'export Markdown (`KindleClippings.markdown`).
public enum ZoteroNote {
    public struct Passage: Sendable, Equatable {
        public var clipping: Clipping
        /// Couleur nommée (« Jaune », « Construction »), nil pour le jaune sans légende.
        public var colorName: String?
        public var thematics: [String]

        public init(clipping: Clipping, colorName: String? = nil, thematics: [String] = []) {
            self.clipping = clipping
            self.colorName = colorName
            self.thematics = thematics
        }
    }

    /// `heading` : « Notes d'Alexandrie » ou le nom d'une thématique.
    public static func html(heading: String, title: String, author: String, passages: [Passage], sentAt: Date = Date()) -> String {
        let date = sentAt.formatted(date: .long, time: .shortened)
        var out = "<h1>\(escape(heading)) — \(escape(title))</h1>\n"
        let count = passages.count
        let sent = count == 1 ? String(localized: "1 passage, envoyé depuis Foluna le \(date)")
            : String(localized: "\(count) passages, envoyés depuis Foluna le \(date)")
        out += "<p><em>\(author.isEmpty ? "" : escape(author) + " · ")\(escape(sent))</em></p>\n"
        let ordered = KindleClippings.readingOrder(passages.map(\.clipping))
        let byID = Dictionary(passages.map { ($0.clipping.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in ordered {
            guard let p = byID[c.id] else { continue }
            out += "<hr/>\n"
            if c.kind == .note {
                out += "<p>📝 \(paragraphs(c.displayText))</p>\n"
            } else {
                out += "<blockquote><p>\(paragraphs(c.displayText))</p></blockquote>\n"
            }
            if let note = c.note, c.hasNote { out += "<p>📝 \(paragraphs(note))</p>\n" }
            let meta = [c.kind == .note ? "Note" : p.colorName ?? "", p.thematics.joined(separator: ", "), c.location, c.added]
                .filter { !$0.isEmpty }
            out += "<p><small>\(meta.map(escape).joined(separator: " · "))</small></p>\n"
        }
        return out
    }

    /// Texte échappé, retours à la ligne en `<br/>`.
    static func paragraphs(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\n", with: "<br/>")
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Correspondances avec Zotero (`zotero.json`) : référence et note de chaque livre, note de chaque thématique.
public struct ZoteroLinks: Codable, Equatable, Sendable {
    public struct Link: Codable, Equatable, Sendable {
        public var itemKey: String
        public var noteKey: String?
        public var noteVersion: Int?
        public var sentAt: Date?

        public init(itemKey: String, noteKey: String? = nil, noteVersion: Int? = nil, sentAt: Date? = nil) {
            self.itemKey = itemKey
            self.noteKey = noteKey
            self.noteVersion = noteVersion
            self.sentAt = sentAt
        }
    }

    /// Clé de livre (`ShelfSync.normalize(title)`) → référence et note « Notes d'Alexandrie ».
    public var books: [String: Link] = [:]
    /// « <thématique>|<clé de livre> » → note de la thématique pour ce livre.
    public var thematicNotes: [String: Link] = [:]
    /// Serveur Zotero des correspondances : une autre bibliothèque (autre Mac) repart de zéro.
    public var serverID: String?

    public init() {}

    public static func thematicKey(_ thematic: String, book: String) -> String { thematic + "|" + book }

    public static func load(_ url: URL) -> ZoteroLinks {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(ZoteroLinks.self, from: $0) } ?? ZoteroLinks()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
