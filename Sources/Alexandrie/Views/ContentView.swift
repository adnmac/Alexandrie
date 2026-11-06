import AlexandrieCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all, recent, sent, toReview, kindle
    /// Livres en attente d'envoi (Kindle débranchée).
    case pending
    /// Corbeille d'Alexandrie.
    case trash
    /// Étagère d'une liseuse (identifiant de la Kindle).
    case shelf(String)
    /// Notes et surlignages importés des Kindle.
    case notes
    case format(BookFormat)
    /// Clé de regroupement (voir `AuthorNames`), pas une graphie particulière.
    case author(String)
    /// Clé de regroupement de série (voir `SeriesNames`).
    case series(String)
    /// Clé de regroupement de genre (voir `GenreNames`).
    case genre(String)
}

extension EnvironmentValues {
    /// Liste affichée (barre latérale) : le menu d'un livre propose de le retirer de cette liste.
    @Entry var libraryList: SidebarItem?
}

enum SortOrder: String, CaseIterable, Identifiable {
    case title = "Titre", author = "Auteur", added = "Date d'ajout"
    var id: Self { self }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(UpdateMonitor.self) private var updates
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @State private var sidebar: SidebarItem? = .all
    /// Identifiants de lignes : livre seul, groupe (`group:…`) ou fichier d'un groupe.
    @State private var selection = Set<String>()
    @State private var kindleSelection: KindleDocument.ID?
    @State private var search = ""
    @State private var sort: SortOrder = .title
    @AppStorage("gridMode") private var gridMode = true
    @State private var isDropTargeted = false
    @State private var showReview = false
    /// Livre annoté choisi dans la vue Notes (titre normalisé).
    @State private var notesBook: String?

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
        .onAppear { library.undoManager = undoManager }
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
                    LibraryView(groups: groups, selection: $selection, gridMode: gridMode, resolve: resolve)
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
        // qui ont leur propre sélection).
        .focusedSceneValue(\.bookCommands, BookCommands(
            books: sidebar == .kindle || sidebar == .notes ? [] : selected,
            list: sidebar, library: library, kindle: kindle))
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
        }
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

