import AlexandrieCore
import Foundation
import Observation

/// Envoi des notes et surlignages vers Zotero, par son API locale (S-092 à S-094).
/// Copie à sens unique : rien n'est retiré d'Alexandrie, et ce qui change dans Zotero ne revient pas.
/// Rien ne sort du Mac : Zotero écoute sur `127.0.0.1`.
@MainActor @Observable
final class ZoteroStore {
    enum Status: Equatable {
        case unknown, checking
        case notRunning, disabled
        /// Zotero joignable ; `authorized` : une autorisation « Toujours autoriser » est gardée.
        case ready(authorized: Bool)
        case failed(String)
    }

    private(set) var status: Status = .unknown
    /// Envoi en cours (titre du livre ou de la thématique).
    private(set) var sending: String?
    /// Dernier résultat, montré sous le bouton ou dans une alerte.
    var message: String?

    @ObservationIgnored private let client: ZoteroLocalClient
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let kindle: KindleMonitor
    @ObservationIgnored private let researches: () -> ResearchStore
    @ObservationIgnored private let linksURL: URL
    @ObservationIgnored private var links: ZoteroLinks
    /// Clé gardée en mémoire avec `ALEXANDRIE_STORE` : jamais dans le Trousseau de l'utilisateur en test.
    @ObservationIgnored private var memoryKey: String?
    /// Faux en mode test : la clé reste en mémoire, le Trousseau n'est ni lu ni écrit.
    @ObservationIgnored let useKeychain = AppDirectories.testStore == nil
    static let keychainService = "be.adnmac.alexandrie.zotero"

    init(directories: AppDirectories, library: LibraryStore, kindle: KindleMonitor,
         researches: @escaping () -> ResearchStore, client: ZoteroLocalClient = ZoteroLocalClient()) {
        self.client = client
        self.library = library
        self.kindle = kindle
        self.researches = researches
        linksURL = directories.zotero
        links = ZoteroLinks.load(directories.zotero)
    }

    // MARK: - Autorisation

    private var savedKey: String? {
        get { useKeychain ? Keychain.read(service: Self.keychainService, account: "local") : memoryKey }
        set {
            if useKeychain {
                if let newValue { Keychain.write(newValue, service: Self.keychainService, account: "local") }
                else { Keychain.delete(service: Self.keychainService, account: "local") }
            } else {
                memoryKey = newValue
            }
        }
    }

    /// Relit l'état de Zotero (ouvert, API locale activée).
    func check() async {
        status = .checking
        do {
            try await client.checkReadable()
            status = .ready(authorized: savedKey != nil)
        } catch ZoteroError.notRunning {
            status = .notRunning
        } catch ZoteroError.localAPIDisabled {
            status = .disabled
        } catch {
            status = .failed(ZoteroLocalClient.describe(error))
        }
    }

    /// Oublie l'autorisation gardée (Zotero : Réglages › Avancés › « Effacer les autorisations d'écriture » la retire aussi).
    func forgetAuthorization() {
        savedKey = nil
        if case .ready = status { status = .ready(authorized: false) }
    }

    /// Clé d'écriture : celle gardée, sinon demandée à Zotero (fenêtre « Autoriser / Toujours autoriser »).
    /// Un envoi écrit plusieurs éléments : seule « Toujours autoriser » convient.
    private func writeKey(serverID: String) async throws -> String {
        if let key = savedKey { return key }
        let granted = try await client.authorize(appName: "Alexandrie", serverID: serverID)
        guard granted.remember else { throw ZoteroStoreError.needsAlwaysAllow }
        savedKey = granted.key
        return granted.key
    }

    // MARK: - Envoi

    /// Notes d'un livre : une note « Notes d'Alexandrie » rattachée à sa référence.
    func send(bookKey: String) async {
        guard let entry = kindle.clippingBooks.first(where: { $0.id == bookKey }) else { return }
        let book = library.books(titleKey: bookKey).first { $0.trashedAt == nil }
        let clippings = entry.clippings.filter { !$0.isHidden && $0.kind != .bookmark }
        await run(title: book?.title ?? entry.title) { sender in
            let ref = Self.reference(book, entry: entry)
            let html = ZoteroNote.html(heading: "Notes d'Alexandrie", title: ref.title, author: ref.authors.joined(separator: ", "),
                                       passages: clippings.map { self.passage($0, in: nil) })
            let outcome = try await sender.send(html: html, book: ref, previous: self.links.books[bookKey])
            self.links.books[bookKey] = outcome.link
            return [outcome]
        } summary: { outcomes in
            let o = outcomes[0]
            return "Envoyé à Zotero : \(clippings.count) passage\(clippings.count > 1 ? "s" : ""), référence "
                + (o.createdItem ? "créée" : "retrouvée") + ", note " + (o.createdNote ? "ajoutée." : "mise à jour.")
        }
    }

