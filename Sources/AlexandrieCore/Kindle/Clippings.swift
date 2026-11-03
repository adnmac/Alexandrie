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
    public var text: String
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
