import FolunaCore
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

/// Sélection de la grille et de la liste, lue par chaque carte : un clic ne redessine que les cartes
/// concernées, pas toute la grille (100 000 cartes : près d'une seconde par clic).
@MainActor @Observable
final class SelectionBox {
    var ids = Set<String>()
}

/// Comparée par l'identité de sa liste (`listingID`) : quand seule la sélection change, la fenêtre se redessine
/// sans reconstruire la grille ni la liste (`.equatable()`).
struct LibraryView: View, Equatable {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let groups: [BookGroup]
    let listingID: Int
    /// Change avec la page, la recherche ou le tri (pas avec une retouche) : la liste est alors reconstruite
    /// plutôt que comparée ligne à ligne, ce qui prenait des secondes sur 100 000 livres quand l'ordre changeait.
    var tableIdentity = 0
    let selection: SelectionBox
    let setSelection: (Set<String>) -> Void
    let gridMode: Bool
    let resolve: (String) -> Book?
    /// Liste en cours de calcul (grande bibliothèque) : celle d'avant reste affichée, un indicateur le signale.
    var isComputing = false
    /// La grille prend le focus au clic : Espace (Coup d'œil) et Supprimer lui arrivent alors.
    @FocusState private var gridFocused: Bool

    var body: some View {
        content
            .overlay(alignment: .top) {
                if isComputing && !groups.isEmpty {
                    ProgressView().controlSize(.small).padding(Space.md)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if groups.isEmpty {
            if library.isScanning {
                ProgressView("Indexation de la bibliothèque…")
            } else if isComputing {
                ProgressView()
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
        let ids = selection.ids
        guard ids.contains(g.id), ids.count > 1 else { return [g.primary] }
        return ids.compactMap(resolve)
    }

    // MARK: - Grille : une carte par livre, avec tous ses formats

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 20)], spacing: 24) {
                ForEach(groups) { g in
                    SelectableBookCard(group: g, onDevice: g.books.contains(where: kindle.isOnDevice), selection: selection)
                        // Double-clic : lire le livre (S-066) ; le simple clic reste la sélection.
                        .onTapGesture(count: 2) { if g.primary.canRead, !library.isUnavailable(g.primary) { ReaderWindows.open(g.primary.id) } }
                        .onTapGesture { select(g) }
                        .contextMenu { BookActions(book: g.primary) }
                        // Glisser vers une liseuse de la barre latérale : le livre (ou la sélection) rejoint son étagère.
                        // Vers le Finder : une copie du fichier ; vers une liseuse : la sélection, pour son étagère.
                        .draggable(BookDragItem(payload: BookDrag.payload(dragged(g)), file: g.primary.url)) {
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
            setSelection([])
            gridFocused = true
        }
    }

    private func select(_ g: BookGroup) {
        let flags = NSEvent.modifierFlags
        var ids = selection.ids
        if flags.contains(.command) {
            if ids.contains(g.id) { ids.remove(g.id) } else { ids.insert(g.id) }
        } else if flags.contains(.shift), let anchor = ids.first,
                  let a = groups.firstIndex(where: { $0.id == anchor }),
                  let b = groups.firstIndex(where: { $0.id == g.id }) {
            ids = Set(groups[min(a, b)...max(a, b)].map(\.id))
        } else {
            ids = [g.id]
        }
        setSelection(ids)
        gridFocused = true
    }

    // MARK: - Liste : chevron à gauche pour déplier les fichiers d'un même livre

    private var table: some View {
        Table(LibraryRow.rows(groups), children: \.children,
              selection: Binding(get: { selection.ids }, set: { setSelection($0) })) {
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
                    if !r.isFile, r.book.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(Palette.favorite)
                            .accessibilityLabel(Text("Favori")).help("Favori")
                    }
                    if (r.group?.books ?? [r.book]).contains(where: kindle.isOnDevice) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).help("Sur la liseuse")
                    }
                    if (r.group?.books ?? [r.book]).contains(where: \.isPendingSend) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.info)
                            .help("En attente d'envoi : partira dès que la liseuse sera branchée")
                    }
                }
                .help(r.isFile ? r.book.path : r.book.title)
            }
            TableColumn("Auteur") { r in Text(r.isFile ? "" : r.book.authorLine).lineLimit(1) }
            TableColumn("Série") { r in
                if !r.isFile, let s = r.book.series {
                    Text(s + (r.book.seriesIndex.map { String(localized: " · \(SeriesNames.format($0))") } ?? "")).lineLimit(1)
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
        .id(tableIdentity)
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let b = resolve(id) { BookActions(book: b) }
        } primaryAction: { ids in
            // Double-clic sur une ligne : lire le livre (S-066).
            if ids.count == 1, let b = ids.first.flatMap(resolve), b.canRead, !library.isUnavailable(b) { ReaderWindows.open(b.id) }
        }
    }
}

