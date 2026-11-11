import Foundation

/// Couverture d'un livre sur Open Library : par ISBN, sinon par titre et auteur (notice concordante seulement).
public struct CoverFinder: Sendable {
    let fetch: CatalogClient.Fetch

    public init(fetch: CatalogClient.Fetch? = nil) {
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
    }

    static func isbnCoverURL(_ isbn: String) -> URL {
        URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg?default=false")!
    }

    static func idCoverURL(_ id: Int) -> URL {
        URL(string: "https://covers.openlibrary.org/b/id/\(id)-L.jpg?default=false")!
    }

    static func searchURL(title: String, author: String?) -> URL {
        var c = URLComponents(string: "https://openlibrary.org/search.json")!
        c.queryItems = [.init(name: "title", value: Matching.searchTerms(title)), .init(name: "limit", value: "8"),
                        .init(name: "fields", value: "title,author_name,cover_i")]
        if let author { c.queryItems?.append(.init(name: "author", value: author)) }
        return c.url!
    }

    /// Image de couverture, ou nil si Open Library n'en a pas (ou ne trouve pas le livre).
    public func cover(for book: MetadataEdits) async -> Data? {
        if let isbn = book.isbn.flatMap(ISBN.normalized), let data = await image(Self.isbnCoverURL(isbn)) {
            return data
        }
        let title = Matching.mainTitle(book.title)
        guard !title.isEmpty,
              let data = try? await fetch(Self.searchURL(title: title, author: book.authors.first.map(Matching.surname))),
              let id = Self.coverID(data, for: book) else { return nil }
        return await image(Self.idCoverURL(id))
    }

    /// Identifiant de couverture du premier résultat dont le titre et l'auteur concordent.
    static func coverID(_ data: Data, for book: MetadataEdits) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { return nil }
        return docs.first { d in
            guard let t = d["title"] as? String, d["cover_i"] is Int else { return false }
            return Matching.titlesMatch(t, book.title)
                && Matching.authorsMatch(book.authors, (d["author_name"] as? [String]) ?? [])
        }?["cover_i"] as? Int
    }

    /// Une réponse trop petite n'est pas une vraie couverture (image de remplacement).
    private func image(_ url: URL) async -> Data? {
        guard let data = try? await fetch(url), data.count > 1_000 else { return nil }
        return data
    }
}
