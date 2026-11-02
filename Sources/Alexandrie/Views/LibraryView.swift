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

    // MARK: - Grille : une carte par livre, avec tous ses formats

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 20)], spacing: 24) {
                ForEach(groups) { g in
                    BookCard(book: g.primary, formats: g.formats, fileCount: g.books.count,
                             onDevice: g.books.contains(where: kindle.isOnDevice), isSelected: selection.contains(g.id))
                        .onTapGesture { select(g) }
                        .contextMenu { BookActions(book: g.primary) }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onTapGesture { selection.removeAll() }
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
    }

    // MARK: - Liste : chevron à gauche pour déplier les fichiers d'un même livre

    private var table: some View {
        Table(LibraryRow.rows(groups), children: \.children, selection: $selection) {
            TableColumn("Titre") { r in
                HStack(spacing: 6) {
                    if r.isFile {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text((r.book.path as NSString).lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    } else {
                        Text(r.book.title).lineLimit(1)
                        if let g = r.group {
                            Text("\(g.books.count) fichiers")
                                .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if (r.group?.books ?? [r.book]).contains(where: kindle.isOnDevice) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Sur la Kindle")
                    }
                    if (r.group?.books ?? [r.book]).contains(where: { $0.pendingSendAt != nil }) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
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
        VStack(alignment: .leading, spacing: 6) {
            CoverView(book: book)
                .frame(height: 200)
                .overlay(alignment: .topTrailing) { badges }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
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
                    .padding(.horizontal, 5).padding(.vertical, 2)
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
                    .foregroundStyle(.orange)
                    .padding(4).background(.ultraThinMaterial, in: Circle())
                    .help("Le catalogue propose des corrections")
            }
            if book.pendingSendAt != nil {
                Image(systemName: "clock.arrow.circlepath").font(.caption)
                    .foregroundStyle(.blue)
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
                    .foregroundStyle(.green)
                    .padding(3).background(.ultraThinMaterial, in: Circle())
                    .help("Présent sur la Kindle")
            }
        }
        .padding(6)
    }
}

/// Couverture d'un livre de la bibliothèque.
struct CoverView: View {
    @Environment(LibraryStore.self) private var library
    let book: Book

    var body: some View {
        CoverImage(url: library.coverURL(book), cacheKey: book.fingerprint, title: book.title,
                   subtitle: book.authorLine)
    }
}

/// Couverture mise en cache, avec une couverture générée à défaut.
struct CoverImage: View {
    let url: URL?
    let cacheKey: String
    let title: String
    let subtitle: String
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .task(id: "\(cacheKey)|\(url?.path ?? "")") { await load() }
    }

    private var placeholder: some View {
        let hue = Double(abs(title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 360) / 360
        return RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                          Color(hue: hue, saturation: 0.55, brightness: 0.35)],
                                 startPoint: .top, endPoint: .bottom))
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(4)
                    Text(subtitle).font(.caption).lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(10)
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

/// Actions communes (menu contextuel et fiche).
struct BookActions: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let book: Book

    var body: some View {
        Button(KindleSendLabel.title(kindle)) { Task { await kindle.sendOrQueue([book], library: library) } }
            .disabled(kindle.isBusy || !book.canSendToKindle)
        if library.book(id: book.id)?.pendingSendAt != nil {
            Button("Retirer de la file d'envoi") { library.removeFromKindleQueue([book.id]) }
        }
        if [.mobi, .azw3, .azw].contains(book.format) {
            Button("Exporter en EPUB…") { Task { await Panels.exportEPUB(book, library: library) } }
                .disabled(book.isDRMProtected)
        }
        Divider()
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) }
        Button("Ouvrir") { NSWorkspace.shared.open(book.url) }
        if book.isImported {
            Divider()
            Button("Retirer de la bibliothèque", role: .destructive) { library.removeImported(book) }
        }
    }
}
