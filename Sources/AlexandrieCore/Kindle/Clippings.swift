import Foundation

/// Surlignement, note ou signet relevé sur la Kindle (fichier documents/My Clippings.txt).
public struct Clipping: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case highlight, note, bookmark
    }

    /// Stable d'un import à l'autre : le fichier de la Kindle ne fait que s'allonger.
    public var id: String { [ShelfSync.normalize(title), location, kind.rawValue, text].joined(separator: "|") }
    public var title: String
    public var author: String
    public var kind: Kind
    /// « page 12 · emplacement 180-182 », tel que noté par la Kindle.
    public var location: String
    /// Date telle qu'écrite par la Kindle (« mardi 3 novembre 2026 10:12:33 »).
    public var added: String
    /// Texte relevé sur la Kindle (sert à reconnaître le relevé ; jamais modifié).
    public var text: String
    /// Texte modifié dans Alexandrie, s'il l'a été.
    public var editedText: String?
    /// Supprimé dans Alexandrie : n'est plus affiché, et ne revient pas au prochain import.
    public var hidden: Bool?

    public init(title: String, author: String, kind: Kind, location: String, added: String, text: String) {
        self.title = title
        self.author = author
        self.kind = kind
        self.location = location
        self.added = added
        self.text = text
    }

    /// Texte affiché : la version modifiée si elle existe.
    public var displayText: String { editedText ?? text }
    public var isEdited: Bool { editedText != nil }
    public var isHidden: Bool { hidden == true }

    /// Premier nombre de l'emplacement (ou de la page) : ordre de lecture.
    public var position: Int {
        let digits = location.split(whereSeparator: { !$0.isNumber })
        let emplacement = location.range(of: "emplacement ").map { location[$0.upperBound...] }
        return Int(emplacement?.prefix { $0.isNumber } ?? digits.first ?? "") ?? Int.max
    }
}

/// Livre annoté : ses relevés visibles, pour la liste des livres de la vue Notes.
public struct ClippingBook: Identifiable, Hashable, Sendable {
    /// Titre normalisé (voir `ShelfSync.normalize`), qui rattache aussi le livre à la bibliothèque.
    public let id: String
    public let title: String
    public let author: String
    public let clippings: [Clipping]
    /// Rang du relevé le plus récent dans le fichier de la Kindle (plus grand = plus récent).
    public let latest: Int
}

public enum KindleClippings {
    public static let separator = "=========="

    /// Lit le contenu de My Clippings.txt (français ou anglais). Les signets, sans texte, sont gardés à part.
    public static func parse(_ content: String) -> [Clipping] {
        let normalized = content.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: separator).compactMap(entry)
    }

    static func entry(_ block: String) -> Clipping? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let titleIndex = lines.firstIndex(where: { !$0.isEmpty }), titleIndex + 1 < lines.count else { return nil }
        let (title, author) = splitTitle(lines[titleIndex])
        let meta = lines[titleIndex + 1]
        guard meta.hasPrefix("-") else { return nil }
        let text = lines.dropFirst(titleIndex + 2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = meta.lowercased()
        let kind: Clipping.Kind = lower.contains("signet") || lower.contains("bookmark") ? .bookmark
            : lower.contains("note") && !lower.contains("surlign") && !lower.contains("highlight") ? .note : .highlight
        let parts = meta.dropFirst().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        let addedPrefixes = ["Ajouté le ", "Added on "]
        let added = parts.first { p in addedPrefixes.contains { p.hasPrefix($0) } }
            .map { p in addedPrefixes.reduce(p) { $0.replacingOccurrences(of: $1, with: "") } } ?? ""
        let location = parts.filter { p in !addedPrefixes.contains { p.hasPrefix($0) } }
            .map(cleanLocation).filter { !$0.isEmpty }.joined(separator: " · ")
        guard kind == .bookmark || !text.isEmpty else { return nil }
        return Clipping(title: title, author: author, kind: kind, location: location, added: added, text: text)
    }

    /// « Le Rouge et le Noir (Stendhal) » → titre et auteur (dernières parenthèses).
    static func splitTitle(_ line: String) -> (String, String) {
        guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return (line, "") }
        return (String(line[..<open.lowerBound]), String(line[open.upperBound...].dropLast()))
    }

    /// « Votre surlignement sur la page 12 » → « page 12 » ; « emplacement 180-182 » reste tel quel.
    static func cleanLocation(_ part: String) -> String {
        for marker in ["sur la page ", "on page ", "à l'emplacement ", "à l’emplacement ", "at location ", "page ",
                       "emplacement ", "Location ", "location "] {
            if let r = part.range(of: marker) {
                let word = marker.contains("page") ? "page" : "emplacement"
                return word + " " + part[r.upperBound...]
            }
        }
        return ""
    }

    /// Livres annotés, le plus récemment annoté en tête (relevés supprimés exclus, signets exclus).
    public static func books(_ clippings: [Clipping]) -> [ClippingBook] {
        var order: [String] = []
        var grouped: [String: [Clipping]] = [:]
        var latest: [String: Int] = [:]
        for (i, c) in clippings.enumerated() where !c.isHidden && c.kind != .bookmark {
            let key = ShelfSync.normalize(c.title)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(c)
            latest[key] = i
        }
        return order.map { key in
            let list = grouped[key]!
            return ClippingBook(id: key, title: list[0].title, author: list[0].author, clippings: list, latest: latest[key] ?? 0)
        }
        .sorted { $0.latest > $1.latest }
    }

    /// Export Markdown des relevés d'un livre (texte modifié s'il existe).
    public static func markdown(title: String, author: String, clippings: [Clipping]) -> String {
        var out = "# \(title)\n"
        if !author.isEmpty { out += "\n*\(author)*\n" }
        for c in clippings {
            let meta = [c.kind == .note ? "Note" : "Surlignement", c.location, c.added].filter { !$0.isEmpty }
            out += "\n---\n\n" + (c.kind == .note ? "📝 " : "> ")
                + c.displayText.replacingOccurrences(of: "\n", with: c.kind == .note ? "\n" : "\n> ")
                + "\n\n<small>" + meta.joined(separator: " · ") + "</small>\n"
        }
        return out
    }

    /// Ajoute les relevés nouveaux (même identifiant = déjà connu), dans l'ordre du fichier.
    public static func merge(_ existing: [Clipping], _ new: [Clipping]) -> [Clipping] {
        var seen = Set(existing.map(\.id))
        return existing + new.filter { seen.insert($0.id).inserted }
    }

    public static func load(_ url: URL) -> [Clipping] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Clipping].self, from: data)) ?? []
    }

    public static func save(_ clippings: [Clipping], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(clippings).write(to: url, options: .atomic)
    }
}
