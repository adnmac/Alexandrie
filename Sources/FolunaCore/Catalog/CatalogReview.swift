import Foundation

/// Revue en lot des propositions du catalogue : une ligne par livre et par champ proposé.
public enum CatalogReview {
    public struct Row: Identifiable, Hashable, Sendable {
        public var id: String { book.id + "|" + difference.field.rawValue }
        /// Fichier principal du livre (complété par ses autres fichiers, comme dans la fiche).
        public let book: Book
        /// Tous les fichiers du livre : une correction s'applique à chacun.
        public let fileIDs: [Book.ID]
        public let difference: CatalogDifference
    }

    /// Lignes à revoir, dans l'ordre des livres puis des champs proposés.
    public static func rows(_ groups: [BookGroup]) -> [Row] {
        groups.flatMap { g -> [Row] in
            let primary = g.primary
            return primary.catalogSuggestions.map { Row(book: primary, fileIDs: g.books.map(\.id), difference: $0) }
        }
    }

    /// Champs retenus par livre (identifiant du fichier principal → champs).
    public static func fieldsByBook(_ rows: [Row]) -> [Book.ID: (book: Book, fileIDs: [Book.ID], fields: Set<CatalogField>)] {
        var out: [Book.ID: (book: Book, fileIDs: [Book.ID], fields: Set<CatalogField>)] = [:]
        for r in rows {
            out[r.book.id, default: (r.book, r.fileIDs, [])].fields.insert(r.difference.field)
        }
        return out
    }
}