extension LibraryView {
    nonisolated static func == (a: LibraryView, b: LibraryView) -> Bool {
        a.listingID == b.listingID && a.gridMode == b.gridMode && a.isComputing == b.isComputing
    }
}

/// Carte de la grille qui lit elle-même si elle est sélectionnée (voir `SelectionBox`).
struct SelectableBookCard: View {
    let group: BookGroup
    let onDevice: Bool
    let selection: SelectionBox

    var body: some View {
        BookCard(book: group.primary, formats: group.formats, fileCount: group.books.count,
                 onDevice: onDevice, isSelected: selection.ids.contains(group.id))
    }
}

struct BookCard: View {
    @Environment(LibraryStore.self) private var library
    let book: Book
    var formats: [BookFormat] = []
    var fileCount = 1
    var onDevice = false
    let isSelected: Bool
    /// Étoile proposée au survol (S-107) ; toujours visible sur un favori.
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            CoverView(book: book) {
                RoundedRectangle(cornerRadius: Radius.cover)
                    .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 3)  // grid: ok épaisseur de trait, pas un espacement
                    .overlay(alignment: .topTrailing) { badges }
                    .overlay(alignment: .topLeading) { favoriteStar }
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
        .onHover { isHovered = $0 }
    }

    /// Favori (S-107) : étoile pleine toujours visible, étoile vide au survol ; un clic bascule, sans changer la sélection.
    @ViewBuilder private var favoriteStar: some View {
        if book.isFavorite || isHovered {
            FavoriteButton(books: [book])
                .buttonStyle(.plain)
                .font(.caption)
                .padding(Space.xs).background(.ultraThinMaterial, in: Circle())
                .padding(Space.sm)
        }
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
                    .help("En attente d'envoi : partira dès que la liseuse sera branchée")
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
                    .help("Présent sur la liseuse")
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
    static let prefix = "foluna-livres:"

    static func payload(_ books: [Book]) -> String { prefix + books.map(\.id).joined(separator: "\n") }

    static func ids(_ text: String) -> [Book.ID]? {
        guard text.hasPrefix(prefix) else { return nil }
        return text.dropFirst(prefix.count).split(separator: "\n").map(String.init)
    }
}

