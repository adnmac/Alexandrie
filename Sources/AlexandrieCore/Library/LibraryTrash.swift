import Foundation

/// Vidage de la corbeille d'Alexandrie : les fichiers partent dans la Corbeille de macOS,
/// où ils restent récupérables tant qu'elle n'est pas vidée.
public enum LibraryTrash {
    public typealias MoveToTrash = @Sendable (URL) throws -> Void

    public struct Result: Sendable {
        /// Fichiers placés dans la Corbeille de macOS (ou déjà absents du disque).
        public var removed: [Book.ID] = []
        /// Fichiers restés en place, avec la raison.
        public var failures: [(path: String, reason: String)] = []
    }

    public static let systemTrash: MoveToTrash = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public static func empty(_ books: [Book], moveToTrash: MoveToTrash = systemTrash) -> Result {
        var result = Result()
        for book in books {
            guard FileManager.default.fileExists(atPath: book.path) else {
                result.removed.append(book.id)
                continue
            }
            do {
                try moveToTrash(book.url)
                result.removed.append(book.id)
            } catch {
                result.failures.append((book.path, error.localizedDescription))
            }
        }
        return result
    }
}
