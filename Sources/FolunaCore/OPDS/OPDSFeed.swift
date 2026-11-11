import Foundation

/// Flux OPDS 1.2 (Atom) : une page de catalogue, de navigation ou de livres.
public struct OPDSFeed: Sendable, Hashable {
    /// Adresse effective du flux (après redirections) : les liens relatifs s'y rattachent.
    public var url: URL
    public var title: String
    public var subtitle: String?
    public var entries: [OPDSEntry]
    /// Page suivante (`rel="next"`).
    public var nextURL: URL?
    /// Recherche du catalogue : description OpenSearch à charger, ou gabarit déjà lisible.
    public var search: OPDSSearchLink?

    public init(url: URL, title: String, subtitle: String? = nil, entries: [OPDSEntry],
                nextURL: URL? = nil, search: OPDSSearchLink? = nil) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.entries = entries
        self.nextURL = nextURL
        self.search = search
    }
}

/// Lien de recherche d'un flux.
public enum OPDSSearchLink: Sendable, Hashable {
    /// Description OpenSearch (`application/opensearchdescription+xml`) à charger.
    case description(URL)
    /// Gabarit contenant `{searchTerms}`.
    case template(OPDSSearchTemplate)
}

/// Gabarit OpenSearch (`…?query={searchTerms}`).
public struct OPDSSearchTemplate: Sendable, Hashable {
    public var template: String

    public init(_ template: String) { self.template = template }

    /// Adresse de recherche pour ces mots, en HTTPS ; nil si le gabarit est inutilisable.
    public func url(for terms: String) -> URL? {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, template.contains("{searchTerms}") else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        var s = template.replacingOccurrences(of: "{searchTerms}", with: encoded)
        s = s.replacingOccurrences(of: "{startPage?}", with: "1")
            .replacingOccurrences(of: "{startIndex?}", with: "1")
            .replacingOccurrences(of: "{startPage}", with: "1")
            .replacingOccurrences(of: "{startIndex}", with: "1")
        // Paramètres facultatifs restants (`{language?}`, `{count?}`…) : vides.
        if let optional = try? NSRegularExpression(pattern: "\\{[A-Za-z:]+\\?\\}") {
            s = optional.replace(in: s) { _ in "" }
        }
        return URL(string: s).flatMap(OPDSURL.secure)
    }
}

/// Entrée d'un flux : un sous-catalogue (navigation) ou un livre (acquisitions).
public struct OPDSEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var authors: [String]
    public var summary: String?
    public var language: String?
    public var thumbnailURL: URL?
    /// Sous-catalogue ouvert par l'entrée.
    public var navigationURL: URL?
    /// Fichiers téléchargeables, un par format, EPUB d'abord.
    public var acquisitions: [OPDSAcquisition]
    /// Flux liés (« Du même auteur »…).
    public var related: [OPDSRelated]

    public init(id: String, title: String, authors: [String] = [], summary: String? = nil, language: String? = nil,
                thumbnailURL: URL? = nil, navigationURL: URL? = nil, acquisitions: [OPDSAcquisition] = [],
                related: [OPDSRelated] = []) {
        self.id = id
        self.title = title
        self.authors = authors
        self.summary = summary
        self.language = language
        self.thumbnailURL = thumbnailURL
        self.navigationURL = navigationURL
        self.acquisitions = acquisitions
        self.related = related
    }

    /// Un livre téléchargeable (et non un sous-catalogue).
    public var isBook: Bool { !acquisitions.isEmpty }
}

/// Fichier gratuit d'un livre, dans un format que la bibliothèque sait lire.
public struct OPDSAcquisition: Sendable, Hashable, Identifiable {
    public var url: URL
    public var format: BookFormat
    /// Taille annoncée par le catalogue, en octets.
    public var length: Int64?
    public var id: URL { url }

    public init(url: URL, format: BookFormat, length: Int64? = nil) {
        self.url = url
        self.format = format
        self.length = length
    }
}

/// Flux lié à une entrée.
public struct OPDSRelated: Sendable, Hashable, Identifiable {
    public var title: String
    public var url: URL
    public var id: URL { url }

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

/// Règles d'adresse : tout passe en HTTPS (les catalogues publics le servent, Gutenberg annonce encore `http`).
public enum OPDSURL {
    /// Adresse en HTTPS (une adresse `http` est réécrite) ; nil pour tout autre schéma.
    public static func secure(_ url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http":
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
            c.scheme = "https"
            if c.port == 80 { c.port = nil }
            return c.url
        default: return nil
        }
    }

    /// Adresse saisie par l'utilisateur : `https://` ajouté s'il manque.
    public static func parse(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let withScheme = t.contains("://") ? t : "https://" + t
        guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
        return secure(url)
    }

    /// Lien `href` relatif au flux, en HTTPS.
    static func resolve(_ href: String, against base: URL) -> URL? {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.lowercased().hasPrefix("data:") else { return nil }
        let url = URL(string: h, relativeTo: base)
            ?? h.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0, relativeTo: base) }
        return url.flatMap { secure($0.absoluteURL) }
    }
}