/// Livre glissé hors de la grille, sous deux formes :
/// - la liste des livres, lue seulement par l'app (liseuses de la barre latérale) ;
/// - l'adresse d'une copie du fichier, que le Finder ou le bureau reçoivent. Une copie temporaire, pas le
///   fichier de la bibliothèque : sur le même disque, le Finder pourrait déplacer ce qu'on lui donne.
/// Une `FileRepresentation` ne suffit pas : le Finder ne l'accepte pas d'une autre app (S-050, FIXLOG).
struct BookDragItem: Transferable {
    let payload: String
    let file: URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.payload)
            .visibility(.ownProcess)
        ProxyRepresentation(exporting: { try $0.dragCopy() })
    }

    /// Copie dans un dossier temporaire à part, sous le nom du fichier (clone instantané sur APFS).
    func dragCopy() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Foluna-glisser", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
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
                library.undoable(String(localized: "Ajouter à l'étagère")) { library.addToShelf(books, reader: reader.id) }
            }
        } else if available.count > 1 {
            Menu("Ajouter à l'étagère") {
                ForEach(available) { reader in
                    Button(reader.name) {
                        library.undoable(String(localized: "Ajouter à l'étagère")) { library.addToShelf(books, reader: reader.id) }
                    }
                }
            }
        }
        if case .shelf(let id) = list, let reader = kindle.readers.first(where: { $0.id == id }),
           current.contains(where: { $0.shelfIDs.contains(id) }) {
            Button("Retirer de l'étagère « \(reader.name) »") {
                library.undoable(String(localized: "Retirer de l'étagère")) { library.removeFromShelf(books, reader: id) }
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
        Button("Restaurer") { library.undoable(String(localized: "Restaurer")) { library.restoreFromTrash(book) } }
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
        Button("Lire") { ReaderWindows.open(book.id) }
            .disabled(!book.canRead || library.isUnavailable(book))
        let isFavorite = library.areFavorites([book])
        Button(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { library.toggleFavorite([book]) }
        Divider()
        // Déjà en attente et Kindle débranchée : le remettre en attente n'aurait aucun effet.
        if !(isPending && !kindle.isConnected) {
            KindleSendButton(books: [book]) { Text(KindleSendLabel.title(kindle)) }
                .disabled(kindle.isBusy || !kindle.canSend(book))
        }
        ShelfActions(books: [book])
        TagActions(books: [book])
        // Retirer d'une liste ne supprime rien : le livre reste dans la bibliothèque.
        if isPending {
            Button("Retirer de la liste « En attente d'envoi »") {
                library.undoable(String(localized: "Retirer de la file d'envoi")) { library.removeFromKindleQueue([book.id]) }
            }
        }
        if list == .sent, library.book(id: book.id)?.lastSentAt != nil {
            Button("Retirer de la liste « Envoyés à la liseuse »") {
                library.undoable(String(localized: "Retirer des envoyés")) { library.forgetSent(book) }
            }
        }
        if [.mobi, .azw3, .azw].contains(book.format) {
            Button("Exporter en EPUB…") { Task { await Panels.exportEPUB(book, library: library) } }
                .disabled(book.isDRMProtected)
        }
        Divider()
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) }
        Button("Ouvrir") { NSWorkspace.shared.open(book.url) }
        // Sous-menu du système : AirDrop, Mail, Messages… avec le fichier du livre, intact.
        ShareLink(item: book.url) { Text("Partager") }
        // Pas de corbeille dans les listes « Envoyés », « En attente » ou une étagère : le menu propose
        // d'y retirer le livre de la liste (règle partagée avec Livre > Mettre à la corbeille).
        if list?.allowsTrash == true {
            Divider()
            Button(String(localized: "Mettre à la corbeille")) { library.undoable("Mettre à la corbeille") { library.moveToTrash(book) } }
        }
    }
}

/// Étoile qui ajoute aux favoris ou en retire (S-107) : carte de la grille et fiche.
struct FavoriteButton: View {
    @Environment(LibraryStore.self) private var library
    let books: [Book]

    var body: some View {
        let isFavorite = library.areFavorites(books)
        Button { library.toggleFavorite(books) } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? AnyShapeStyle(Palette.favorite) : AnyShapeStyle(.secondary))
        }
        .accessibilityLabel(Text(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris"))
        .help(isFavorite ? String(localized: "Retirer des favoris (⌘D)") : String(localized: "Ajouter aux favoris (⌘D)"))
    }
}

/// Étiquettes de l'utilisateur (S-106) : cocher ou décocher pour la sélection, ou en créer une.
struct TagActions: View {
    @Environment(LibraryStore.self) private var library
    let books: [Book]

    var body: some View {
        let current = books.compactMap { library.book(id: $0.id) }
        let tags = library.summary.tags
        Menu("Étiquettes") {
            ForEach(tags) { tag in
                Toggle(tag.name, isOn: Binding(
                    get: { !current.isEmpty && current.allSatisfy { TagNames.has($0, key: tag.key) } },
                    set: { on in
                        library.undoable(on ? String(localized: "Ajouter l'étiquette") : String(localized: "Retirer l'étiquette")) {
                            if on { library.addTag(tag.name, to: books) } else { library.removeTag(key: tag.key, from: books) }
                        }
                    }))
            }
            if !tags.isEmpty { Divider() }
            Button("Nouvelle étiquette…") {
                guard let name = Panels.askTagName(title: String(localized: "Nouvelle étiquette"), action: String(localized: "Ajouter")) else { return }
                library.undoable(String(localized: "Ajouter l'étiquette")) { library.addTag(name, to: books) }
            }
        }
    }
}
