import Foundation

public enum OPDSError: LocalizedError, Equatable {
    /// La réponse n'est pas un flux OPDS (page web, erreur du serveur…).
    case notAFeed
    /// Catalogue au format OPDS 2 (JSON), non pris en charge.
    case opds2
    /// Adresse ou redirection hors HTTPS.
    case insecure
    /// Le catalogue n'a pas de recherche.
    case noSearch
    /// Fichier plus gros que `OPDSClient.maxDownload`.
    case tooLarge
    /// Le fichier reçu n'est pas du format annoncé (page web, archive…).
    case wrongFormat(BookFormat)

    public var errorDescription: String? {
        switch self {
        case .notAFeed: String(localized: "Cette adresse ne mène pas à un catalogue OPDS.")
        case .opds2: String(localized: "Ce catalogue utilise OPDS 2 (JSON), que Foluna ne lit pas encore.")
        case .insecure: String(localized: "Seules les adresses sécurisées (https) sont acceptées.")
        case .noSearch: String(localized: "Ce catalogue ne propose pas de recherche.")
        case .tooLarge: String(localized: "Le fichier dépasse 200 Mo.")
        case .wrongFormat(let f): String(localized: "Le fichier reçu n'est pas un \(f.label).")
        }
    }
}

/// Lecture des flux OPDS 1.2 (Atom) et des descriptions OpenSearch.
public enum OPDSParser {
    static let acquisition = "http://opds-spec.org/acquisition"

    /// Flux à l'adresse effective `url`.
    public static func feed(_ data: Data, url: URL) throws -> OPDSFeed {
        let root = try rootElement(data)
        guard root.localName == "feed" else { throw OPDSError.notAFeed }
        let links = root.children(named: "link")
        var nextURL: URL?
        var search: OPDSSearchLink?
        for link in links {
            guard let href = link.attr("href") else { continue }
            let rel = link.attr("rel") ?? ""
            let type = mediaType(link.attr("type"))
            if rel == "next", nextURL == nil {
                nextURL = OPDSURL.resolve(href, against: url)
            } else if rel == "search", search == nil {
                if href.contains("{searchTerms}") {
                    search = .template(resolveTemplate(href, against: url))
                } else if type == "application/opensearchdescription+xml",
                          let u = OPDSURL.resolve(href, against: url) {
                    search = .description(u)
                }
            }
        }
        let entries = root.children(named: "entry").compactMap { entry($0, base: url) }
        return OPDSFeed(url: url, title: text(root.firstChild(named: "title")) ?? url.host ?? "Catalogue",
                        subtitle: text(root.firstChild(named: "subtitle")), entries: entries,
                        nextURL: nextURL, search: search)
    }

    /// Gabarit de recherche Atom d'une description OpenSearch.
    public static func searchTemplate(_ data: Data, url: URL) throws -> OPDSSearchTemplate {
        let root = try rootElement(data)
        guard root.localName == "OpenSearchDescription" else { throw OPDSError.noSearch }
        let urls = root.children(named: "Url").filter { $0.attr("rel") == nil || $0.attr("rel") == "results" }
        let atom = urls.first { mediaType($0.attr("type")).contains("atom+xml") }
        guard let template = atom?.attr("template"), template.contains("{searchTerms}") else {
            throw OPDSError.noSearch
        }
        return resolveTemplate(template, against: url)
    }

    /// Gabarit relatif rattaché au document qui l'annonce (`feed.php?query={searchTerms}` → même dossier).
    /// Les accolades empêchent `URL(string:relativeTo:)` : elles sont mises de côté le temps de la résolution.
    static func resolveTemplate(_ template: String, against base: URL) -> OPDSSearchTemplate {
        var placeholders: [(String, String)] = []
        var s = template
        if let regex = try? NSRegularExpression(pattern: "\\{[A-Za-z:]+\\??\\}") {
            s = regex.replace(in: template) { g in
                let token = "opdsparam\(placeholders.count)x"
                placeholders.append((token, g[0]))
                return token
            }
        }
        guard let url = URL(string: s, relativeTo: base)?.absoluteURL else { return OPDSSearchTemplate(template) }
        var resolved = url.absoluteString
        for (token, original) in placeholders { resolved = resolved.replacingOccurrences(of: token, with: original) }
        return OPDSSearchTemplate(resolved)
    }

    // MARK: - Entrées

