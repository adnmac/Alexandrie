import AlexandrieCore
import Foundation
import Observation

/// Catalogues OPDS publics (S-086 à S-089) : liste enregistrée dans `opds.json`, pages ouvertes par catalogue,
/// téléchargements. Aucune requête ne part avant qu'un catalogue soit ouvert dans la barre latérale.
@MainActor @Observable
final class OPDSStore {
    /// Page ouverte d'un catalogue : un flux chargé, en cours de chargement, ou en échec.
    struct Page: Identifiable {
        let id = UUID()
        var title: String
        var url: URL
        /// Mots cherchés, pour une page de résultats.
        var terms: String?
        var feed: OPDSFeed?
        var error: String?
        var loadingMore = false
        var isLoading: Bool { feed == nil && error == nil }
    }

    private(set) var list: OPDSCatalogList
    /// Pages ouvertes, de l'accueil à la page affichée, par catalogue.
    private(set) var stacks: [String: [Page]] = [:]
    /// Entrée choisie dans la page affichée, par catalogue (sa fiche est à droite).
    var selection: [String: OPDSEntry.ID] = [:]
    /// Fichiers en cours de téléchargement (adresses).
    private(set) var downloading: Set<URL> = []
    /// Dernier téléchargement en échec : entrée et message.
    private(set) var downloadError: (entry: OPDSEntry.ID, message: String)?
    /// « Afficher dans la bibliothèque » : la fenêtre passe à ce livre.
    var showRequest: Book.ID?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let client: OPDSClient
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var templates: [String: OPDSSearchTemplate] = [:]
    @ObservationIgnored private var covers: [URL: URL] = [:]
    @ObservationIgnored private let coverDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Alexandrie-OPDS", isDirectory: true)

    init(directories: AppDirectories, library: LibraryStore, client: OPDSClient = OPDSClient()) {
        url = directories.opds
        list = OPDSCatalogList.load(directories.opds)
        self.client = client
        self.library = library
    }

    var catalogs: [OPDSCatalog] { list.catalogs }

    func catalog(id: String) -> OPDSCatalog? { list.catalog(id: id) }

    // MARK: - Navigation

    /// Page affichée d'un catalogue.
    func current(_ id: String) -> Page? { stacks[id]?.last }

    func path(_ id: String) -> [Page] { stacks[id] ?? [] }

    /// Ouvre l'accueil du catalogue à la première visite.
    func open(_ id: String) async {
        guard stacks[id]?.isEmpty ?? true, let catalog = catalog(id: id) else { return }
        await push(id, url: catalog.url, title: catalog.name)
    }

    /// Ouvre un sous-catalogue (entrée de navigation, « Du même auteur »…).
    func push(_ id: String, url: URL, title: String, terms: String? = nil) async {
        let page = Page(title: title, url: url, terms: terms)
        stacks[id, default: []].append(page)
        selection[id] = nil
        await load(id, page: page.id)
    }

    /// Revient à la page `index` du chemin (0 : accueil).
    func back(_ id: String, to index: Int) {
        guard var stack = stacks[id], index >= 0, index < stack.count - 1 else { return }
        stack.removeSubrange((index + 1)...)
        stacks[id] = stack
        selection[id] = nil
    }

    func reload(_ id: String) async {
        guard let page = current(id) else { return await open(id) }
        update(id, page.id) { $0.feed = nil; $0.error = nil }
        await load(id, page: page.id)
    }

    /// Page suivante du flux affiché, ajoutée à la suite (« Plus de résultats »).
    func loadMore(_ id: String) async {
        guard let page = current(id), let next = page.feed?.nextURL, !page.loadingMore else { return }
        update(id, page.id) { $0.loadingMore = true }
        do {
            let more = try await client.feed(at: listURL(next, in: id))
            update(id, page.id) { p in
                let known = Set(p.feed?.entries.map(\.id) ?? [])
                p.feed?.entries += more.entries.filter { !known.contains($0.id) }
                p.feed?.nextURL = more.nextURL == next ? nil : more.nextURL
                p.loadingMore = false
            }
        } catch {
            update(id, page.id) { $0.loadingMore = false; $0.feed?.nextURL = nil }
        }
    }

    private func load(_ id: String, page: UUID) async {
        guard let url = stacks[id]?.first(where: { $0.id == page })?.url else { return }
        do {
            let feed = try await client.feed(at: listURL(url, in: id))
            update(id, page) { p in
                p.feed = feed
                if p.terms == nil, p.title.isEmpty { p.title = feed.title }
            }
        } catch {
            update(id, page) { $0.error = OPDSClient.describe(error) }
        }
    }

    private func update(_ id: String, _ page: UUID, _ change: (inout Page) -> Void) {
        guard let i = stacks[id]?.firstIndex(where: { $0.id == page }) else { return }
        change(&stacks[id]![i])
    }

    // MARK: - Recherche (S-087)

    /// Le catalogue a une recherche (annoncée par une de ses pages ouvertes).
    func canSearch(_ id: String) -> Bool {
        templates[id] != nil || path(id).contains { $0.feed?.search != nil }
    }

    func search(_ id: String, terms: String) async {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = "« \(trimmed) »"
        do {
            let template: OPDSSearchTemplate
            if let known = templates[id] {
                template = known
            } else {
                guard let link = path(id).reversed().compactMap({ $0.feed?.search }).first else { throw OPDSError.noSearch }
                template = try await client.searchTemplate(link)
                templates[id] = template
            }
            let sent = catalog(id: id).map { OPDSLanguage.terms(trimmed, language: language(id), catalog: $0) } ?? trimmed
            guard let url = template.url(for: sent) else { throw OPDSError.noSearch }
            // Une nouvelle recherche remplace la précédente plutôt que de s'empiler.
            if current(id)?.terms != nil { stacks[id]?.removeLast() }
            await push(id, url: url, title: title, terms: trimmed)
        } catch {
            if current(id)?.terms != nil { stacks[id]?.removeLast() }
            var page = Page(title: title, url: current(id)?.url ?? catalog(id: id)?.url ?? URL(fileURLWithPath: "/"), terms: trimmed)
            page.error = OPDSClient.describe(error)
            stacks[id, default: []].append(page)
        }
    }

