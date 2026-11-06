import AlexandrieCore
import AppKit
import SwiftUI

/// Ligne de la liste : un livre seul, un livre en plusieurs fichiers (parent), ou l'un de ces fichiers (enfant).
struct LibraryRow: Identifiable, Hashable {
    let id: String
    let book: Book
    let group: BookGroup?
    var children: [LibraryRow]?

    /// Ligne d'un fichier à l'intérieur d'un groupe.
    var isFile = false

    static func rows(_ groups: [BookGroup]) -> [LibraryRow] {
        groups.map { g in
            guard g.isGroup else { return LibraryRow(id: g.id, book: g.books[0], group: nil) }
            let files = g.books.sorted { $0.format.rawValue < $1.format.rawValue }
                .map { LibraryRow(id: $0.id, book: $0, group: nil, isFile: true) }
            return LibraryRow(id: g.id, book: g.primary, group: g, children: files)
        }
    }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let groups: [BookGroup]
    @Binding var selection: Set<String>
    let gridMode: Bool
    let resolve: (String) -> Book?
    /// La grille prend le focus au clic : Espace (Coup d'œil) et Supprimer lui arrivent alors.
    @FocusState private var gridFocused: Bool

    var body: some View {
        if groups.isEmpty {
            if library.isScanning {
                ProgressView("Indexation de la bibliothèque…")
            } else {
                ContentUnavailableView("Aucun livre", systemImage: "magnifyingglass",
                                       description: Text("Aucun livre ne correspond à ce filtre."))
            }
        } else if gridMode {
            grid
        } else {
            table
        }
    }

    /// Livres emportés en glissant une carte : toute la sélection si la carte en fait partie.
    private func dragged(_ g: BookGroup) -> [Book] {
        guard selection.contains(g.id), selection.count > 1 else { return [g.primary] }
        return selection.compactMap(resolve)
    }

