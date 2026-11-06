import AlexandrieCore
import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Binding var selection: SidebarItem?
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
                row("Tous les livres", "books.vertical", .all, count: books.count)
                row("Ajoutés récemment", "clock", .recent)
                row("Envoyés à la Kindle", "checkmark.circle", .sent,
                    count: books.filter { $0.lastSentAt != nil }.count)
                row("À vérifier", "exclamationmark.bubble", .toReview, count: library.pendingSuggestionCount)
                let notes = kindle.clippings.filter { $0.kind != .bookmark }.count
                if notes > 0 || selection == .notes {
                    row("Notes et surlignages", "highlighter", .notes, count: notes)
                        .help("Notes et surlignages importés des Kindle")
                }
                row("Corbeille", library.trashedBooks.isEmpty ? "trash" : "trash.fill", .trash,
                    count: library.trashedBooks.count)
                    .help("Livres supprimés, restaurables tant que la corbeille n'est pas vidée")
            }

            Section("Kindle") {
                Label {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kindle.displayName ?? (kindle.ejectedName != nil ? "Éjectée" : "Non connectée"))
                            if let device = kindle.device {
                                Text(device.connection.rawValue)
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
                            .help("Éjecter la Kindle")
                        }
                    }
                } icon: {
                    Image(systemName: kindle.isConnected ? "ipad.landscape.badge.play" : "ipad.landscape")
                        .foregroundStyle(kindle.isConnected ? Palette.success : Color.secondary)
                }
                .tag(SidebarItem.kindle)
                .contextMenu {
                    Button("Actualiser") { Task { await kindle.refresh() } }
                    Button("Éjecter la Kindle") { Task { await kindle.eject() } }
                        .disabled(!kindle.canEject || kindle.isBusy)
                }
                let pending = library.pendingSends.count
                if pending > 0 || selection == .pending {
                    row("En attente d'envoi", "clock.arrow.circlepath", .pending, count: pending)
                        .help("Livres envoyés automatiquement dès que la Kindle sera branchée")
                }
            }

            if !kindle.readers.isEmpty {
                Section("Liseuses") {
                    ForEach(kindle.readers) { reader in
                        let connected = kindle.deviceID == reader.id
                        Label(reader.name, systemImage: connected ? "books.vertical.circle.fill" : "books.vertical.circle")
                            .badge(library.shelfCount(reader.id))
                            .tag(SidebarItem.shelf(reader.id))
                            .help(connected ? "Étagère de \(reader.name) — branchée" : "Étagère de \(reader.name)")
                            // Livres glissés depuis la grille : ajoutés à cette étagère.
                            .dropDestination(for: String.self) { items, _ in
                                let books = items.compactMap(BookDrag.ids).flatMap { $0 }.compactMap(library.book(id:))
                                guard !books.isEmpty else { return false }
                                library.undoable("Ajouter à l'étagère") { library.addToShelf(books, reader: reader.id) }
                                return true
                            }
                    }
                }
            }

            // Dossiers de livres : une page par dossier dès qu'il y en a deux (S-061, S-062).
            if library.folders.count > 1 {
                Section {
                    CollapsibleHeader(title: "Dossiers", count: library.folders.count, isExpanded: $foldersExpanded)
                    if foldersExpanded {
                        ForEach(library.folders, id: \.path) { folder in
                            let unavailable = library.unavailableFolders.contains(folder.path)
                            row(LibraryFolders.name(of: folder.path), unavailable ? "externaldrive.badge.xmark" : "folder",
                                .folder(folder.path), count: library.books(inFolder: folder.path).count)
                                .foregroundStyle(unavailable ? .secondary : .primary)
                                .help(unavailable ? "Indisponible : disque débranché ou dossier introuvable. Ses livres restent dans la bibliothèque et reviendront au rebranchement."
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
                CollapsibleHeader(title: "Formats", count: formats.count, isExpanded: $formatsExpanded)
                if formatsExpanded {
                    ForEach(formats, id: \.0) { f, n in row(f.label, "doc", .format(f), count: n) }
                }
            }

            let series = SeriesNames.groups(library.visibleBooks)
            Section {
                CollapsibleHeader(title: "Séries", count: series.count, isExpanded: $seriesExpanded)
                if seriesExpanded {
                    ForEach(series) { s in
                        row(s.name, "books.vertical", .series(s.key), count: s.bookCount)
                            .help(s.variants.count > 1 ? "Noms regroupés : " + s.variants.joined(separator: " · ") : s.name)
                    }
                }
            }

            let genres = GenreNames.groups(library.visibleBooks, identities: library.identities)
            if !genres.isEmpty {
                Section {
                    CollapsibleHeader(title: "Genres", count: genres.count, isExpanded: $genresExpanded)
                    if genresExpanded {
                        ForEach(genres) { g in row(g.name, "theatermasks", .genre(g.key), count: g.bookCount) }
                    }
                }
            }

            let authors = AuthorNames.groups(library.visibleBooks)
            Section {
                CollapsibleHeader(title: "Auteurs", count: authors.count, isExpanded: $authorsExpanded)
                if authorsExpanded {
                    ForEach(authors) { a in
                        row(a.name, "person", .author(a.key), count: a.bookCount)
                            .help(a.variants.count > 1 ? "Graphies regroupées : " + a.variants.joined(separator: " · ") : a.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
        .help(isExpanded ? "Replier \(title.lowercased())" : "Déplier \(title.lowercased())")
        .accessibilityLabel("\(title), \(isExpanded ? "déplié" : "replié")")
    }
}
