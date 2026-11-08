import Foundation

/// Texte de la notification envoyée quand la file d'attente part sur la liseuse branchée.
/// Singulier et pluriel sont des textes distincts : chaque langue les traduit (catalogue de l'app).
public enum SendSummary {
    public static var title: String { String(localized: "Livres envoyés sur la liseuse") }

    /// - Parameters:
    ///   - sent: titres des livres arrivés sur la liseuse.
    ///   - failed: nombre de livres dont l'envoi a échoué (ils restent en attente).
    ///   - reader: nom de la liseuse, s'il est connu.
    /// - Returns: le corps de la notification, ou nil s'il n'y a rien à dire.
    public static func body(sent: [String], failed: Int, reader: String?) -> String? {
        switch (sent.count, failed) {
        case (0, 0):
            return nil
        case (0, let f):
            return f == 1 ? String(localized: "Échec de l'envoi de 1 livre") : String(localized: "Échec de l'envoi de \(f) livres")
        case (1, 0):
            return reader.map { String(localized: "« \(sent[0]) » envoyé sur « \($0) »") }
                ?? String(localized: "« \(sent[0]) » envoyé sur la liseuse")
        case (let n, 0):
            return reader.map { String(localized: "\(n) livres envoyés sur « \($0) »") }
                ?? String(localized: "\(n) livres envoyés sur la liseuse")
        case (let n, let f):
            let books = n == 1 ? String(localized: "1 livre envoyé") : String(localized: "\(n) livres envoyés")
            let failures = f == 1 ? String(localized: "1 échec") : String(localized: "\(f) échecs")
            return books + ", " + failures
        }
    }
}