    static func entry(_ el: XMLElement, base: URL) -> OPDSEntry? {
        guard let title = text(el.firstChild(named: "title")) else { return nil }
        var acquisitions: [OPDSAcquisition] = []
        var thumbnail: URL?
        var image: URL?
        var navigation: URL?
        var related: [OPDSRelated] = []
        for link in el.children(named: "link") {
            guard let href = link.attr("href"), let url = OPDSURL.resolve(href, against: base) else { continue }
            let rel = link.attr("rel") ?? ""
            let type = mediaType(link.attr("type"))
            if rel == acquisition || rel == acquisition + "/open-access" {
                // Chaîne d'acquisition indirecte : livre sous DRM (Adobe, LCP) ou à acheter.
                guard link.children(named: "indirectAcquisition").isEmpty,
                      let format = format(type) else { continue }
                let length = link.attr("length").flatMap { Int64($0) }
                acquisitions.append(OPDSAcquisition(url: url, format: format, length: length))
            } else if rel == "http://opds-spec.org/image/thumbnail" || rel == "x-stanza-cover-image-thumbnail" {
                thumbnail = thumbnail ?? url
            } else if rel == "http://opds-spec.org/image" || rel == "x-stanza-cover-image" {
                image = image ?? url
            } else if type == "application/atom+xml" {
                switch rel {
                case "related":
                    related.append(OPDSRelated(title: link.attr("title") ?? String(localized: "Voir aussi"), url: url))
                case "self", "alternate", "start", "up", "search", "next", "previous":
                    break
                default:
                    navigation = navigation ?? url
                }
            }
        }
        // Un fichier par format, dans l'ordre de préférence (EPUB, puis formats Kindle, puis PDF).
        var seen = Set<BookFormat>()
        acquisitions = acquisitions.filter { seen.insert($0.format).inserted }
            .sorted { order($0.format) < order($1.format) }
        let authors = el.children(named: "author").compactMap { text($0.firstChild(named: "name")) }
        let summary = summaryText(el.firstChild(named: "summary")) ?? summaryText(el.firstChild(named: "content"))
        let language = text(el.firstChild(named: "language"))
        return OPDSEntry(id: text(el.firstChild(named: "id")) ?? (navigation ?? acquisitions.first?.url)?.absoluteString ?? title,
                         title: title, authors: authors, summary: summary, language: language,
                         thumbnailURL: thumbnail ?? image, navigationURL: acquisitions.isEmpty ? navigation : nil,
                         acquisitions: acquisitions, related: related)
    }

    static func format(_ type: String) -> BookFormat? {
        switch type {
        case "application/epub+zip": .epub
        case "application/x-mobipocket-ebook", "application/x-mobi8-ebook": .mobi
        case "application/vnd.amazon.ebook", "application/x-mobi8": .azw3
        case "application/pdf": .pdf
        case "application/x-fictionbook+xml", "application/fb2+xml", "application/x-fb2", "application/fb2+zip",
             "application/x-zip-compressed-fb2": .fb2
        case "application/vnd.comicbook+zip", "application/x-cbz": .cbz
        default: nil
        }
    }

    static func order(_ f: BookFormat) -> Int {
        switch f {
        case .epub: 0
        case .azw3: 1
        case .mobi: 2
        case .azw: 3
        case .prc: 4
        case .fb2: 5
        case .pdf: 6
        case .cbz: 7
        case .txt: 8
        }
    }

    // MARK: - Aides

    static func rootElement(_ data: Data) throws -> XMLElement {
        let head = data.prefix(64).drop { [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        if head.first == UInt8(ascii: "{") { throw OPDSError.opds2 }
        // `XMLLoader` se replie sur le mode HTML : une page web y deviendrait un document `html`.
        guard let doc = try? XMLLoader.document(data), let root = doc.rootElement() else { throw OPDSError.notAFeed }
        return root
    }

    /// Type sans paramètres (`application/atom+xml;profile=opds-catalog` → `application/atom+xml`).
    static func mediaType(_ type: String?) -> String {
        (type ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    static func text(_ el: XMLElement?) -> String? {
        guard let t = el?.textContent, !t.isEmpty else { return nil }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Résumé lisible : balises HTML retirées, un paragraphe par ligne.
    static func summaryText(_ el: XMLElement?) -> String? {
        guard let el else { return nil }
        let type = mediaType(el.attr("type"))
        let pieces: [String]
        if type == "xhtml" {
            // Contenu XHTML : du vrai XML, dont on reprend le balisage pour garder les paragraphes.
            let markup = (el.children ?? []).map { $0.xmlString }.joined()
            pieces = htmlParagraphs(markup)
        } else if let s = el.stringValue, type.contains("html") || s.contains("<") {
            pieces = htmlParagraphs(s)
        } else {
            pieces = (el.stringValue ?? "").components(separatedBy: .newlines)
        }
        let paragraphs = pieces.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n")
    }

    /// Paragraphes d'un fragment HTML (coupés aux `<br>` et fins de blocs), entités décodées.
    static func htmlParagraphs(_ html: String) -> [String] {
        html.replacingOccurrences(of: "<br\\s*/?>|</(p|div|li|h[1-6])>", with: "\u{1}",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .components(separatedBy: "\u{1}")
            .map(HTMLEntities.decode)
    }
}
