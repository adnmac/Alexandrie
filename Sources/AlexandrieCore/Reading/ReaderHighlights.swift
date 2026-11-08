import Foundation

/// Passage surligné dans la fenêtre de lecture (S-070). Le fichier du livre n'est jamais modifié :
/// le passage est repéré par sa position dans le texte du chapitre (EPUB) ou de la page (PDF).
public struct ReaderAnchor: Codable, Hashable, Sendable {
    /// Empreinte du livre (`Book.fingerprint`).
    public var book: String
    /// Index du chapitre (fichier du spine) ou de la page d'un PDF.
    public var chapter: Int
    /// Début et fin du passage, en unités UTF-16 du texte du chapitre (`textContent` du corps) ou de la page.
    public var start: Int
    public var end: Int
    /// Rang dans le livre, comparable aux relevés de la Kindle : emplacement estimé, ou numéro de page d'un PDF.
    public var order: Int

    public init(book: String, chapter: Int, start: Int, end: Int, order: Int) {
        self.book = book
        self.chapter = chapter
        self.start = start
        self.end = end
        self.order = order
    }

    /// Octets de texte par emplacement Kindle.
    public static let bytesPerLocation = 150

    /// Emplacement Kindle estimé d'un passage d'EPUB : la Kindle compte un emplacement par 150 octets
    /// du livre, ici approchés par la taille des chapitres précédents et la part du chapitre déjà lue.
    public static func estimatedLocation(chapter: Int, offset: Int, textLength: Int, weights: [Int]) -> Int {
        guard weights.indices.contains(chapter) else { return 1 }
        let before = weights[..<chapter].reduce(0, +)
        let within = textLength > 0 ? Double(weights[chapter]) * Double(min(max(offset, 0), textLength)) / Double(textLength) : 0
        return (before + Int(within)) / bytesPerLocation + 1
    }
}

/// Couleur d'un surlignage (S-073). Gardée dans Alexandrie : la Kindle n'en a pas.
public enum HighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow, green, blue, pink, purple

    public var id: Self { self }

    public var label: String {
        switch self {
        case .yellow: String(localized: "Jaune")
        case .green: String(localized: "Vert")
        case .blue: String(localized: "Bleu")
        case .pink: String(localized: "Rose")
        case .purple: String(localized: "Violet")
        }
    }
}

public extension Clipping {
    /// Couleur du surlignage ; jaune par défaut, comme sur la Kindle.
    var highlightColor: HighlightColor { color ?? .yellow }

    /// Surlignage fait dans la fenêtre de lecture. `location` se lit comme celui de la Kindle
    /// (« chapitre 3 », « page 12 ») ; la date est écrite à sa manière (« vendredi 6 novembre 2026 18:12:33 »).
    static func readerHighlight(title: String, author: String, text: String, anchor: ReaderAnchor, isPDF: Bool,
                                color: HighlightColor = .yellow, date: Date = Date(),
                                uid: String = UUID().uuidString) -> Clipping {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM yyyy HH:mm:ss"
        var clipping = Clipping(title: title, author: author, kind: .highlight,
                                location: (isPDF ? "page " : "chapitre ") + "\(anchor.chapter + 1)",
                                added: formatter.string(from: date), text: text)
        clipping.uid = uid
        clipping.anchor = anchor
        clipping.color = color == .yellow ? nil : color
        return clipping
    }
}