    // MARK: - Langue (S-090)

    /// Le catalogue a des livres en plusieurs langues (les catalogues tout en français n'ont pas de choix).
    func offersLanguages(_ id: String) -> Bool { catalog(id: id).map { $0.onlyLanguage == nil } ?? false }

    /// Langue choisie (code ISO 639-1) ; nil : toutes les langues.
    func language(_ id: String) -> String? { offersLanguages(id) ? list.languages[id] : nil }

    /// Change la langue ; la page affichée est rechargée avec elle (recherche relancée, liste restreinte).
    func setLanguage(_ id: String, _ code: String?) async {
        guard code != language(id) else { return }
        list.languages[id] = code
        save()
        if let selected = selection[id], let entry = current(id)?.feed?.entries.first(where: { $0.id == selected }),
           !OPDSLanguage.keeps(entry, language: code, in: catalog(id: id)) {
            selection[id] = nil
        }
        if let terms = current(id)?.terms {
            await search(id, terms: terms)
        } else if let catalog = catalog(id: id), let url = current(id)?.url,
                  OPDSLanguage.restrictsOnServer(url, catalog: catalog) {
            // Liste que le serveur sait restreindre : rechargée, pour avoir des pages entières dans la langue.
            await reload(id)
        }
    }

    /// Adresse d'une liste, restreinte à la langue choisie quand le serveur le permet.
    private func listURL(_ url: URL, in id: String) -> URL {
        guard let catalog = catalog(id: id) else { return url }
        return OPDSLanguage.url(url, language: language(id), catalog: catalog)
    }

    /// Entrées affichées de la page : les livres d'une autre langue sont écartés, et comptés.
    func visibleEntries(_ id: String) -> (entries: [OPDSEntry], hidden: Int) {
        let all = current(id)?.feed?.entries ?? []
        let catalog = catalog(id: id)
        let shown = all.filter { OPDSLanguage.keeps($0, language: language(id), in: catalog) }
        return (shown, all.count - shown.count)
    }

    // MARK: - Téléchargement (S-088)

    /// Livre de la bibliothèque téléchargé depuis cette entrée (s'il y est encore).
    func libraryBook(for entry: OPDSEntry) -> Book? {
        guard let path = list.downloads[entry.id] else { return nil }
        return library.book(id: path).flatMap { $0.trashedAt == nil ? $0 : nil }
    }

    func isDownloading(_ entry: OPDSEntry) -> Bool { entry.acquisitions.contains { downloading.contains($0.url) } }

    /// Télécharge le fichier et l'ajoute à la bibliothèque, comme « Importer ». L'envoi à la liseuse reste à part.
    @discardableResult
    func download(_ acquisition: OPDSAcquisition, of entry: OPDSEntry) async -> Book? {
        guard !downloading.contains(acquisition.url) else { return nil }
        downloading.insert(acquisition.url)
        downloadError = nil
        defer { downloading.remove(acquisition.url) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Alexandrie-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let file = try await client.download(acquisition, of: entry, into: temp)
            guard let book = await library.importDownloaded(file) else {
                downloadError = (entry.id, library.lastError ?? String(localized: "Le livre n'a pas pu être ajouté à la bibliothèque."))
                library.lastError = nil
                return nil
            }
            list.downloads[entry.id] = book.id
            save()
            return book
        } catch {
            downloadError = (entry.id, OPDSClient.describe(error))
            return nil
        }
    }

    /// Couverture réduite d'une entrée, gardée dans un dossier temporaire le temps de la session.
    func cover(for entry: OPDSEntry) async -> URL? {
        guard let remote = entry.thumbnailURL else { return nil }
        if let local = covers[remote] { return local }
        guard let data = try? await client.image(at: remote) else { return nil }
        try? FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        let local = coverDirectory.appendingPathComponent(UUID().uuidString)
        guard (try? data.write(to: local)) != nil else { return nil }
        covers[remote] = local
        return local
    }

    // MARK: - Gestion des catalogues (S-089)

    /// Vérifie l'adresse en chargeant le flux, puis ajoute le catalogue ; rend un message d'erreur sinon.
    func add(name: String, address: String) async -> Result<OPDSCatalog, OPDSAddError> {
        guard let url = OPDSURL.parse(address) else { return .failure(.init(message: String(localized: "Adresse invalide : saisissez une adresse https://…"))) }
        do {
            let feed = try await client.feed(at: url)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let catalog = list.add(name: trimmed.isEmpty ? feed.title : trimmed, url: url)
            save()
            return .success(catalog)
        } catch {
            return .failure(.init(message: OPDSClient.describe(error)))
        }
    }

    func rename(_ id: String, to name: String) {
        list.rename(id, to: name)
        save()
    }

    func remove(_ id: String) {
        list.remove(id)
        stacks[id] = nil
        selection[id] = nil
        templates[id] = nil
        save()
    }

    func restoreSuggestions() {
        list.restoreSuggestions()
        save()
    }

    private func save() {
        do { try list.save(to: url) } catch {
            library.lastError = String(localized: "Catalogues non enregistrés : \(error.localizedDescription)")
        }
    }
}

struct OPDSAddError: Error {
    let message: String
}
