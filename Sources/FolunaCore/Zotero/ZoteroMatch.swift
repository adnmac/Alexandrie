import Foundation

/// Référence Zotero d'un livre de la bibliothèque : retrouvée, ou décrite pour être créée.
public enum ZoteroMatch {
    /// Mots de recherche : titre principal et nom du premier auteur.
    public static func searchTerms(title: String, authors: [String]) -> String {
        let main = Matching.mainTitle(title)
        let author = authors.first.map(Matching.surname) ?? ""
        return [main, author].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// La référence du livre parmi les résultats : même ISBN d'abord, sinon titre et auteurs concordants.
    public static func best(_ items: [ZoteroItem], title: String, authors: [String], isbn: String?) -> ZoteroItem? {
        let books = items.filter { ($0.itemType == "book" || $0.itemType == "bookSection") && !$0.deleted }
        if let isbn = isbn.flatMap(ISBN.normalized),
           let same = books.first(where: { item in ISBN.first(in: (item.isbn ?? "").split(separator: " ").map(String.init)) == isbn }) {
            return same
        }
        return books.first { item in
            Matching.titlesMatch(item.title, title)
                && (authors.isEmpty || item.creators.isEmpty || Matching.authorsMatch(authors, item.creators))
        }
    }

    /// Élément `book` décrit d'après la fiche Foluna.
    public static func bookItem(title: String, authors: [String], isbn: String?, publisher: String?,
                                date: String?, language: String?, summary: String?) -> [String: Any] {
        var item: [String: Any] = [
            "itemType": "book",
            "title": title,
            "creators": authors.map(creator),
            "tags": [["tag": "Foluna"]],
        ]
        if let isbn = isbn.flatMap(ISBN.normalized) { item["ISBN"] = isbn }
        if let publisher, !publisher.isEmpty { item["publisher"] = publisher }
        if let date, !date.isEmpty { item["date"] = date }
        if let language, !language.isEmpty { item["language"] = language }
        if let summary, !summary.isEmpty { item["abstractNote"] = summary }
        return item
    }

    private static let particles: Set<String> = ["de", "du", "des", "d'", "la", "le", "van", "von", "der", "den", "di", "da", "del"]

    /// Auteur Zotero : « Verne, Jules » ou « Jules Verne » → nom et prénom ; un seul mot → `name`.
    /// Les particules restent avec le nom (« Honoré de Balzac » → « de Balzac », « Honoré »).
    public static func creator(_ author: String) -> [String: String] {
        let a = author.trimmingCharacters(in: .whitespaces)
        if let comma = a.firstIndex(of: ",") {
            let last = a[..<comma].trimmingCharacters(in: .whitespaces)
            let first = a[a.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !last.isEmpty && !first.isEmpty { return ["creatorType": "author", "firstName": first, "lastName": last] }
        }
        var words = a.split(separator: " ").map(String.init)
        guard words.count > 1 else { return ["creatorType": "author", "name": a] }
        var last = [words.removeLast()]
        while let w = words.last, particles.contains(w.lowercased()), words.count > 1 { last.insert(words.removeLast(), at: 0) }
        return ["creatorType": "author", "firstName": words.joined(separator: " "), "lastName": last.joined(separator: " ")]
    }
}
