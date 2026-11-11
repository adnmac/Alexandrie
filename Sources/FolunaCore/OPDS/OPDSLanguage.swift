import Foundation

/// Langue choisie pour un catalogue OPDS (S-090) : envoyée au serveur quand il sait filtrer (Gutenberg),
/// et appliquée aux livres dont la langue est connue.
public enum OPDSLanguage {
    /// Langues proposées (codes ISO 639-1), dans l'ordre du menu.
    public static let choices = ["fr", "en", "de", "es", "it", "nl", "pt", "la"]

    /// Nom de la langue dans la langue de l'interface (« Français », « French »…), d'après le système.
    public static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current) ?? code
    }

    /// Code ISO 639-1 d'une langue de flux : `fre`, `fra`, `fr-FR`, `FR` → `fr`.
    public static func normalized(_ value: String) -> String {
        let base = value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? value
        return Matching.language(base.trimmingCharacters(in: .whitespaces))
    }

    /// Langues nommées en anglais en fin de titre (« Le tour du monde… (French) », usage de Gutenberg).
    static let englishNames: [String: String] = [
        "English": "en", "French": "fr", "German": "de", "Spanish": "es", "Italian": "it", "Dutch": "nl",
        "Portuguese": "pt", "Latin": "la", "Finnish": "fi", "Swedish": "sv", "Danish": "da", "Norwegian": "no",
        "Polish": "pl", "Russian": "ru", "Greek": "el", "Hungarian": "hu", "Czech": "cs", "Catalan": "ca",
        "Chinese": "zh", "Japanese": "ja", "Esperanto": "eo", "Tagalog": "tl", "Welsh": "cy", "Irish": "ga",
    ]
    private static let suffix = try! NSRegularExpression(pattern: "\\(([A-Z][a-z]+)\\)\\s*$")

    /// Langue annoncée en fin de titre, si c'est un nom de langue connu.
    static func fromTitle(_ title: String) -> String? {
        suffix.firstGroups(in: title).flatMap { englishNames[$0[1]] }
    }

    /// L'entrée désigne un livre : livre téléchargeable, ou lien vers la fiche d'un livre (Gutenberg).
    public static func isBook(_ entry: OPDSEntry, in catalog: OPDSCatalog?) -> Bool {
        if entry.isBook { return true }
        guard let pattern = catalog?.bookLinkPattern, let url = entry.navigationURL?.absoluteString else { return false }
        return url.range(of: pattern, options: .regularExpression) != nil
    }

    /// Langue d'un livre : indiquée par le flux, sinon en fin de titre, sinon la langue des titres sans mention
    /// du catalogue (l'anglais chez Gutenberg). Nil : inconnue.
    public static func language(of entry: OPDSEntry, in catalog: OPDSCatalog?) -> String? {
        if let own = entry.language, !own.isEmpty { return normalized(own) }
        if let fromTitle = fromTitle(entry.title) { return fromTitle }
        return isBook(entry, in: catalog) ? catalog?.unmarkedLanguage : nil
    }

    /// L'entrée reste affichée : rubrique, livre de langue inconnue, ou livre dans la langue choisie.
    public static func keeps(_ entry: OPDSEntry, language: String?, in catalog: OPDSCatalog? = nil) -> Bool {
        guard let language, isBook(entry, in: catalog), let own = self.language(of: entry, in: catalog) else { return true }
        return own == language
    }

    /// Mots de recherche complétés par la syntaxe de langue du catalogue (Gutenberg : `l.fr`).
    public static func terms(_ terms: String, language: String?, catalog: OPDSCatalog) -> String {
        guard let clause = clause(language, catalog), !terms.contains(clause) else { return terms }
        return terms + " " + clause
    }

    /// Adresse d'une liste du catalogue restreinte à la langue côté serveur : chez Gutenberg, toute page
    /// `search.opds` (populaires, récents, résultats et leurs pages suivantes) reçoit `l.fr` dans `query`.
    public static func url(_ url: URL, language: String?, catalog: OPDSCatalog) -> URL {
        guard let clause = clause(language, catalog), let path = catalog.languageListPath,
              url.path.contains(path),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        var items = c.queryItems ?? []
        if let i = items.firstIndex(where: { $0.name == "query" }) {
            let current = items[i].value ?? ""
            guard !current.contains(clause) else { return url }
            items[i].value = current.isEmpty ? clause : current + " " + clause
        } else {
            items.append(URLQueryItem(name: "query", value: clause))
        }
        c.queryItems = items
        return c.url ?? url
    }

    /// Le serveur sait restreindre cette liste à une langue (la page est alors rechargée au changement).
    public static func restrictsOnServer(_ url: URL, catalog: OPDSCatalog) -> Bool {
        guard catalog.languageQuery != nil, let path = catalog.languageListPath else { return false }
        return url.path.contains(path)
    }

    private static func clause(_ language: String?, _ catalog: OPDSCatalog) -> String? {
        guard let language, let syntax = catalog.languageQuery else { return nil }
        return syntax.replacingOccurrences(of: "{lang}", with: language)
    }
}
