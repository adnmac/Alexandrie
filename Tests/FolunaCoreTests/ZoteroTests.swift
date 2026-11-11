import Foundation
import Testing
@testable import FolunaCore

@Suite struct ZoteroMatchTests {
    @Test func splitsAuthorNames() {
        #expect(ZoteroMatch.creator("Jules Verne") == ["creatorType": "author", "firstName": "Jules", "lastName": "Verne"])
        #expect(ZoteroMatch.creator("Verne, Jules") == ["creatorType": "author", "firstName": "Jules", "lastName": "Verne"])
        #expect(ZoteroMatch.creator("Honoré de Balzac")["lastName"] == "de Balzac")
        #expect(ZoteroMatch.creator("Ludwig van Beethoven")["lastName"] == "van Beethoven")
        #expect(ZoteroMatch.creator("Homère") == ["creatorType": "author", "name": "Homère"])
    }

    @Test func picksTheReference() {
        let byISBN = ZoteroItem(key: "A", version: 1, itemType: "book", title: "Autre titre", isbn: "978-2-07-036002-4")
        let byTitle = ZoteroItem(key: "B", version: 1, itemType: "book", title: "L'Étranger", creators: ["Albert Camus"])
        let article = ZoteroItem(key: "C", version: 1, itemType: "journalArticle", title: "L'Étranger", creators: ["Albert Camus"])
        let otherAuthor = ZoteroItem(key: "D", version: 1, itemType: "book", title: "L'Étranger", creators: ["Jean Dupont"])
        #expect(ZoteroMatch.best([byTitle, byISBN], title: "L'étranger", authors: ["Albert Camus"], isbn: "2070360024")?.key == "A",
                "même ISBN d'abord")
        #expect(ZoteroMatch.best([article, otherAuthor, byTitle], title: "L'étranger", authors: ["Camus, Albert"], isbn: nil)?.key == "B")
        #expect(ZoteroMatch.best([article, otherAuthor], title: "L'étranger", authors: ["Albert Camus"], isbn: nil) == nil)
        #expect(ZoteroMatch.searchTerms(title: "L'Étranger : roman", authors: ["Albert Camus"]).contains("Camus"))
    }

    @Test func describesABook() {
        let item = ZoteroMatch.bookItem(title: "L'Étranger", authors: ["Albert Camus"], isbn: "2-07-036002-4", publisher: "Gallimard",
                                        date: "1942", language: "fr", summary: nil)
        #expect(item["itemType"] as? String == "book")
        #expect(item["ISBN"] as? String == "9782070360024")
        #expect(item["publisher"] as? String == "Gallimard" && item["abstractNote"] == nil)
        #expect((item["creators"] as? [[String: String]])?.first?["lastName"] == "Camus")
    }
}

@Suite struct ZoteroNoteTests {
    @Test func escapesAndOrders() {
        var late = Clipping(title: "Livre", author: "A", kind: .highlight, location: "page 40", added: "lundi", text: "Fin <b>& \"tout\"</b>")
        late.note = "ma note\nsur deux lignes"
        let early = Clipping(title: "Livre", author: "A", kind: .highlight, location: "page 3", added: "mardi", text: "Début")
        let html = ZoteroNote.html(heading: "Notes de Foluna", title: "Livre <1>", author: "A",
                                   passages: [.init(clipping: late, colorName: "Construction", thematics: ["Mémoire"]),
                                              .init(clipping: early)])
        #expect(html.contains("<h1>Notes de Foluna — Livre &lt;1&gt;</h1>"))
        #expect(html.contains("Fin &lt;b&gt;&amp; &quot;tout&quot;&lt;/b&gt;"))
        #expect(html.contains("📝 ma note<br/>sur deux lignes"))
        #expect(html.contains("Construction · Mémoire · page 40 · lundi"))
        #expect(html.contains("2 passages"))
        #expect(html.range(of: "Début")!.lowerBound < html.range(of: "Fin")!.lowerBound, "ordre de lecture")
    }

    @Test func savesLinks() throws {
        var links = ZoteroLinks()
        links.books["letranger"] = .init(itemKey: "A", noteKey: "N", noteVersion: 3, sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        links.thematicNotes[ZoteroLinks.thematicKey("t1", book: "letranger")] = .init(itemKey: "A", noteKey: "M")
        links.serverID = "abc"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zotero-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try links.save(to: file)
        #expect(ZoteroLinks.load(file) == links)
        #expect(ExternalBackup.dataFiles.contains("zotero.json"), "dans la sauvegarde")
    }
}

@Suite struct ZoteroClientTests {
    let book = ZoteroBookRef(title: "L'Étranger", authors: ["Albert Camus"], isbn: "2070360024", publisher: "Gallimard")