/// Première connexion d'une Kindle : son nom de liseuse.
struct NameReaderSheet: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var adoptExisting = true

    /// Livres de la bibliothèque déjà présents sur cette Kindle.
    private var booksOnDevice: [Book] {
        kindle.documents.compactMap { kindle.libraryBook(for: $0, in: library) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Label("Nouvelle liseuse", systemImage: "ipad.landscape.badge.play").font(.title3.weight(.semibold))
            Text("Cette Kindle est branchée pour la première fois. Donnez-lui un nom : Alexandrie la reconnaîtra ensuite automatiquement et lui tiendra une étagère de livres.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Nom", text: $name, prompt: Text("ex. Kindle de Léa"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            let onDevice = booksOnDevice.count
            if onDevice > 0 {
                Toggle("Ajouter à son étagère les \(onDevice) livres de la bibliothèque déjà présents sur cette Kindle",
                       isOn: $adoptExisting)
            }
            HStack {
                Spacer()
                Button("Plus tard") {
                    kindle.postponeNaming()
                    dismiss()
                }
                Button("Enregistrer", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.margin)
        .frame(width: Layout.sheet)
        .noInitialFocus()
        .onAppear { name = kindle.device?.name ?? "Kindle" }
    }

    private func save() {
        let existing = adoptExisting ? booksOnDevice : []
        kindle.nameCurrentReader(name)
        if let reader = kindle.currentReader, !existing.isEmpty {
            library.addToShelf(existing, reader: reader.id)
        }
        dismiss()
    }
}

/// Bouton d'envoi : envoi immédiat si la Kindle est branchée ; sinon mise en attente, avec le choix
/// de la liseuse quand plusieurs sont connues.
struct KindleSendButton<Content: View>: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let books: [Book]
    @ViewBuilder let label: () -> Content

    var body: some View {
        if kindle.isConnected || kindle.readers.count < 2 {
            Button {
                if kindle.isConnected {
                    Task { await kindle.send(books, library: library) }
                } else {
                    // Mise en attente annulable (⌘Z), comme la commande Kindle > Envoyer.
                    let reader = kindle.readers.first.map(\.id)
                    library.undoable("Envoyer à la connexion") { library.queueForKindle(books, reader: reader) }
                }
            } label: { label() }
        } else {
            Menu {
                Section("Envoyer à la connexion de") {
                    ForEach(kindle.readers) { reader in
                        Button(reader.name) { library.queueForKindle(books, reader: reader.id) }
                    }
                }
            } label: { label() }
        }
    }
}

/// Libellé des boutons d'envoi : envoi immédiat, ou mise en attente si la Kindle est débranchée.
enum KindleSendLabel {
    @MainActor static func title(_ kindle: KindleMonitor) -> String {
        if kindle.isConnected { return kindle.currentReader.map { "Envoyer sur « \($0.name) »" } ?? "Envoyer à la Kindle" }
        if kindle.readers.count == 1 { return "Envoyer à la connexion de « \(kindle.readers[0].name) »" }
        return "Envoyer à la connexion"
    }
    @MainActor static func icon(_ kindle: KindleMonitor) -> String {
        kindle.isConnected ? "arrow.down.to.line.compact" : "clock.arrow.circlepath"
    }
}

/// Version publiée plus récente : installation depuis l'app.
struct ReleaseBanner: View {
    @Environment(UpdateMonitor.self) private var updates
    @Environment(\.openURL) private var openURL
    let release: ReleaseInfo

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Palette.info)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Alexandrie \(release.version) est disponible (vous avez la \(updates.currentVersion))")
                    .font(.callout.weight(.semibold))
                if case .failed(let why) = updates.installState {
                    Text(why).foregroundStyle(Palette.warning).lineLimit(3)
                } else if !release.notes.isEmpty {
                    Text(release.notes.components(separatedBy: .newlines).prefix(2).joined(separator: " "))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .font(.caption)
            Spacer(minLength: 8)
            switch updates.installState {
            case .downloading, .installing:
                ProgressView().controlSize(.small)
                Text(updates.installState == .downloading ? "Téléchargement…" : "Installation…").font(.caption)
            case .idle, .failed:
                if let page = release.pageURL { Button("Détails") { openURL(page) } }
                Button("Installer et relancer") { Task { await updates.install(release) } }
                    .buttonStyle(.borderedProminent)
                Button("Plus tard") { updates.dismissRelease() }
            }
        }
        .banner(Palette.info)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Bandeau signalant une version plus récente publiée sur GitHub.
struct UpdateBanner: View {
    @Environment(UpdateMonitor.self) private var updates
    @Environment(\.openURL) private var openURL
    let info: UpdateInfo

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Palette.info)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Une mise à jour d'Alexandrie est disponible sur GitHub").font(.callout.weight(.semibold))
                Text(info.newCommits == 1 ? "1 modification" : "\(info.newCommits) modifications")
                    + Text(info.latestMessage.isEmpty ? "" : " · dernière : \(info.latestMessage)")
                Text("Pour l'installer : git pull, puis scripts/bundle.sh.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(2)
            Spacer(minLength: 8)
            if let url = info.url {
                Button("Voir les modifications") { openURL(url) }
            }
            Button("Plus tard") { updates.dismiss() }
        }
        .banner(Palette.info)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Bienvenue dans Alexandrie")
                .font(.largeTitle.weight(.semibold))
            Text("Choisissez le dossier où se trouvent vos livres (EPUB, MOBI, AZW3, PDF).\nIl sera indexé en lecture seule : aucun fichier n'y sera modifié.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choisir le dossier…") { Panels.chooseLibraryFolder(library) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