    /// Thématique : une note par livre, titrée par la thématique et rattachée à la référence du livre.
    func send(thematicID: String) async {
        guard let research = researches().research(id: thematicID) else { return }
        let all = kindle.clippings.filter { !$0.isHidden && $0.kind != .bookmark && $0.thematicIDs.contains(thematicID) }
        let byBook = Dictionary(grouping: all) { ShelfSync.normalize($0.title) }
        guard !byBook.isEmpty else { message = "Cette thématique n'a encore aucun passage."; return }
        await run(title: research.name) { sender in
            var outcomes: [ZoteroSender.Outcome] = []
            for (bookKey, clippings) in byBook.sorted(by: { $0.key < $1.key }) {
                let book = self.library.books(titleKey: bookKey).first { $0.trashedAt == nil }
                let ref = Self.reference(book, title: clippings[0].title, author: clippings[0].author)
                let html = ZoteroNote.html(heading: research.name.isEmpty ? "Thématique" : research.name, title: ref.title,
                                           author: ref.authors.joined(separator: ", "),
                                           passages: clippings.map { self.passage($0, in: thematicID) })
                let key = ZoteroLinks.thematicKey(thematicID, book: bookKey)
                // Même référence que la note du livre, si elle est déjà reliée.
                var previous = self.links.thematicNotes[key]
                if previous == nil, let item = self.links.books[bookKey]?.itemKey { previous = .init(itemKey: item) }
                let outcome = try await sender.send(html: html, book: ref, previous: previous)
                self.links.thematicNotes[key] = outcome.link
                if self.links.books[bookKey] == nil { self.links.books[bookKey] = .init(itemKey: outcome.link.itemKey) }
                outcomes.append(outcome)
            }
            return outcomes
        } summary: { outcomes in
            let created = outcomes.filter(\.createdItem).count
            return "Envoyé à Zotero : \(all.count) passage\(all.count > 1 ? "s" : ""), \(outcomes.count) livre\(outcomes.count > 1 ? "s" : "")"
                + (created > 0 ? " (\(created) référence\(created > 1 ? "s" : "") créée\(created > 1 ? "s" : ""))." : ".")
        }
    }

    /// Enchaîne : serveur, autorisation, envoi ; une autorisation périmée (401) est redemandée une fois.
    private func run(title: String, _ body: @escaping (ZoteroSender) async throws -> [ZoteroSender.Outcome],
                     summary: ([ZoteroSender.Outcome]) -> String) async {
        guard sending == nil else { return }
        sending = title
        message = nil
        defer { sending = nil }
        do {
            let serverID = try await client.serverID()
            // Autre Zotero (autre Mac, profil recréé) : les correspondances ne valent plus.
            if links.serverID != serverID {
                links = ZoteroLinks()
                links.serverID = serverID
            }
            var outcomes: [ZoteroSender.Outcome]
            do {
                outcomes = try await body(ZoteroSender(client: client, serverID: serverID, apiKey: try await writeKey(serverID: serverID)))
            } catch ZoteroError.unauthorized {
                savedKey = nil
                outcomes = try await body(ZoteroSender(client: client, serverID: serverID, apiKey: try await writeKey(serverID: serverID)))
            }
            try links.save(to: linksURL)
            status = .ready(authorized: savedKey != nil)
            message = summary(outcomes)
        } catch {
            try? links.save(to: linksURL)
            if case ZoteroError.localAPIDisabled = error { status = .disabled }
            if case ZoteroError.notRunning = error { status = .notRunning }
            message = "Envoi à Zotero impossible : " + ((error as? ZoteroStoreError)?.errorDescription ?? ZoteroLocalClient.describe(error))
        }
    }

    private func passage(_ c: Clipping, in thematic: String?) -> ZoteroNote.Passage {
        let researches = researches()
        let mark = researches.mark(of: c, in: thematic)
        let named = c.kind == .highlight && !(c.thematicIDs.isEmpty && mark.key == HighlightColor.yellow.hex)
        return .init(clipping: c, colorName: named ? mark.label : nil,
                     thematics: thematic == nil ? researches.thematicNames(of: c) : [])
    }

    static func reference(_ book: Book?, entry: ClippingBook) -> ZoteroBookRef {
        reference(book, title: entry.title, author: entry.author)
    }

    /// Fiche Alexandrie (corrections comprises), ou à défaut titre et auteur des relevés.
    static func reference(_ book: Book?, title: String, author: String) -> ZoteroBookRef {
        guard let book else {
            return ZoteroBookRef(title: title, authors: author.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        return ZoteroBookRef(title: book.title, authors: book.authors, isbn: book.isbn, publisher: book.publisher,
                             date: book.publishedDate, language: book.language, summary: book.summary)
    }
}

enum ZoteroStoreError: LocalizedError {
    case needsAlwaysAllow
    var errorDescription: String? {
        "dans la fenêtre de Zotero, choisissez « Toujours autoriser » : chaque envoi écrit plusieurs éléments (référence et note)."
    }
}
