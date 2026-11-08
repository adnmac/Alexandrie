import Foundation

/// Accès aux catalogues OPDS publics : flux, recherche, couvertures et téléchargement des livres.
/// Aucune requête ne part sans que l'utilisateur ait ouvert un catalogue.
public struct OPDSClient: Sendable {
    /// Données et adresse effective (après redirections) d'une requête.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, URL)
    /// Plafond d'un livre téléchargé.
    public static let maxDownload = 200 * 1024 * 1024

    let fetch: Fetch

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { url in
            guard let secure = OPDSURL.secure(url) else { throw OPDSError.insecure }
            var request = URLRequest(url: secure, timeoutInterval: 30)
            request.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: secure])
            }
            // Une redirection vers `http` est refusée.
            let final = http.url ?? secure
            guard final.scheme?.lowercased() == "https" else { throw OPDSError.insecure }
            return (data, final)
        }
    }

    public func feed(at url: URL) async throws -> OPDSFeed {
        guard let url = OPDSURL.secure(url) else { throw OPDSError.insecure }
        let (data, final) = try await fetchCOPS(url)
        return try OPDSParser.feed(data, url: final)
    }

    /// Les serveurs COPS récents servent tout par `index.php` mais annoncent encore `feed.php` (recherche) :
    /// une adresse `feed.php` introuvable est réessayée avec `index.php`.
    func fetchCOPS(_ url: URL) async throws -> (Data, URL) {
        do {
            return try await fetch(url)
        } catch let error as URLError where error.code == .badServerResponse && url.lastPathComponent == "feed.php" {
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw error }
            c.path = (c.path as NSString).deletingLastPathComponent + "/index.php"
            guard let retry = c.url else { throw error }
            return try await fetch(retry)
        }
    }

    /// Gabarit de recherche du flux (la description OpenSearch est chargée si besoin).
    public func searchTemplate(_ link: OPDSSearchLink) async throws -> OPDSSearchTemplate {
        switch link {
        case .template(let t): return t
        case .description(let url):
            let (data, final) = try await fetchCOPS(url)
            return try OPDSParser.searchTemplate(data, url: final)
        }
    }

    public func search(_ terms: String, with template: OPDSSearchTemplate) async throws -> OPDSFeed {
        guard let url = template.url(for: terms) else { throw OPDSError.noSearch }
        return try await feed(at: url)
    }

    /// Image (couverture réduite) d'une entrée.
    public func image(at url: URL) async throws -> Data {
        try await fetch(url).0
    }

    /// Télécharge le livre dans `directory`, sous le nom « Auteur - Titre.ext ».
    /// Le contenu est vérifié : une page web ou une archive à la place d'un livre est refusée.
    public func download(_ acquisition: OPDSAcquisition, of entry: OPDSEntry, into directory: URL) async throws -> URL {
        if let length = acquisition.length, length > Self.maxDownload { throw OPDSError.tooLarge }
        let (data, _) = try await fetch(acquisition.url)
        guard data.count <= Self.maxDownload else { throw OPDSError.tooLarge }
        guard Self.looksLike(acquisition.format, data) else { throw OPDSError.wrongFormat(acquisition.format) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(Self.fileName(for: entry, format: acquisition.format))
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Nom de fichier sûr : « Auteur - Titre.ext », sans caractères interdits, 120 caractères au plus.
    /// L'extension vient du format et non de l'adresse (Gutenberg sert `164.epub.noimages`).
    public static func fileName(for entry: OPDSEntry, format: BookFormat) -> String {
        let author = entry.authors.first.map { $0 + " - " } ?? ""
        var base = (author + entry.title).replacingOccurrences(of: "[/\\\\:*?\"<>|\\p{Cc}]", with: " ",
                                                                  options: .regularExpression)
        base = base.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Ni fichier caché ni remontée de dossier (« ../ »).
        while base.hasPrefix(".") || base.hasPrefix(" ") { base.removeFirst() }
        if base.count > 120 { base = String(base.prefix(120)).trimmingCharacters(in: .whitespaces) }
        if base.isEmpty { base = "Livre" }
        return base + "." + format.rawValue
    }

    /// Signature du fichier : ZIP pour l'EPUB, `%PDF`, `BOOKMOBI` pour les formats Kindle.
    static func looksLike(_ format: BookFormat, _ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(68))
        switch format {
        case .epub: return bytes.starts(with: [0x50, 0x4B, 0x03, 0x04])
        case .pdf: return bytes.starts(with: Array("%PDF".utf8))
        case .mobi, .azw3, .azw: return bytes.count >= 68 && Array(bytes[60..<68]) == Array("BOOKMOBI".utf8)
        }
    }

    /// Message compréhensible pour un catalogue ou un téléchargement en échec.
    public static func describe(_ error: any Error) -> String {
        if let e = error as? OPDSError { return e.errorDescription ?? "Catalogue illisible." }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "Pas de connexion Internet."
            case .cannotFindHost, .dnsLookupFailed: return "Adresse introuvable : vérifiez-la."
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .badServerResponse, .secureConnectionFailed:
                return "Le catalogue ne répond pas pour le moment. Réessayez plus tard."
            default: break
            }
        }
        return error.localizedDescription
    }
}
