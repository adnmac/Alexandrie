import Foundation

/// Notice trouvée dans un catalogue de bibliothèque.
public struct CatalogRecord: Codable, Hashable, Sendable {
    public enum Match: String, Codable, Sendable {
        case isbn, titleAuthor
    }

    public var source: String
    public var url: String?
    public var match: Match
    public var isbn: String?
    public var title: String
    public var authors: [String]
    public var publisher: String?
    public var publishedDate: String?
    public var language: String?
}

// MARK: - BnF (SRU, Dublin Core)

public enum BnFCatalog {
    static let endpoint = "https://catalogue.bnf.fr/api/SRU"

    /// La BnF indexe les éditions antérieures à 2007 par leur ISBN-10 : on interroge les deux formes.
    static func isbnQuery(_ isbn13: String) -> String {
        var q = "bib.isbn adj \"\(isbn13)\""
        if let ten = ISBN.to10(isbn13) { q += " or bib.isbn adj \"\(ten)\"" }
        return q
    }

    static func titleQuery(title: String, author: String?) -> String {
        var q = "bib.title all \"\(Matching.searchTerms(title))\""
        if let author, !author.isEmpty { q += " and bib.author all \"\(Matching.searchTerms(author))\"" }
        return q
    }

    static func url(_ query: String, max: Int) -> URL {
        var c = URLComponents(string: endpoint)!
        c.queryItems = [
            .init(name: "version", value: "1.2"), .init(name: "operation", value: "searchRetrieve"),
            .init(name: "query", value: query), .init(name: "recordSchema", value: "dublincore"),
            .init(name: "maximumRecords", value: String(max)),
        ]
        return c.url!
    }

    /// Notices de textes (imprimés ou numériques) ; les enregistrements sonores, cartes… sont écartés.
    public static func parse(_ data: Data, match: CatalogRecord.Match) -> [CatalogRecord] {
        guard let doc = try? XMLDocument(data: data), let root = doc.rootElement() else { return [] }
        return root.descendants(named: "dc").compactMap { dc in
            func values(_ name: String) -> [String] { dc.children(named: name).map(\.textContent).filter { !$0.isEmpty } }
            let types = dc.children(named: "type").filter { $0.attr("lang") == "fre" }.map(\.textContent)
            if !types.isEmpty && !types.contains(where: { $0.contains("texte") || $0.contains("électronique") }) {
                return nil
            }
            guard let rawTitle = values("title").first else { return nil }
            let parts = rawTitle.components(separatedBy: " / ")
            var authors = values("creator").compactMap(personName)
            if authors.isEmpty, parts.count > 1 {
                authors = parts[1].components(separatedBy: ";")[0].components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let identifiers = values("identifier")
            return CatalogRecord(
                source: "BnF",
                url: identifiers.first { $0.hasPrefix("http") },
                match: match,
                isbn: ISBN.first(in: identifiers.filter { $0.uppercased().hasPrefix("ISBN") }),
                title: parts[0].trimmingCharacters(in: .whitespaces),
                authors: authors,
                publisher: values("publisher").first.map(stripPlace),
                publishedDate: values("date").first,
                language: values("language").first.map(Matching.language))
        }
    }

    /// « Aron, Matthieu (1963-....). Auteur du texte » → « Matthieu Aron » ; les traducteurs, préfaciers… sont ignorés.
    static func personName(_ creator: String) -> String? {
        var name = creator
        if let dot = name.range(of: ". ") {
            let role = name[dot.upperBound...].lowercased()
            if !role.contains("auteur") && !role.contains("autrice") { return nil }
            name = String(name[..<dot.lowerBound])
        }
        if let paren = name.range(of: " (") { name = String(name[..<paren.lowerBound]) }
        let pieces = name.components(separatedBy: ", ")
        if pieces.count == 2 { name = pieces[1] + " " + pieces[0] }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// « Gallimard (Paris) » → « Gallimard ».
    static func stripPlace(_ publisher: String) -> String {
        publisher.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
    }
}

// MARK: - Open Library

public enum OpenLibraryCatalog {
    static func isbnURL(_ isbn: String) -> URL {
        URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data")!
    }

    static func searchURL(title: String, author: String?) -> URL {
        var c = URLComponents(string: "https://openlibrary.org/search.json")!
        c.queryItems = [.init(name: "title", value: Matching.searchTerms(title)), .init(name: "limit", value: "8"),
                        .init(name: "fields", value: "key,title,author_name,isbn,publisher,first_publish_year,language")]
        if let author, !author.isEmpty { c.queryItems!.append(.init(name: "author", value: author)) }
        return c.url!
    }

    public static func parseISBN(_ data: Data, isbn: String) -> CatalogRecord? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json.values.first as? [String: Any], let title = entry["title"] as? String else { return nil }
        let names = { (key: String) in ((entry[key] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String } }
        return CatalogRecord(source: "Open Library", url: entry["url"] as? String, match: .isbn, isbn: isbn,
                             title: title, authors: names("authors"), publisher: names("publishers").first,
                             publishedDate: (entry["publish_date"] as? String).flatMap(Matching.year),
                             language: nil)
    }

    public static func parseSearch(_ data: Data) -> [CatalogRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { d in
            guard let title = d["title"] as? String else { return nil }
            let isbns = (d["isbn"] as? [String]) ?? []
            return CatalogRecord(
                source: "Open Library", url: (d["key"] as? String).map { "https://openlibrary.org" + $0 },
                match: .titleAuthor,
                isbn: isbns.first { $0.count == 13 }.flatMap(ISBN.normalized) ?? ISBN.first(in: isbns),
                title: title, authors: (d["author_name"] as? [String]) ?? [],
                publisher: (d["publisher"] as? [String])?.first,
                publishedDate: (d["first_publish_year"] as? Int).map(String.init),
                language: ((d["language"] as? [String])?.count == 1 ? (d["language"] as? [String])?.first : nil)
                    .map(Matching.language))
        }
    }
}

// MARK: - Recherche combinée

/// Interroge la BnF puis Open Library. L'accès réseau est injectable pour les tests.
public struct CatalogClient: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    let fetch: Fetch

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Alexandrie/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
    }