    // MARK: - Grille : une carte par livre, avec tous ses formats

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 20)], spacing: 24) {
                ForEach(groups) { g in
                    BookCard(book: g.primary, formats: g.formats, fileCount: g.books.count,
                             onDevice: g.books.contains(where: kindle.isOnDevice), isSelected: selection.contains(g.id))
                        .onTapGesture { select(g) }
                        .contextMenu { BookActions(book: g.primary) }
                        // Glisser vers une liseuse de la barre latérale : le livre (ou la sélection) rejoint son étagère.
                        .draggable(BookDrag.payload(dragged(g))) {
                            BookCard(book: g.primary, formats: g.formats, isSelected: false).frame(width: 128)
                        }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Focalisable sans anneau : la sélection des cartes montre déjà où l'on est.
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onTapGesture {
            selection.removeAll()
            gridFocused = true
        }
    }

    private func select(_ g: BookGroup) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(g.id) { selection.remove(g.id) } else { selection.insert(g.id) }
        } else if flags.contains(.shift), let anchor = selection.first,
                  let a = groups.firstIndex(where: { $0.id == anchor }),
                  let b = groups.firstIndex(where: { $0.id == g.id }) {
            selection = Set(groups[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [g.id]
        }
        gridFocused = true
    }

    // MARK: - Liste : chevron à gauche pour déplier les fichiers d'un même livre

    private var table: some View {
        Table(LibraryRow.rows(groups), children: \.children, selection: $selection) {
            TableColumn("Titre") { r in
                HStack(spacing: Space.sm) {
                    if r.isFile {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text((r.book.path as NSString).lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    } else {
                        Text(r.book.title).lineLimit(1)
                        if let g = r.group {
                            Text("\(g.books.count) fichiers")
                                .font(.caption2).padding(.horizontal, Space.sm).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if (r.group?.books ?? [r.book]).contains(where: kindle.isOnDevice) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).help("Sur la Kindle")
                    }
                    if (r.group?.books ?? [r.book]).contains(where: \.isPendingSend) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.info)
                            .help("En attente d'envoi : partira dès que la Kindle sera branchée")
                    }
                }
                .help(r.isFile ? r.book.path : r.book.title)
            }
            TableColumn("Auteur") { r in Text(r.isFile ? "" : r.book.authorLine).lineLimit(1) }
            TableColumn("Série") { r in
                if !r.isFile, let s = r.book.series {
                    Text(s + (r.book.seriesIndex.map { " · \(SeriesNames.format($0))" } ?? "")).lineLimit(1)
                }
            }
            .width(min: 60, ideal: 120)
            TableColumn("Genre") { r in
                if !r.isFile, let g = r.book.genre { Text(g).lineLimit(1) }
            }
            .width(min: 50, ideal: 90)
            TableColumn("Format") { r in
                Text(r.group.map { $0.formats.map(\.label).joined(separator: " · ") } ?? r.book.format.label)
                    .monospaced().lineLimit(1)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Taille") { r in
                let size = r.group?.books.reduce(0) { $0 + $1.fileSize } ?? r.book.fileSize
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            .width(70)
            TableColumn("Ajouté le") { r in
                Text(r.group?.books.map(\.addedAt).max() ?? r.book.addedAt, format: .dateTime.day().month().year())
            }
            .width(90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let b = resolve(id) { BookActions(book: b) }
        }
    }
}

struct BookCard: View {
    @Environment(LibraryStore.self) private var library
    let book: Book
    var formats: [BookFormat] = []
    var fileCount = 1
    var onDevice = false
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            CoverView(book: book) {
                RoundedRectangle(cornerRadius: Radius.cover)
                    .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 3)  // grid: ok épaisseur de trait, pas un espacement
                    .overlay(alignment: .topTrailing) { badges }
            }
            .frame(height: 200)
            formatRow
            Text(book.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(book.authorLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// Formats disponibles, entre la couverture et le titre.
    private var formatRow: some View {
        HStack(spacing: 4) {
            ForEach(formats.isEmpty ? [book.format] : formats, id: \.self) { f in
                Text(f.label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, Space.sm).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if fileCount > max(1, formats.count) {
                Text("\(fileCount) fichiers").font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var badges: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !book.catalogSuggestions.isEmpty {
                Image(systemName: "exclamationmark.bubble.fill").font(.caption)
                    .foregroundStyle(Palette.warning)
                    .padding(4).background(.ultraThinMaterial, in: Circle())
                    .help("Le catalogue propose des corrections")
            }
            if book.isPendingSend {
                Image(systemName: "clock.arrow.circlepath").font(.caption)
                    .foregroundStyle(Palette.info)
                    .padding(4).background(.ultraThinMaterial, in: Circle())
                    .help("En attente d'envoi : partira dès que la Kindle sera branchée")
            }
            if book.isDRMProtected {
                Image(systemName: "lock.fill").font(.caption)
                    .padding(4).background(.ultraThinMaterial, in: Circle())
                    .help("Protégé par DRM")
            }
            if onDevice {
                Image(systemName: "checkmark.circle.fill").font(.caption)
                    .foregroundStyle(Palette.success)
                    .padding(Space.xs).background(.ultraThinMaterial, in: Circle())
                    .help("Présent sur la Kindle")
            }
        }
        .padding(Space.sm)
    }
}

/// Couverture d'un livre de la bibliothèque.
struct CoverView<Decoration: View>: View {
    @Environment(LibraryStore.self) private var library
    let book: Book
    @ViewBuilder var decoration: Decoration

    var body: some View {
        CoverImage(url: library.coverURL(book), cacheKey: book.fingerprint, title: book.title,
                   subtitle: book.authorLine) { decoration }
    }
}

extension CoverView where Decoration == EmptyView {
    init(book: Book) { self.init(book: book) { EmptyView() } }
}

/// Couverture mise en cache, avec une couverture générée à défaut.
/// Couvertures déjà lues, partagées par toutes les vues (hors du type générique).
@MainActor private let coverCache = NSCache<NSString, NSImage>()

/// `decoration` (pastilles, contour de sélection) se pose sur la couverture elle-même,
/// pas sur le cadre plus large qui la centre.
struct CoverImage<Decoration: View>: View {
    let url: URL?
    let cacheKey: String
    let title: String
    let subtitle: String
    @ViewBuilder var decoration: Decoration
    @State private var image: NSImage?

    private static var cache: NSCache<NSString, NSImage> { coverCache }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.cover))
        .overlay { decoration }
        .shadow(color: Surface.coverShadow, radius: Surface.coverShadowRadius, y: Surface.coverShadowY)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(cacheKey)|\(url?.path ?? "")") { await load() }
    }

    private var placeholder: some View {
        let hue = Double(abs(title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 360) / 360
        return RoundedRectangle(cornerRadius: Radius.cover)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                          Color(hue: hue, saturation: 0.55, brightness: 0.35)],
                                 startPoint: .top, endPoint: .bottom))
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                VStack(spacing: Space.sm) {
                    Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(4)
                    Text(subtitle).font(.caption).lineLimit(2)
                }
                .foregroundStyle(.white)  // couverture générée : du contenu, pas de l'interface
                .padding(Space.md)
            }
    }

    private func load() async {
        let key = cacheKey as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        guard let url else {
            image = nil
            return
        }
        // Lecture hors du thread principal ; NSImage n'est pas Sendable, seules les données traversent.
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        if let data, let loaded = NSImage(data: data) {
            Self.cache.setObject(loaded, forKey: key)
            image = loaded
        }
    }
}

