import Foundation

/// Surlignement, note ou signet relevé sur la Kindle (fichier documents/My Clippings.txt).
public struct Clipping: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case highlight, note, bookmark
    }

    /// Stable d'un import à l'autre : le fichier de la Kindle ne fait que s'allonger.
    /// Un surlignage fait dans l'app a son propre identifiant (`uid`).
    public var id: String { uid ?? [ShelfSync.normalize(title), location, kind.rawValue, text].joined(separator: "|") }
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
    /// Surlignage fait dans la fenêtre de lecture d'Alexandrie (S-070) ; absent pour un relevé de la Kindle.
    public var uid: String?
    /// Passage surligné dans l'app : livre, chapitre (ou page) et position dans son texte.
    public var anchor: ReaderAnchor?
    /// Note ajoutée dans Alexandrie à un surlignage (S-071), de la Kindle ou de l'app.
    public var note: String?
    /// Couleur choisie dans Alexandrie (S-073) ; absente = jaune.
    public var color: HighlightColor?
    /// Couleur ajoutée à une légende (« #RRGGBB »), à la place de `color` (S-079).
    public var hue: String?
    /// Thématiques du surlignage (S-079) ; voir `thematicIDs`.
    public var thematics: [String]?
    /// Recherche et thème d'avant S-079, repris par `ResearchList.migrate` puis effacés.
    public var research: String?
    public var theme: String?

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
    /// Fait dans Alexandrie plutôt que sur la Kindle.
    public var isFromApp: Bool { anchor != nil }
    /// Porte une note ajoutée dans Alexandrie (S-071).
    public var hasNote: Bool { !(note ?? "").isEmpty }
    /// Texte ou note contient la recherche.
    public func matches(_ query: String) -> Bool {
        displayText.localizedStandardContains(query) || (note ?? "").localizedStandardContains(query)
    }

    /// Premier nombre de l'emplacement (ou de la page) : ordre de lecture. Un surlignage de l'app
    /// donne l'emplacement Kindle estimé de son passage (ou sa page pour un PDF).
    public var position: Int {
        if let anchor { return anchor.order }
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

    /// Ordre de lecture : par position dans le livre, l'ordre d'ajout départageant les égalités.
    /// Les surlignages de l'app et ceux de la Kindle se mêlent ainsi (S-070).
    public static func readingOrder(_ clippings: [Clipping]) -> [Clipping] {
        clippings.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element)
    }

    /// Surlignages des marques choisies (S-074, S-077) : couleurs de base (« yellow ») ou thèmes (« theme:<id> ») ;
    /// ceux de la Kindle comptent comme jaunes. Les notes seules de la Kindle, sans couleur, ne sont gardées
    /// que sans filtre. Un ensemble vide ne filtre rien.
    public static func withMarks(_ clippings: [Clipping], _ keys: Set<String>, mark: (Clipping) -> String) -> [Clipping] {
        guard !keys.isEmpty else { return clippings }
        return clippings.filter { $0.kind == .highlight && keys.contains(mark($0)) }
    }

    /// Relevés rangés dans une des thématiques choisies (S-079) ; un ensemble vide ne filtre rien.
    /// `noThematic` dans `ids` garde aussi les relevés sans aucune thématique.
    public static func withThematics(_ clippings: [Clipping], _ ids: Set<String>) -> [Clipping] {
        guard !ids.isEmpty else { return clippings }
        return clippings.filter { c in
            !ids.isDisjoint(with: c.thematicIDs) || (ids.contains(noThematic) && c.thematicIDs.isEmpty)
        }
    }

    /// Choix « Sans thématique » du filtre des notes.
    public static let noThematic = "-"

    /// Export Markdown des relevés d'un livre (texte modifié s'il existe).
    /// `label` nomme la couleur ou le thème d'un surlignage (rien pour le jaune sans recherche).
    public static func markdown(title: String, author: String, clippings: [Clipping],
                                label: (Clipping) -> String? = { $0.color?.label }) -> String {
        var out = "# \(title)\n"
        if !author.isEmpty { out += "\n*\(author)*\n" }
        for c in clippings {
            let meta = [c.kind == .note ? String(localized: "Note") : String(localized: "Surlignement"), c.kind == .note ? "" : label(c) ?? "", c.location, c.added]
                .filter { !$0.isEmpty }
            out += "\n---\n\n" + (c.kind == .note ? "📝 " : "> ")
                + c.displayText.replacingOccurrences(of: "\n", with: c.kind == .note ? "\n" : "\n> ")
                + "\n\n" + (c.hasNote ? "📝 " + (c.note ?? "") + "\n\n" : "")
                + "<small>" + meta.joined(separator: " · ") + "</small>\n"
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