    /// Notice correspondant au livre : par ISBN si valide, sinon (ou à défaut) par titre et auteur.
    /// Une recherche par titre n'est retenue que si le titre et l'auteur concordent.
    /// Si un des deux services est injoignable, l'autre est quand même interrogé ; l'erreur n'est levée
    /// que si aucune notice n'a pu être trouvée (« aucune notice » ne doit pas masquer une panne).
    public func lookup(_ book: MetadataEdits) async throws -> CatalogRecord? {
        var failure: (any Error)?
        func attempt(_ url: URL) async -> Data? {
            do { return try await fetch(url) } catch { failure = failure ?? error; return nil }
        }

        if let isbn = book.isbn.flatMap(ISBN.normalized) {
            if let data = await attempt(BnFCatalog.url(BnFCatalog.isbnQuery(isbn), max: 3)),
               let r = BnFCatalog.parse(data, match: .isbn).first {
                return r
            }
            if let data = await attempt(OpenLibraryCatalog.isbnURL(isbn)),
               let r = OpenLibraryCatalog.parseISBN(data, isbn: isbn) {
                return r
            }
        }
        let title = Matching.mainTitle(book.title)
        guard !title.isEmpty else {
            if let failure { throw failure }
            return nil
        }
        let author = book.authors.first.map(Matching.surname)
        let bnf = await attempt(BnFCatalog.url(BnFCatalog.titleQuery(title: title, author: author), max: 10))
            .map { BnFCatalog.parse($0, match: .titleAuthor) } ?? []
        let fromBnF = Matching.best(bnf, for: book)
        if fromBnF?.isbn != nil { return fromBnF }
        // Notice BnF sans ISBN (édition ancienne) : Open Library peut en fournir un.
        let ol = await attempt(OpenLibraryCatalog.searchURL(title: title, author: author))
            .map(OpenLibraryCatalog.parseSearch) ?? []
        let fromOL = Matching.best(ol, for: book)
        if let found = fromOL?.isbn != nil ? fromOL : (fromBnF ?? fromOL) { return found }
        if let failure { throw failure }
        return nil
    }

    /// Message compréhensible pour une vérification échouée.
    public static func describe(_ error: any Error) -> String {
        let unavailable: [URLError.Code] = [.secureConnectionFailed, .networkConnectionLost, .cannotConnectToHost,
                                            .cannotFindHost, .timedOut, .badServerResponse, .dnsLookupFailed]
        if let e = error as? URLError {
            if e.code == .notConnectedToInternet { return "Vérification impossible : pas de connexion Internet." }
            if unavailable.contains(e.code) {
                let host = e.failingURL?.host.map { $0.contains("bnf.fr") ? "de la BnF" : "d'Open Library" } ?? "en ligne"
                return "Vérification impossible : le catalogue \(host) ne répond pas pour le moment. Réessayez plus tard."
            }
        }
        return "Vérification impossible : \(error.localizedDescription)"
    }
}

// MARK: - Comparaison