    func sender(_ server: ZoteroMemoryServer) async throws -> ZoteroSender {
        let client = ZoteroLocalClient(transport: server.transport)
        let id = try await client.serverID()
        let key = try await client.authorize(appName: "Foluna", serverID: id)
        #expect(key.remember)
        return ZoteroSender(client: client, serverID: id, apiKey: key.key)
    }

    @Test func createsThenUpdatesWithoutDuplicates() async throws {
        let server = ZoteroMemoryServer()
        let s = try await sender(server)
        let first = try await s.send(html: "<p>un</p>", book: book, previous: nil)
        #expect(first.createdItem && first.createdNote)
        #expect(server.list().map { $0.json["itemType"] as? String } == ["book", "note"])
        #expect(server.list()[1].json["parentItem"] as? String == first.link.itemKey)

        let second = try await s.send(html: "<p>deux</p>", book: book, previous: first.link)
        #expect(!second.createdItem && !second.createdNote && second.link.noteKey == first.link.noteKey)
        #expect(server.list().count == 2)
        #expect(server.list()[1].json["note"] as? String == "<p>deux</p>")

        // Modifiée dans Zotero entre-temps (version avancée) : relue, puis mise à jour.
        server.touch(first.link.noteKey!)
        let third = try await s.send(html: "<p>trois</p>", book: book, previous: second.link)
        #expect(!third.createdNote && server.list()[1].json["note"] as? String == "<p>trois</p>")

        // Supprimée dans Zotero : recréée sur la même référence.
        server.delete(first.link.noteKey!)
        let fourth = try await s.send(html: "<p>quatre</p>", book: book, previous: third.link)
        #expect(fourth.createdNote && !fourth.createdItem && fourth.link.itemKey == first.link.itemKey)
    }

    @Test func findsAnExistingReference() async throws {
        let server = ZoteroMemoryServer()
        let s = try await sender(server)
        let existing = try await ZoteroLocalClient(transport: server.transport).create(
            ZoteroMatch.bookItem(title: "L'Étranger", authors: ["Albert Camus"], isbn: nil, publisher: nil, date: nil,
                                 language: nil, summary: nil), key: "key1", serverID: server.serverID)
        let sent = try await s.send(html: "<p>x</p>", book: book, previous: nil)
        #expect(!sent.createdItem && sent.link.itemKey == existing.key)
        // Référence supprimée dans Zotero : une nouvelle est retrouvée ou créée.
        server.delete(existing.key)
        let again = try await s.send(html: "<p>y</p>", book: book, previous: sent.link)
        #expect(again.createdItem && again.link.itemKey != existing.key)
    }

    @Test func explainsFailures() async throws {
        let server = ZoteroMemoryServer()
        let client = ZoteroLocalClient(transport: server.transport)
        server.enabled = false
        await #expect(throws: ZoteroError.localAPIDisabled) { try await client.checkReadable() }
        server.enabled = true
        server.authorizeRemember = nil
        await #expect(throws: ZoteroError.denied) { try await client.authorize(appName: "A", serverID: server.serverID) }
        let s = ZoteroSender(client: client, serverID: server.serverID, apiKey: "inconnue")
        await #expect(throws: ZoteroError.unauthorized) { try await s.send(html: "", book: book, previous: nil) }
        let down = ZoteroLocalClient { _ in throw ZoteroError.notRunning }
        await #expect(throws: ZoteroError.notRunning) { try await down.serverID() }
        let old = ZoteroLocalClient { _ in ZoteroResponse(status: 404) }
        await #expect(throws: ZoteroError.tooOld) { try await old.authorize(appName: "A", serverID: "x") }
        #expect(ZoteroLocalClient.describe(ZoteroError.localAPIDisabled).contains("Réglages › Avancés"))
    }

    @Test func readsCreationResponses() throws {
        let both = ZoteroResponse(status: 200, data: Data(#"{"successful":{"0":{"key":"ABCD1234","version":7}},"success":{"0":"ABCD1234"}}"#.utf8))
        #expect(try ZoteroLocalClient.created(both) == ("ABCD1234", 7))
        let short = ZoteroResponse(status: 200, headers: ["Last-Modified-Version": "9"], data: Data(#"{"success":{"0":"EFGH"}}"#.utf8))
        #expect(try ZoteroLocalClient.created(short) == ("EFGH", 9))
        let failed = ZoteroResponse(status: 200, data: Data(#"{"failed":{"0":{"code":400,"message":"Bad parent"}}}"#.utf8))
        #expect(throws: ZoteroError.failed(200, "Bad parent")) { try ZoteroLocalClient.created(failed) }
    }
}
