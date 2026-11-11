import Foundation

/// Rapprochement entre l'étagère d'une liseuse et les livres présents sur la Kindle.
public enum ShelfSync {
    /// Titre réduit à ses lettres et chiffres, sans casse ni accents (titres de la bibliothèque et de l'appareil).
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    /// Un livre est sur l'appareil si l'un de ses fichiers y porte son nom d'envoi, ou si son titre y figure.
    public static func isOnDevice(_ files: [Book], documentNames: Set<String>, deviceTitles: Set<String>) -> Bool {
        files.contains { b in
            documentNames.contains(b.kindleFilename) || b.sentFilename.map(documentNames.contains) == true
                || deviceTitles.contains(normalize(b.title))
        }
    }

    /// Livres de l'étagère à envoyer : absents de l'appareil et envoyables (un EPUB sous DRM ne l'est pas).
    /// Un livre par groupe : son fichier principal, celui qui part sur la Kindle.
    public static func missing(_ shelf: [BookGroup], documentNames: Set<String>, deviceTitles: Set<String>) -> [Book] {
        shelf.filter { !isOnDevice($0.books, documentNames: documentNames, deviceTitles: deviceTitles) }
            .map(\.primary)
            .filter(\.canSendToKindle)
    }
}
