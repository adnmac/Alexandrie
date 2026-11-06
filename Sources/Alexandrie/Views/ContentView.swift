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

    var body: some View {
        Group {
            if library.hasLibrary {
                main
            } else {
                OnboardingView()
            }
        }
        // La Kindle vient d'être branchée : la file d'attente part.
        .onChange(of: kindle.isConnected) { _, connected in
            if connected { Task { await kindle.sendPending(library: library) } }
        }
        .sheet(isPresented: $showReview) { CatalogReviewSheet() }
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
        .onChange(of: sidebar) { _, page in savedPage = page?.storageKey ?? "" }
        .onChange(of: selection) { _, ids in savedSelection = ids.sorted().joined(separator: "\n") }
        .onAppear { ReaderWindows.open = { [openWindow] id in openWindow(id: "lecture", value: id) } }
        .task {
            guard Snapshot.directory != nil else { return }
            await Snapshot.run(library: library, kindle: kindle, sidebar: $sidebar, selection: $selection, notesBook: $notesBook,
                               openSettings: openSettings)
        }
        .onChange(of: undoManager) { _, manager in library.undoManager = manager }
        // Kindle inconnue : on lui donne un nom, une fois pour toutes.
        .sheet(isPresented: Binding(get: { kindle.needsNaming }, set: { if !$0 { kindle.postponeNaming() } })) {
            NameReaderSheet()
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK") { library.lastError = nil; kindle.lastError = nil }
        } message: {
            Text(library.lastError ?? kindle.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { library.lastError != nil || kindle.lastError != nil },
                set: { if !$0 { library.lastError = nil; kindle.lastError = nil } })
    }

    private var main: some View {
        let groups = BookGroups.make(filteredBooks, identities: library.identities)
        let index = Dictionary(groups.filter(\.isGroup).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Un groupe sélectionné vaut pour son fichier principal (fiche, envoi à la Kindle).
        let resolve: (String) -> Book? = { id in
            BookGroups.isGroupID(id) ? index[id]?.primary : library.book(id: id)
        }
        let selected = Self.unique(selection.sorted().compactMap(resolve))
        let commands = BookCommands(
            books: sidebar == .kindle || sidebar == .notes ? [] : selected,
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
                } else {
                    libraryPage(groups: groups, selected: selected, resolve: resolve)
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 640)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let release = updates.releaseBanner {
                    ReleaseBanner(release: release)
                } else if let info = updates.banner {
                    UpdateBanner(info: info)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Titre, auteur, série, genre…")
        } detail: {
            Group {
                if sidebar == .notes {
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
                                               description: Text("Choisissez un livre de la Kindle pour voir sa fiche."))
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
        case .all, nil: "Tous les livres"
        case .recent: "Ajoutés récemment"
        case .sent: "Envoyés à la Kindle"
        case .toReview: "À vérifier"
        case .notes: "Notes et surlignages"
        case .trash: "Corbeille"
        case .kindle: kindle.displayName ?? "Kindle"
        case .pending: "En attente d'envoi"
        case .shelf(let id): kindle.readers.first { $0.id == id }?.name ?? "Étagère"
        case .format(let f): f.label
        case .author(let key): AuthorNames.groups(library.visibleBooks).first { $0.key == key }?.name ?? "Auteur"
        case .series(let key): SeriesNames.groups(library.visibleBooks).first { $0.key == key }?.name ?? "Série"
        case .genre(let key):
            GenreNames.groups(library.visibleBooks, identities: library.identities).first { $0.key == key }?.name ?? "Genre"
        case .folder(let path): LibraryFolders.name(of: path)
        }
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
                    .help(library.progress.map { "Indexation : \($0.done)/\($0.total)" } ?? "Indexation…")
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

            Menu {
                Picker("Trier par", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Trier", systemImage: "arrow.up.arrow.down")
            }
            .disabled(sidebar == .recent || isSeriesSelected)
            .help(sidebar == .recent ? "Les ajouts récents sont toujours classés du plus récent au plus ancien"
                  : isSeriesSelected ? "Les livres d'une série sont classés par numéro" : "Trier")

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
            .disabled(!selected.contains(where: \.canSendToKindle) || kindle.isBusy || sidebar == .trash)
            .help(kindle.isConnected ? "Copier les livres sélectionnés sur la Kindle (⌘K)"
                  : "Mettre les livres sélectionnés en attente : ils partiront dès que la Kindle sera branchée (⌘K)")
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
        if !query.isEmpty {
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
