import Foundation

/// En-tête `User-Agent` de toutes les requêtes de Foluna (catalogues, couvertures, mises à jour) :
/// le nom et la version de l'app, rien d'autre (audit, § 5).
public enum UserAgent {
    public static var value: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Foluna/\(version) (macOS)"
    }
}
