import Foundation

/// Livre tel que Foluna le décrit, pour retrouver ou créer sa référence Zotero.
public struct ZoteroBookRef: Sendable, Equatable {
    public var title: String
    public var authors: [String]
    public var isbn: String?
    public var publisher: String?
    public var date: String?
    public var language: String?
    public var summary: String?

    public init(title: String, authors: [String], isbn: String? = nil, publisher: String? = nil,
                date: String? = nil, language: String? = nil, summary: String? = nil) {
        self.title = title
        self.authors = authors
        self.isbn = isbn
        self.publisher = publisher
        self.date = date
        self.language = language
        self.summary = summary
    }
}

/// Envoi d'une note : référence retrouvée ou créée, note créée ou mise à jour (sans doublon).
public struct ZoteroSender: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var link: ZoteroLinks.Link
        public var createdItem: Bool
        public var createdNote: Bool
    }

    let client: ZoteroLocalClient
    let serverID: String
    let apiKey: String

    public init(client: ZoteroLocalClient, serverID: String, apiKey: String) {
        self.client = client
        self.serverID = serverID
        self.apiKey = apiKey
    }

    public func send(html: String, book: ZoteroBookRef, previous: ZoteroLinks.Link?, now: Date = Date()) async throws -> Outcome {
        // Référence : celle déjà reliée si elle existe encore, sinon retrouvée, sinon créée.
        var itemKey: String?
        if let known = previous?.itemKey {
            do { itemKey = try await client.item(known).key } catch ZoteroError.notFound { itemKey = nil }
        }
        var createdItem = false
        if itemKey == nil {
            let found = try await client.searchBooks(ZoteroMatch.searchTerms(title: book.title, authors: book.authors))
            itemKey = ZoteroMatch.best(found, title: book.title, authors: book.authors, isbn: book.isbn)?.key
        }
        if itemKey == nil {
            let item = ZoteroMatch.bookItem(title: book.title, authors: book.authors, isbn: book.isbn, publisher: book.publisher,
                                           date: book.date, language: book.language, summary: book.summary)
            itemKey = try await client.create(item, key: apiKey, serverID: serverID).key
            createdItem = true
        }
        guard let parent = itemKey else { throw ZoteroError.notFound }

        // Note : mise à jour si elle existe encore (et est toujours rattachée au livre), sinon recréée.
        if !createdItem, let noteKey = previous?.noteKey, previous?.itemKey == parent {
            do {
                // Toujours relue : vérifie aussi que la note existe encore (corbeille de Zotero comprise).
                let version = try await client.item(noteKey).version
                let next: Int
                do {
                    next = try await client.updateNote(noteKey, html: html, version: version, key: apiKey, serverID: serverID)
                } catch ZoteroError.conflict {
                    // Modifiée dans Zotero depuis : version relue, une seule nouvelle tentative.
                    let fresh = try await client.item(noteKey).version
                    next = try await client.updateNote(noteKey, html: html, version: fresh, key: apiKey, serverID: serverID)
                }
                return Outcome(link: .init(itemKey: parent, noteKey: noteKey, noteVersion: next, sentAt: now),
                               createdItem: false, createdNote: false)
            } catch ZoteroError.notFound {
                // Supprimée dans Zotero : recréée plus bas.
            }
        }
        let note: [String: Any] = ["itemType": "note", "note": html, "parentItem": parent, "tags": [["tag": "Foluna"]]]
        let created = try await client.create(note, key: apiKey, serverID: serverID)
        return Outcome(link: .init(itemKey: parent, noteKey: created.key, noteVersion: created.version, sentAt: now),
                       createdItem: createdItem, createdNote: true)
    }

}