enum Matching {
    /// Minuscules, sans accents ni ponctuation.
    static func key(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Titre principal, sans sous-titre ni mention « (French Edition) ».
    static func mainTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*(edition|édition|trad)[^\\)\\]]*[\\)\\]]",
                                           with: "", options: [.regularExpression, .caseInsensitive])
        for sep in [" : ", ": ", " - ", " — "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func searchTerms(_ s: String) -> String {
        key(s).split(separator: " ").prefix(8).joined(separator: " ")
    }

    /// Nom de famille : « Heller, Peter » → Heller ; « Peter Heller » → Heller.
    static func surname(_ name: String) -> String {
        if let comma = name.firstIndex(of: ",") { return String(name[..<comma]).trimmingCharacters(in: .whitespaces) }
        return name.split(separator: " ").last.map(String.init) ?? name
    }

    /// Nom comparable quel que soit l'ordre (« Heller, Peter » = « Peter Heller »).
    static func personKey(_ name: String) -> String {
        key(name).split(separator: " ").sorted().joined(separator: " ")
    }

    static func year(_ s: String) -> String? {
        s.range(of: "\\d{4}", options: .regularExpression).map { String(s[$0]) }
    }

    static func language(_ code: String) -> String {
        let map = ["fre": "fr", "fra": "fr", "eng": "en", "ger": "de", "deu": "de", "spa": "es", "ita": "it",
                   "dut": "nl", "nld": "nl", "por": "pt", "rus": "ru", "jpn": "ja", "chi": "zh", "zho": "zh",
                   "lat": "la", "grc": "grc", "ara": "ar", "pol": "pl", "swe": "sv"]
        return map[code.lowercased()] ?? code.lowercased()
    }

    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = key(mainTitle(a)), y = key(mainTitle(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        return long.hasPrefix(short) && Double(short.count) / Double(long.count) >= 0.5
    }

    static func authorsMatch(_ book: [String], _ record: [String]) -> Bool {
        guard !book.isEmpty else { return true }
        let recordKeys = record.map(key).joined(separator: " ")
        return book.contains { recordKeys.contains(key(surname($0))) }
    }

    /// Meilleure notice concordante : avec ISBN d'abord, dans la langue du livre si connue.
    static func best(_ records: [CatalogRecord], for book: MetadataEdits) -> CatalogRecord? {
        let candidates = records.filter { titlesMatch($0.title, book.title) && authorsMatch(book.authors, $0.authors) }
        let lang = book.language.map { String($0.prefix(2)).lowercased() }
        return candidates.max { a, b in score(a, lang) < score(b, lang) }
    }

    private static func score(_ r: CatalogRecord, _ lang: String?) -> Int {
        var s = r.isbn != nil ? 4 : 0
        if let lang, r.language == lang { s += 2 }
        if let y = r.publishedDate.flatMap(year), let n = Int(y) { s += n >= 2000 ? 1 : 0 }
        return s
    }
}

/// Champ comparable entre un livre et une notice.
public enum CatalogField: String, CaseIterable, Codable, Sendable, Identifiable {
    case isbn, title, authors, publisher, publishedDate, language

    public var id: Self { self }

    public var label: String {
        switch self {
        case .isbn: "ISBN"
        case .title: "Titre"
        case .authors: "Auteurs"
        case .publisher: "Éditeur"
        case .publishedDate: "Publication"
        case .language: "Langue"
        }
    }
}

public struct CatalogDifference: Identifiable, Hashable, Sendable {
    public var id: CatalogField { field }
    public let field: CatalogField
    public let current: String?
    public let proposed: String
}

public enum CatalogComparison {
    /// Différences significatives (casse, accents, ponctuation et ordre des noms ignorés).
    public static func differences(_ e: MetadataEdits, _ r: CatalogRecord) -> [CatalogDifference] {
        var out: [CatalogDifference] = []
        func add(_ f: CatalogField, _ current: String?, _ proposed: String?) {
            if let p = proposed, !p.isEmpty { out.append(CatalogDifference(field: f, current: current, proposed: p)) }
        }
        // Un ISBN valide absent des catalogues est souvent celui de l'édition numérique : on le garde.
        let currentISBN = e.isbn.flatMap(ISBN.normalized)
        if let rIsbn = r.isbn, currentISBN != rIsbn, currentISBN == nil || r.match == .isbn {
            add(.isbn, e.isbn, rIsbn)
        }
        if Matching.key(e.title) != Matching.key(r.title) && Matching.key(Matching.mainTitle(e.title)) != Matching.key(r.title) {
            add(.title, e.title, r.title)
        }
        if !r.authors.isEmpty, Set(e.authors.map(Matching.personKey)) != Set(r.authors.map(Matching.personKey)) {
            add(.authors, e.authors.isEmpty ? nil : e.authors.joined(separator: ", "), r.authors.joined(separator: ", "))
        }
        if let p = r.publisher {
            let a = Matching.key(e.publisher ?? ""), b = Matching.key(p)
            if a.isEmpty || (!a.contains(b) && !b.contains(a)) { add(.publisher, e.publisher, p) }
        }
        if let d = r.publishedDate, e.publishedDate.flatMap(Matching.year) != Matching.year(d) {
            add(.publishedDate, e.publishedDate, d)
        }
        if let l = r.language, e.language.map({ String($0.prefix(2)).lowercased() }) != l {
            add(.language, e.language, l)
        }
        return out
    }

    public static func apply(_ fields: Set<CatalogField>, from r: CatalogRecord, to e: inout MetadataEdits) {
        for f in fields {
            switch f {
            case .isbn: e.isbn = r.isbn ?? e.isbn
            case .title: e.title = r.title
            case .authors: if !r.authors.isEmpty { e.authors = r.authors }
            case .publisher: e.publisher = r.publisher ?? e.publisher
            case .publishedDate: e.publishedDate = r.publishedDate ?? e.publishedDate
            case .language: e.language = r.language ?? e.language
            }
        }
    }
}