extension CoverImage where Decoration == EmptyView {
    init(url: URL?, cacheKey: String, title: String, subtitle: String) {
        self.init(url: url, cacheKey: cacheKey, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Livres glissés depuis la grille (identifiants des fichiers principaux), reconnus par leur préfixe.
enum BookDrag {
    static let prefix = "alexandrie-livres:"

    static func payload(_ books: [Book]) -> String { prefix + books.map(\.id).joined(separator: "\n") }

    static func ids(_ text: String) -> [Book.ID]? {
        guard text.hasPrefix(prefix) else { return nil }
        return text.dropFirst(prefix.count).split(separator: "\n").map(String.init)
    }
}

/// Ajout aux étagères des liseuses et retrait de l'étagère affichée (menu d'un livre, sélection multiple).
struct ShelfActions: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(\.libraryList) private var list
    let books: [Book]

    var body: some View {
        let current = books.compactMap { library.book(id: $0.id) }
        let available = kindle.readers.filter { r in !current.allSatisfy { $0.shelfIDs.contains(r.id) } }
        if available.count == 1, let reader = available.first {
            Button("Ajouter à l'étagère « \(reader.name) »") {
                library.undoable("Ajouter à l'étagère") { library.addToShelf(books, reader: reader.id) }
            }
        } else if available.count > 1 {
            Menu("Ajouter à l'étagère") {
                ForEach(available) { reader in
                    Button(reader.name) {
                        library.undoable("Ajouter à l'étagère") { library.addToShelf(books, reader: reader.id) }
                    }
                }
            }
        }
        if case .shelf(let id) = list, let reader = kindle.readers.first(where: { $0.id == id }),
           current.contains(where: { $0.shelfIDs.contains(id) }) {
            Button("Retirer de l'étagère « \(reader.name) »") {
                library.undoable("Retirer de l'étagère") { library.removeFromShelf(books, reader: id) }
            }
        }
    }
}

/// Actions communes (menu contextuel et fiche).
struct BookActions: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(\.libraryList) private var list
    let book: Book

    var body: some View {
        if list == .trash || library.book(id: book.id)?.trashedAt != nil {
            trashActions
        } else {
            libraryActions
        }
    }

    /// Livre dans la corbeille : le restaurer, ou placer ses fichiers dans la Corbeille de macOS.
    @ViewBuilder private var trashActions: some View {
        Button("Restaurer") { library.undoable("Restaurer") { library.restoreFromTrash(book) } }
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) }
        Divider()
        Button("Supprimer définitivement…", role: .destructive) {
            let files = library.trashedFiles(of: book)
            if Panels.confirmDeletePermanently(book, fileCount: files.count) {
                Task { await library.deletePermanently(files) }
            }
        }
    }

    @ViewBuilder private var libraryActions: some View {
        let isPending = library.book(id: book.id)?.isPendingSend == true
        // Déjà en attente et Kindle débranchée : le remettre en attente n'aurait aucun effet.
        if !(isPending && !kindle.isConnected) {
            KindleSendButton(books: [book]) { Text(KindleSendLabel.title(kindle)) }
                .disabled(kindle.isBusy || !book.canSendToKindle)
        }
        ShelfActions(books: [book])
        // Retirer d'une liste ne supprime rien : le livre reste dans la bibliothèque.
        if isPending {
            Button("Retirer de la liste « En attente d'envoi »") {
                library.undoable("Retirer de la file d'envoi") { library.removeFromKindleQueue([book.id]) }
            }
        }
        if list == .sent, library.book(id: book.id)?.lastSentAt != nil {
            Button("Retirer de la liste « Envoyés à la Kindle »") {
                library.undoable("Retirer des envoyés") { library.forgetSent(book) }
            }
        }
        if [.mobi, .azw3, .azw].contains(book.format) {
            Button("Exporter en EPUB…") { Task { await Panels.exportEPUB(book, library: library) } }
                .disabled(book.isDRMProtected)
        }
        Divider()
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) }
        Button("Ouvrir") { NSWorkspace.shared.open(book.url) }
        // Pas de corbeille dans les listes « Envoyés », « En attente » ou une étagère : le menu propose
        // d'y retirer le livre de la liste (règle partagée avec Livre > Mettre à la corbeille).
        if list?.allowsTrash == true {
            Divider()
            Button("Mettre à la corbeille") { library.undoable("Mettre à la corbeille") { library.moveToTrash(book) } }
        }
    }
}
