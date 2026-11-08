import AlexandrieCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(UpdateMonitor.self) private var updates
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var sidebar: SidebarItem? = .all
    /// Identifiants de lignes : livre seul, groupe (`group:…`) ou fichier d'un groupe.
    @State private var selection = Set<String>()
    @State private var kindleSelection: KindleDocument.ID?
    @State private var search = ""
    /// Champ de recherche : fiches des livres, ou leur texte (S-082).
    @State private var searchScope: SearchScope = .titles
    /// Écriture exacte dans le contenu (S-084), gardée d'une recherche à l'autre.
    @AppStorage("contentSearchExact") private var contentSearchExact = false
    @Environment(ContentIndexer.self) private var contentIndexer
    @Environment(OPDSStore.self) private var opds
    @Environment(ZoteroStore.self) private var zotero
    @State private var sort: SortOrder = .title
    @AppStorage("gridMode") private var gridMode = true
    /// Page et sélection rendues au lancement suivant. Dans les réglages de l'app, pas dans l'état de la
    /// fenêtre (@SceneStorage) : macOS jette celui-ci au ⌘Q quand « Fermer les fenêtres à la fermeture
    /// d'une app » est coché, le réglage par défaut.
    @AppStorage("lastSidebarPage") private var savedPage = ""
    @AppStorage("lastSelectedBooks") private var savedSelection = ""
    @State private var isDropTargeted = false
    @State private var showReview = false
    /// Livre annoté choisi dans la vue Notes (titre normalisé).
    @State private var notesBook: String?
    /// Fichier montré par Coup d'œil (Espace, ou Livre > Coup d'œil).
    @State private var quickLookURL: URL?

    // La chaîne de modificateurs est coupée en trois propriétés : d'un seul tenant, le Swift de la CI
    // (macos-15) n'arrivait plus à la typer à temps.
    var body: some View {
        withNavigation
            .onChange(of: undoManager) { _, manager in library.undoManager = manager }
            // Kindle inconnue : on lui donne un nom, une fois pour toutes.
            .sheet(isPresented: Binding(get: { kindle.needsNaming }, set: { if !$0 { kindle.postponeNaming() } })) {
                NameReaderSheet()
            }
            // Résultat d'un envoi à Zotero (S-093, S-094).
            .alert("Zotero", isPresented: Binding(get: { zotero.message != nil }, set: { if !$0 { zotero.message = nil } })) {
                Button("OK") { zotero.message = nil }
            } message: {
                Text(zotero.message ?? "")
            }
            .alert("Erreur", isPresented: errorBinding) {
                Button("OK") { library.lastError = nil; kindle.lastError = nil }
            } message: {
                Text(library.lastError ?? kindle.lastError ?? "")
            }
    }

    /// Page, sélection, demandes venues des autres vues (notes, catalogues) et tâches de fond.
    private var withNavigation: some View {
        withSheets
        // Texte des livres indexé en arrière-plan (S-081), après chaque analyse du dossier ou ajout.
        .onChange(of: library.isScanning, initial: true) { _, scanning in
            if !scanning { contentIndexer.refresh(books: library.visibleBooks, identities: library.identities) }
        }
        .onChange(of: library.visibleBooks.count) { contentIndexer.refresh(books: library.visibleBooks, identities: library.identities) }
        // Catalogue en ligne (S-088) : « Afficher dans la bibliothèque » montre le livre téléchargé.
        .onChange(of: opds.showRequest) { _, id in
            guard let id else { return }
            search = ""
            sidebar = .all
            selection = [id]
            opds.showRequest = nil
        }
        .onChange(of: sidebar) { _, page in savedPage = page?.storageKey ?? "" }
        .onChange(of: selection) { _, ids in savedSelection = ids.sorted().joined(separator: "\n") }
        .onAppear { ReaderWindows.open = { [openWindow] id in openWindow(id: "lecture", value: id) } }
        // Sauvegarde du jour dans le dossier choisi (jamais pendant les captures).
        .onAppear { if Snapshot.directory == nil { AppServices.shared.backups.start() } }
        .task {
            guard Snapshot.directory != nil else { return }
            await Snapshot.run(library: library, kindle: kindle, sidebar: $sidebar, selection: $selection, notesBook: $notesBook,
                               search: $search, searchScope: $searchScope, openSettings: openSettings)
        }
    }

    /// Fenêtre principale ou accueil, et les feuilles qui s'ouvrent d'elles-mêmes.
    private var withSheets: some View {
        Group {
            if library.hasLibrary {
                main
            } else {
                OnboardingView()
            }
        }
        // La liseuse vient d'être branchée : la file d'attente part.
        .onChange(of: kindle.isConnected) { _, connected in
            if connected { Task { await kindle.sendPending(library: library) } }
        }
        .sheet(isPresented: $showReview) { CatalogReviewSheet() }
        // Après un plantage : le rapport n'est envoyé que si l'utilisateur le décide.
        .sheet(isPresented: Binding(get: { !CrashReports.shared.pending.isEmpty && Snapshot.directory == nil },
                                    set: { _ in })) { CrashReportSheet() }
        // Bibliothèque d'avant l'audit : la vérification en ligne attend une réponse, posée une fois.
        .sheet(isPresented: Binding(get: { library.hasLibrary && !library.catalogConsentAnswered
                                         && AppDirectories.testStore == nil && Snapshot.directory == nil },
                                    set: { _ in })) { CatalogConsentSheet() }
        // Depuis la fiche : « Voir les notes » ouvre la vue Notes sur ce livre.
        .onChange(of: kindle.notesRequest) { _, key in
            guard let key else { return }
            sidebar = .notes
            notesBook = key
            kindle.notesRequest = nil
        }
        .onAppear {
            library.undoManager = undoManager
            restorePage()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { library.lastError != nil || kindle.lastError != nil },
                set: { if !$0 { library.lastError = nil; kindle.lastError = nil } })
    }

    private var main: some View {
        let groups = BookGroups.make(filteredBooks, identities: library.identities)
        let index = Dictionary(groups.filter(\.isGroup).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Un groupe sélectionné vaut pour son fichier principal (fiche, envoi à la liseuse).
        let resolve: (String) -> Book? = { id in
            BookGroups.isGroupID(id) ? index[id]?.primary : library.book(id: id)
        }
        let selected = Self.unique(selection.sorted().compactMap(resolve))
        let commands = BookCommands(
            books: sidebar == .kindle || sidebar == .notes || sidebar?.isThematic == true || sidebar?.catalogID != nil
                ? [] : selected,
            list: sidebar, library: library, kindle: kindle,
            afterTrash: { selection = Self.nextSelection(after: selection, in: groups) },
            toggleQuickLook: { quickLookURL = quickLookURL == nil ? selected.first?.url : nil })
        // Les actions des menus relisent les commandes du dernier affichage (livres, page, fermetures à jour).
        MenuState.shared.current = commands
        return NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            Group {
                if sidebar == .kindle {
                    KindleView(search: search, gridMode: gridMode, selection: $kindleSelection)
                } else if case .thematic(let id) = sidebar {
                    // Toutes les notes d'une thématique, de tous les livres (S-080).
                    ThematicNotesView(thematicID: id, search: search, selectedBook: $notesBook).id(id)
                } else if sidebar == .notes {
                    // Livres annotés (colonne étroite) et notes du livre choisi (large) ; sa fiche est à droite.
                    HSplitView {
                        NotesBookList(search: search, selection: $notesBook)
                            .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
                        Group {
                            if let key = notesBook {
                                NotesEditor(bookKey: key).id(key)
                            } else {
                                ContentUnavailableView("Choisissez un livre", systemImage: "highlighter",
                                                       description: Text("Ses notes et surlignages s'afficheront ici."))
                            }
                        }
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let id = sidebar?.catalogID {
                    // Catalogue OPDS (S-086) : la recherche part à la validation du champ (S-087).
                    OPDSCatalogView(catalogID: id).id(id)
                } else if searchScope == .content && !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentSearchView(query: search.trimmingCharacters(in: .whitespaces), exact: contentSearchExact,
                                      selection: $selection)
                } else {
                    libraryPage(groups: groups, selected: selected, resolve: resolve)
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 640)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Où chercher (S-082) : visible dès qu'une recherche est tapée, sur les pages de livres.
                if !search.trimmingCharacters(in: .whitespaces).isEmpty && sidebar != .kindle && sidebar != .notes
                    && sidebar?.isThematic != true && sidebar?.catalogID == nil {
                    SearchScopeBar(scope: $searchScope, exact: $contentSearchExact)
                }
                if let release = updates.releaseBanner {
                    ReleaseBanner(release: release)
                } else if let info = updates.banner {
                    UpdateBanner(info: info)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
            .onSubmit(of: .search) {
                guard let id = sidebar?.catalogID else { return }
                Task { await opds.search(id, terms: search) }
            }

        } detail: {
            Group {
                if let id = sidebar?.catalogID {
                    OPDSEntryDetailView(catalogID: id)
                } else if sidebar == .notes || sidebar?.isThematic == true {
                    if let key = notesBook, let book = library.books(titleKey: key).first(where: { $0.trashedAt == nil }) {
                        let identity = library.identity(of: book)
                        let files = library.visibleBooks.filter { library.identity(of: $0) == identity }
                        BookDetailView(book: BookGroups.make(files, identities: library.identities).first?.primary ?? book,
                                       files: files)
                            .id(book.id)
                    } else {
                        ContentUnavailableView("Aucune fiche", systemImage: "book.closed",
                                               description: Text("Le livre annoté n'est pas dans la bibliothèque."))
                    }
                } else if sidebar == .kindle {
                    if let doc = kindle.documents.first(where: { $0.id == kindleSelection }) {
                        KindleBookDetailView(document: doc).id(doc.id)
                    } else if kindle.device == nil {
                        // Sans Kindle, le message de la liste suffit : pas de second message vide de sens.
                        Color.clear
                    } else {
                        ContentUnavailableView("Aucun livre sélectionné", systemImage: "book.closed",
                                               description: Text("Choisissez un livre de la liseuse pour voir sa fiche."))
                    }
                } else if selected.count > 1 {
                    MultiSelectionView(books: selected)
                } else if let book = selected.first {
                    // Les autres fichiers du même livre reçoivent les corrections et sont listés dans la fiche.
                    let files = groups.first { $0.books.contains { $0.id == book.id } }?.books ?? [book]
                    BookDetailView(book: book, files: files)
                        .id(book.id)
                } else {
                    ContentUnavailableView("Aucun livre sélectionné", systemImage: "book.closed",
                                           description: Text("Choisissez un livre pour voir sa fiche."))
                }
            }
            // Sans minimum, la fiche était écrasée à 170 pt dans la vue Notes (boutons et titres tronqués).
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        }
        .navigationTitle(pageTitle)
        .toolbar { toolbar(selected) }
        // Barre des menus : commandes sur la sélection de cette fenêtre (pas sur les pages Kindle et Notes,
        // qui ont leur propre sélection), recopiées dans MenuState à chaque changement.
        .onChange(of: MenuState.Values(commands), initial: true) { MenuState.shared.update(commands) }
        .environment(\.libraryList, sidebar)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Radius.dropZone)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))  // grid: ok épaisseur de trait, pas un espacement
                    .padding(Space.sm)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Titre de la fenêtre : la page affichée, comme dans la barre latérale.
    private var pageTitle: String {
        switch sidebar {
        case .all, nil: String(localized: "Tous les livres")
        case .recent: String(localized: "Ajoutés récemment")
        case .sent: String(localized: "Envoyés à la liseuse")
        case .toReview: String(localized: "À vérifier")
        case .notes: String(localized: "Notes et surlignages")
        case .thematic(let id): AppServices.shared.researches.research(id: id)?.name ?? String(localized: "Thématique")
        case .trash: String(localized: "Corbeille")
        case .kindle: kindle.displayName ?? String(localized: "Liseuse")
        case .pending: String(localized: "En attente d'envoi")
        case .shelf(let id): kindle.readers.first { $0.id == id }?.name ?? String(localized: "Étagère")
        case .format(let f): f.label
        case .author(let key): AuthorNames.groups(library.visibleBooks).first { $0.key == key }?.name ?? String(localized: "Auteur")
        case .series(let key): SeriesNames.groups(library.visibleBooks).first { $0.key == key }?.name ?? String(localized: "Série")
        case .genre(let key):
            GenreNames.groups(library.visibleBooks, identities: library.identities).first { $0.key == key }?.name ?? String(localized: "Genre")
        case .folder(let path): LibraryFolders.name(of: path)
        case .catalog(let id): opds.catalog(id: id)?.name ?? String(localized: "Catalogue")
        }
    }

    /// Invite du champ de recherche : la page de catalogue cherche dans le catalogue (S-087).
    private var searchPrompt: String {
        if let id = sidebar?.catalogID {
            guard opds.canSearch(id) else { return String(localized: "Ce catalogue n'a pas de recherche") }
            if let name = opds.catalog(id: id)?.name { return String(localized: "Rechercher dans \(name)") }
            return String(localized: "Rechercher dans le catalogue")
        }
        return searchScope == .content ? String(localized: "Mot ou expression dans les livres") : String(localized: "Titre, auteur, série, genre…")
    }

    /// Grille ou liste des livres, avec Coup d'œil (Espace) et la touche Supprimer.
    private func libraryPage(groups: [BookGroup], selected: [Book], resolve: @escaping (String) -> Book?) -> some View {
        LibraryView(groups: groups, selection: $selection, gridMode: gridMode, resolve: resolve)
            // Espace : Coup d'œil sur le livre sélectionné ; les flèches passent aux voisins.
            // Seulement quand la grille ou la liste a le focus : jamais dans le champ de recherche.
            .onKeyPress(.space) {
                guard let url = selected.first?.url else { return .ignored }
                quickLookURL = quickLookURL == nil ? url : nil
                return .handled
            }
            .quickLookPreview($quickLookURL, in: groups.map(\.primary.url))
            // Touche Supprimer dans la grille ou la liste : même action que Livre > Mettre à la corbeille.
            .onDeleteCommand {
                BookCommands(books: selected, list: sidebar, library: library, kindle: kindle,
                             afterTrash: { selection = Self.nextSelection(after: selection, in: groups) }).trash()
            }
    }

    /// Rend la page et la sélection du lancement précédent. Une page vidée depuis (série sans livre)
    /// revient à « Tous les livres » ; un livre disparu est simplement ignoré.
    private func restorePage() {
        guard Snapshot.directory == nil, let page = SidebarItem(storageKey: savedPage) else { return }
        let books = library.visibleBooks
        let exists: Bool = switch page {
        case .format(let f): books.contains { $0.format == f }
        case .author(let key): AuthorNames.groups(books).contains { $0.key == key }
        case .series(let key): SeriesNames.groups(books).contains { $0.key == key }
        case .genre(let key): GenreNames.groups(books, identities: library.identities).contains { $0.key == key }
        case .shelf(let id): kindle.readers.contains { $0.id == id }
        case .folder(let path): library.folders.count > 1 && library.folders.contains { $0.path == path }
        default: true
        }
        sidebar = exists ? page : .all
        let ids = savedSelection.split(separator: "\n").map(String.init)
        if exists, !ids.isEmpty { selection = Set(ids) }
    }

    /// Livre à sélectionner quand la sélection quitte la page : celui qui la suivait, sinon celui d'avant.
    static func nextSelection(after removed: Set<String>, in groups: [BookGroup]) -> Set<String> {
        let ids = groups.map(\.id)
        guard let last = ids.lastIndex(where: removed.contains) else { return [] }
        if let next = ids[(last + 1)...].first(where: { !removed.contains($0) }) { return [next] }
        return ids[..<last].last(where: { !removed.contains($0) }).map { [$0] } ?? []
    }

    @ToolbarContentBuilder
    private func toolbar(_ selected: [Book]) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if library.isScanning {
                ProgressView(value: Double(library.progress?.done ?? 0),
                             total: Double(max(1, library.progress?.total ?? 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help(library.progress.map { String(localized: "Indexation : \($0.done)/\($0.total)") } ?? String(localized: "Indexation…"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Panels.importBooks(into: library)
            } label: {
                Label("Importer", systemImage: "plus")
            }
            .help("Importer des livres (copiés dans la bibliothèque de l'app)")

            Picker("Affichage", selection: $gridMode) {
                Label("Grille", systemImage: "square.grid.2x2").tag(true)
                Label("Liste", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(sidebar?.catalogID != nil)

            Menu {
                Picker("Trier par", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Trier", systemImage: "arrow.up.arrow.down")
            }
            .disabled(sidebar == .recent || isSeriesSelected || sidebar?.catalogID != nil)
            .help(sidebar == .recent ? String(localized: "Les ajouts récents sont toujours classés du plus récent au plus ancien")
                  : isSeriesSelected ? String(localized: "Les livres d'une série sont classés par numéro") : String(localized: "Trier"))

            if let id = sidebar?.catalogID {
                Button {
                    Task { await opds.reload(id) }
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .help("Recharger cette page du catalogue")
            }
            if sidebar == .toReview {
                Button {
                    showReview = true
                } label: {
                    Label("Revue en lot…", systemImage: "checklist")
                }
                .help("Revoir toutes les propositions du catalogue dans un tableau, et les appliquer ou les ignorer d'un coup")
            }
            if sidebar == .trash {
                Button {
                    if Panels.confirmEmptyTrash(fileCount: library.trashedBooks.count) {
                        Task { await library.emptyTrash() }
                    }
                } label: {
                    Label("Vider la corbeille…", systemImage: "trash.slash")
                }
                .disabled(library.trashedBooks.isEmpty)
                .help("Placer tous les fichiers de la corbeille d'Alexandrie dans la Corbeille de macOS")
            }
            KindleSendButton(books: selected) {
                Label(KindleSendLabel.title(kindle), systemImage: KindleSendLabel.icon(kindle))
            }
            .disabled(!selected.contains(where: kindle.canSend) || kindle.isBusy || sidebar == .trash)
            .help(kindle.isConnected ? String(localized: "Copier les livres sélectionnés sur la liseuse (⌘K)")
                  : String(localized: "Mettre les livres sélectionnés en attente : ils partiront dès que la liseuse sera branchée (⌘K)"))
        }
    }

    private var isSeriesSelected: Bool {
        if case .series = sidebar { return true }
        return false
    }

    private static func unique(_ books: [Book]) -> [Book] {
        var seen = Set<Book.ID>()
        return books.filter { seen.insert($0.id).inserted }
    }

    private var filteredBooks: [Book] {
        var list = sidebar == .trash ? library.trashedBooks : library.visibleBooks
        switch sidebar {
        case .recent:
            let limit = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            list = list.filter { $0.addedAt >= limit }
        case .sent: list = list.filter { $0.lastSentAt != nil }
        case .pending: list = list.filter(\.isPendingSend)
        case .shelf(let reader): list = list.filter { $0.shelfIDs.contains(reader) }
        case .genre(let key): list = list.filter { $0.genre.map(GenreNames.key) == key }
        case .toReview: list = list.filter { !$0.catalogSuggestions.isEmpty }
        case .series(let key):
            // Classement par numéro de tome, les livres sans numéro à la fin.
            return list.filter { $0.series.map(SeriesNames.key) == key }
                .sorted { ($0.seriesIndex ?? .infinity, $0.title) < ($1.seriesIndex ?? .infinity, $1.title) }
        case .format(let f): list = list.filter { $0.format == f }
        case .author(let key): list = list.filter { AuthorNames.keys(of: $0).contains(key) }
        case .folder(let path):
            let prefix = LibraryFolders.prefix(path)
            list = list.filter { !$0.isImported && $0.path.hasPrefix(prefix) }
        default: break
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty && searchScope == .titles {
            // Aussi les livres dont une note ou un surlignage Kindle contient le texte cherché.
            let withNotes = kindle.titleKeys(withClippingsMatching: query)
            list = list.filter { b in
                [b.title, b.authorLine, b.series ?? "", b.genre ?? "", b.tags.joined(separator: " ")]
                    .contains { $0.localizedStandardContains(query) }
                    || withNotes.contains(ShelfSync.normalize(b.title))
            }
        }
        // « Ajoutés récemment » : toujours les derniers ajouts en tête, quel que soit le tri choisi.
        if sidebar == .recent {
            return list.sorted { $0.addedAt > $1.addedAt }
        }
        switch sort {
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: list.sort { $0.authorLine.localizedStandardCompare($1.authorLine) == .orderedAscending }
        case .added: list.sort { $0.addedAt > $1.addedAt }
        }
        return list
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = await Self.loadURL(p) { urls.append(url) }
            }
            library.importFiles(urls)
        }
        return true
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
