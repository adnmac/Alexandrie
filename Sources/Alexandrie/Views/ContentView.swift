import AlexandrieCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all, recent, sent, toReview, kindle
    /// Livres en attente d'envoi (Kindle débranchée).
    case pending
    case format(BookFormat)
    /// Clé de regroupement (voir `AuthorNames`), pas une graphie particulière.
    case author(String)
    /// Clé de regroupement de série (voir `SeriesNames`).
    case series(String)
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
    @State private var sidebar: SidebarItem? = .all
    /// Identifiants de lignes : livre seul, groupe (`group:…`) ou fichier d'un groupe.
    @State private var selection = Set<String>()
    @State private var kindleSelection: KindleDocument.ID?
    @State private var search = ""
    @State private var sort: SortOrder = .title
    @AppStorage("gridMode") private var gridMode = true
    @State private var isDropTargeted = false

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
        let groups = BookGroups.make(filteredBooks)
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
                } else {
                    LibraryView(groups: groups, selection: $selection, gridMode: gridMode, resolve: resolve)
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 640)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let info = updates.banner { UpdateBanner(info: info) }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Titre, auteur, série, genre…")
        } detail: {
            if sidebar == .kindle {
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
        .toolbar { toolbar(selected) }
        .environment(\.libraryList, sidebar)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
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

            Button {
                Task { await kindle.sendOrQueue(selected, library: library) }
            } label: {
                Label(KindleSendLabel.title(kindle), systemImage: KindleSendLabel.icon(kindle))
            }
            .disabled(!selected.contains(where: \.canSendToKindle) || kindle.isBusy)
            .help(kindle.isConnected ? "Envoyer la sélection sur la Kindle"
                  : "La Kindle n'est pas branchée : la sélection sera envoyée dès sa connexion")
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
        var list = library.books
        switch sidebar {
        case .recent:
            let limit = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            list = list.filter { $0.addedAt >= limit }
        case .sent: list = list.filter { $0.lastSentAt != nil }
        case .pending: list = list.filter { $0.pendingSendAt != nil }
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
            list = list.filter { b in
                [b.title, b.authorLine, b.series ?? "", b.genre ?? "", b.tags.joined(separator: " ")]
                    .contains { $0.localizedStandardContains(query) }
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

/// Libellé des boutons d'envoi : envoi immédiat, ou mise en attente si la Kindle est débranchée.
enum KindleSendLabel {
    @MainActor static func title(_ kindle: KindleMonitor) -> String {
        kindle.isConnected ? "Envoyer à la Kindle" : "Envoyer à la connexion"
    }
    @MainActor static func icon(_ kindle: KindleMonitor) -> String {
        kindle.isConnected ? "arrow.down.to.line.compact" : "clock.arrow.circlepath"
    }
}

/// Bandeau signalant une version plus récente publiée sur GitHub.
struct UpdateBanner: View {
    @Environment(UpdateMonitor.self) private var updates
    @Environment(\.openURL) private var openURL
    let info: UpdateInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
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
        .controlSize(.small)
        .padding(10)
        .background(.blue.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: 18) {
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
