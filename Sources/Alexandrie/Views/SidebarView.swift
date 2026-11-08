import AlexandrieCore
import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(ResearchStore.self) private var researches
    @Environment(OPDSStore.self) private var opds
    @Binding var selection: SidebarItem?
    @AppStorage("sidebarThematicsExpanded") private var thematicsExpanded = true
    @State private var managesThematics = false
    @State private var managesCatalogs = false
    @AppStorage("sidebarCatalogsExpanded") private var catalogsExpanded = true
    /// États replié/déplié mémorisés : la liste des auteurs peut compter des centaines d'entrées.
    @AppStorage("sidebarAuthorsExpanded") private var authorsExpanded = false
    @AppStorage("sidebarFormatsExpanded") private var formatsExpanded = true
    @AppStorage("sidebarFoldersExpanded") private var foldersExpanded = true
    @AppStorage("sidebarSeriesExpanded") private var seriesExpanded = false
    @AppStorage("sidebarGenresExpanded") private var genresExpanded = false

    var body: some View {
        List(selection: $selection) {
            Section("Bibliothèque") {
                let books = library.visibleBooks
                row(String(localized: "Tous les livres"), "books.vertical", .all, count: count(books))
                row(String(localized: "Ajoutés récemment"), "clock", .recent)
                row(String(localized: "Envoyés à la liseuse"), "checkmark.circle", .sent,
                    count: count(books.filter { $0.lastSentAt != nil }))
                row(String(localized: "À vérifier"), "exclamationmark.bubble", .toReview, count: library.pendingSuggestionCount)
                let notes = kindle.clippings.filter { $0.kind != .bookmark }.count
                if notes > 0 || selection == .notes {
                    row(String(localized: "Notes et surlignages"), "highlighter", .notes, count: notes)
                        .help("Notes et surlignages importés des liseuses")
                }
                row(String(localized: "Corbeille"), library.trashedBooks.isEmpty ? "trash" : "trash.fill", .trash,
                    count: count(library.trashedBooks))
                    .help("Livres supprimés, restaurables tant que la corbeille n'est pas vidée")
            }

            // Thématiques (S-080) : chacune ouvre toutes ses notes, de tous les livres.
            if !researches.researches.isEmpty {
                Section {
                    CollapsibleHeader(title: String(localized: "Thématiques"), count: researches.researches.count, isExpanded: $thematicsExpanded)
                    if thematicsExpanded {
                        ForEach(researches.researches) { thematic in
                            row(thematic.name.isEmpty ? String(localized: "Sans titre") : thematic.name, "tag", .thematic(thematic.id),
                                count: researches.highlightCount(research: thematic.id))
                                .help("Toutes les notes et surlignages de « \(thematic.name) », de tous les livres")
                                .contextMenu { Button("Gérer les thématiques…") { managesThematics = true } }
                        }
                    }
                }
                .sheet(isPresented: $managesThematics) { ResearchesSheet() }
            }

            Section("Liseuse") {
                Label {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kindle.displayName ?? (kindle.ejectedName != nil ? String(localized: "Éjectée") : String(localized: "Non connectée")))
                            if let device = kindle.device {
                                Text(device.brand.label + " · " + device.connection.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        // Comme dans le Finder : ⏏ à droite du disque.
                        if kindle.canEject {
                            Button {
                                Task { await kindle.eject() }
                            } label: {
                                Image(systemName: "eject.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(kindle.isBusy)
                            .help("Éjecter la liseuse")
                        }
                    }
                } icon: {
                    Image(systemName: kindle.isConnected ? "ipad.landscape.badge.play" : "ipad.landscape")
                        .foregroundStyle(kindle.isConnected ? Palette.success : Color.secondary)
                }
                .tag(SidebarItem.kindle)
                .contextMenu {
                    Button("Actualiser") { Task { await kindle.refresh() } }
                    Button("Éjecter la liseuse") { Task { await kindle.eject() } }
                        .disabled(!kindle.canEject || kindle.isBusy)
                }
                let pending = count(library.pendingSends)
                if pending > 0 || selection == .pending {
                    row(String(localized: "En attente d'envoi"), "clock.arrow.circlepath", .pending, count: pending)
                        .help("Livres envoyés automatiquement dès que la liseuse sera branchée")
                }
            }

            if !kindle.readers.isEmpty {
                Section("Liseuses") {
                    ForEach(kindle.readers) { reader in
                        let connected = kindle.deviceID == reader.id
                        Label(reader.name, systemImage: connected ? "books.vertical.circle.fill" : "books.vertical.circle")
                            .badge(library.shelfCount(reader.id))
                            .tag(SidebarItem.shelf(reader.id))
                            .help(connected ? String(localized: "Étagère de \(reader.name) — branchée") : String(localized: "Étagère de \(reader.name)"))
                            // Livres glissés depuis la grille : ajoutés à cette étagère.
                            .dropDestination(for: String.self) { items, _ in
                                let books = items.compactMap(BookDrag.ids).flatMap { $0 }.compactMap(library.book(id:))
                                guard !books.isEmpty else { return false }
                                library.undoable(String(localized: "Ajouter à l'étagère")) { library.addToShelf(books, reader: reader.id) }
                                return true
                            }
                    }
                }
            }

            // Catalogues OPDS publics (S-086) : rien n'est demandé en ligne avant d'en ouvrir un.
            Section {
                CollapsibleHeader(title: String(localized: "Catalogues en ligne"), count: opds.catalogs.count, isExpanded: $catalogsExpanded)
                if catalogsExpanded {
                    ForEach(opds.catalogs) { catalog in
                        row(catalog.name, "globe", .catalog(catalog.id))
                            .help("Livres gratuits de « \(catalog.name) » — \(catalog.url.host ?? "")")
                            .contextMenu { Button("Gérer les catalogues…") { managesCatalogs = true } }
                    }
                    Button("Ajouter un catalogue…") { managesCatalogs = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Ajouter l'adresse d'un catalogue OPDS public")
                }
            }
            .sheet(isPresented: $managesCatalogs) { OPDSCatalogsSheet() }

            // Dossiers de livres : une page par dossier dès qu'il y en a deux (S-061, S-062).
            if library.folders.count > 1 {
                Section {
                    CollapsibleHeader(title: String(localized: "Dossiers"), count: library.folders.count, isExpanded: $foldersExpanded)
                    if foldersExpanded {
                        ForEach(library.folders, id: \.path) { folder in
                            let unavailable = library.unavailableFolders.contains(folder.path)
                            row(LibraryFolders.name(of: folder.path), unavailable ? "externaldrive.badge.xmark" : "folder",
                                .folder(folder.path), count: count(library.books(inFolder: folder.path)))
                                .foregroundStyle(unavailable ? .secondary : .primary)
                                .help(unavailable ? String(localized: "Indisponible : disque débranché ou dossier introuvable. Ses livres restent dans la bibliothèque et reviendront au rebranchement.")
                                      : folder.path)
                        }
                    }
                }
            }

            let formats = BookFormat.allCases.map { f in (f, library.visibleBooks.filter { $0.format == f }.count) }
                .filter { $0.1 > 0 }
            // Titres en lignes ordinaires plutôt qu'en en-têtes de section : macOS ajoute aux en-têtes
            // son propre chevron (visible au survol seulement), qui masquerait celui-ci.
            Section {
                CollapsibleHeader(title: String(localized: "Formats"), count: formats.count, isExpanded: $formatsExpanded)
                if formatsExpanded {
                    ForEach(formats, id: \.0) { f, n in row(f.label, "doc", .format(f), count: n) }
                }
            }

            let series = SeriesNames.groups(library.visibleBooks)
            Section {
                CollapsibleHeader(title: String(localized: "Séries"), count: series.count, isExpanded: $seriesExpanded)
                if seriesExpanded {
                    ForEach(series) { s in
                        row(s.name, "books.vertical", .series(s.key), count: s.bookCount)
                            .help(s.variants.count > 1 ? String(localized: "Noms regroupés : ") + s.variants.joined(separator: " · ") : s.name)
                    }
                }
            }

            let genres = GenreNames.groups(library.visibleBooks, identities: library.identities)
            if !genres.isEmpty {
                Section {
                    CollapsibleHeader(title: String(localized: "Genres"), count: genres.count, isExpanded: $genresExpanded)
                    if genresExpanded {
                        ForEach(genres) { g in row(g.name, "theatermasks", .genre(g.key), count: g.bookCount) }
                    }
                }
            }

            let authors = AuthorNames.groups(library.visibleBooks)
            Section {
                CollapsibleHeader(title: String(localized: "Auteurs"), count: authors.count, isExpanded: $authorsExpanded)
                if authorsExpanded {
                    let perAuthor = authorCounts(library.visibleBooks)
                    ForEach(authors) { a in
                        row(a.name, "person", .author(a.key), count: perAuthor[a.key] ?? a.bookCount)
                            .help(a.variants.count > 1 ? String(localized: "Graphies regroupées : ") + a.variants.joined(separator: " · ") : a.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Nombre de livres, pas de fichiers : les fichiers d'un même livre (EPUB, MOBI, PDF…) comptent pour un,
    /// comme dans la grille.
    private func count(_ list: [Book]) -> Int { library.bookCount(list) }

    /// Livres de chaque auteur (clé de regroupement), chaque livre compté une fois quel que soit son nombre de fichiers.
    private func authorCounts(_ books: [Book]) -> [String: Int] {
        let identities = library.identities
        var seen: [String: Set<String>] = [:]
        for b in books {
            let identity = identities[b.id] ?? BookGroups.key(b)
            for key in AuthorNames.keys(of: b) { seen[key, default: []].insert(identity) }
        }
        return seen.mapValues(\.count)
    }

    private func row(_ title: String, _ icon: String, _ tag: SidebarItem, count: Int? = nil) -> some View {
        Label(title, systemImage: icon)
            .badge(count ?? 0)
            .tag(tag)
    }
}

/// En-tête de section repliable, au style des en-têtes système (« Bibliothèque », « Kindle »),
/// avec un chevron toujours visible.
struct CollapsibleHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            Motion.run(Motion.quick) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Space.xs) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? String(localized: "Replier \(title.lowercased())") : String(localized: "Déplier \(title.lowercased())"))
        .accessibilityLabel("\(title), \(isExpanded ? "déplié" : "replié")")
    }
}
