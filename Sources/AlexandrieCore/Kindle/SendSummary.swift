import Foundation

/// Texte de la notification envoyée quand la file d'attente part sur la Kindle branchée.
public enum SendSummary {
    public static let title = "Livres envoyés sur la Kindle"

    /// - Parameters:
    ///   - sent: titres des livres arrivés sur la Kindle.
    ///   - failed: nombre de livres dont l'envoi a échoué (ils restent en attente).
    ///   - reader: nom de la liseuse, s'il est connu.
    /// - Returns: le corps de la notification, ou nil s'il n'y a rien à dire.
    public static func body(sent: [String], failed: Int, reader: String?) -> String? {
        let destination = reader.map { "sur « \($0) »" } ?? "sur la Kindle"
        switch (sent.count, failed) {
        case (0, 0):
            return nil
        case (0, let f):
            return "Échec de l'envoi de \(books(f))"
        case (1, 0):
            return "« \(sent[0]) » envoyé \(destination)"
        case (let n, 0):
            return "\(n) livres envoyés \(destination)"
        case (let n, let f):
            return "\(n) \(n == 1 ? "livre envoyé" : "livres envoyés"), \(f) \(f == 1 ? "échec" : "échecs")"
        }
    }

    private static func books(_ n: Int) -> String { n == 1 ? "1 livre" : "\(n) livres" }
}
