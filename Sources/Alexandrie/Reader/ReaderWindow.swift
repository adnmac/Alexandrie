import AlexandrieCore
import SwiftUI

/// Ouvre la fenêtre de lecture d'un livre depuis les menus et la grille, qui n'ont pas `openWindow`.
/// La fenêtre principale la branche à son apparition ; une fenêtre déjà ouverte pour ce livre revient devant.
@MainActor
enum ReaderWindows {
    static var open: (Book.ID) -> Void = { _ in }
}

/// Fenêtre « Lecture » (S-066) : le livre dont l'identifiant est passé à `openWindow`.
struct ReaderWindow: View {
    let bookID: Book.ID?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let book = bookID.flatMap(library.book(id:)) {
            ReaderView(book: book)
        } else {
            ContentUnavailableView("Livre introuvable", systemImage: "book.closed",
                                   description: Text("Ce livre ne fait plus partie de la bibliothèque."))
        }
    }
}

struct ReaderView: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    @Environment(ReadingStore.self) private var reading
    @State private var content: Content?
    @State private var failure: String?
    /// Table des matières ouverte ou fermée, pour tous les livres.
    @AppStorage("readerContentsVisible") private var showsContents = false

    enum Content {
        case epub(EPUBPageController)
        case pdf(PDFPageController)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { showsContents ? .all : .detailOnly },
                                                      set: { showsContents = $0 != .detailOnly })) {
            contents
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            page
        }
        .navigationTitle(book.title)
        .navigationSubtitle(book.authorLine)
        .toolbar { toolbar }
        .task { await load() }
        .onChange(of: reading.textScale) { applySettings() }
        .onChange(of: reading.theme) { applySettings() }
        .onDisappear { reading.saveNow() }
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        switch content {
        case .epub(let controller):
            VStack(spacing: 0) {
                EPUBPageView(controller: controller)
                footer(previous: controller.previous, next: controller.next,
                       text: "Page \(controller.page + 1) sur \(controller.pageCount) du chapitre",
                       percent: controller.percent)
            }
            .background(reading.theme.paperColor)
        case .pdf(let controller):
            VStack(spacing: 0) {
                PDFPageView(controller: controller)
                footer(previous: controller.previous, next: controller.next,
                       text: "Page \(controller.page + 1) sur \(controller.pageCount)", percent: controller.percent)
            }
        case nil:
            if let failure {
                ContentUnavailableView("Lecture impossible", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else {
                ProgressView("Préparation du livre…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func footer(previous: @escaping () -> Void, next: @escaping () -> Void, text: String, percent: Double) -> some View {
        HStack(spacing: Space.md) {
            Button(action: previous) { Image(systemName: "chevron.left") }
                .help("Page précédente (←)")
            Spacer()
            Text(text).monospacedDigit()
            Text("·")
            Text(ReadingPosition(chapter: 0, fraction: 0, percent: percent).label).monospacedDigit()
            Spacer()
            Button(action: next) { Image(systemName: "chevron.right") }
                .help("Page suivante (→ ou Espace)")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    // MARK: Table des matières (S-067)

    private var entries: [ReaderBook.Entry] {
        switch content {
        case .epub(let c): c.book.toc
        case .pdf(let c): c.toc
        case nil: []
        }
    }

    /// Entrée en cours : la dernière qui commence au chapitre (ou à la page) affiché ou avant.
    private var currentEntry: ReaderBook.Entry.ID? {
        let position: Int = switch content {
        case .epub(let c): c.chapter
        case .pdf(let c): c.page
        case nil: -1
        }
        return entries.last { $0.chapter <= position }?.id
    }

    @ViewBuilder private var contents: some View {
        if entries.isEmpty {
            ContentUnavailableView("Pas de table des matières", systemImage: "list.bullet",
                                   description: Text("Ce livre n'en contient pas."))
        } else {
            List(entries, selection: Binding(get: { currentEntry }, set: { id in
                guard let entry = entries.first(where: { $0.id == id }) else { return }
                switch content {
                case .epub(let c): c.open(entry)
                case .pdf(let c): c.go(to: entry.chapter)
                case nil: break
                }
            })) { entry in
                Text(entry.title.isEmpty ? "Sans titre" : entry.title)
                    .lineLimit(2)
                    .padding(.leading, CGFloat(entry.depth) * Space.md)
                    .tag(entry.id)
            }
        }
    }

    // MARK: Réglages du texte (S-069)

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { reading.reduce() } label: { Label("Réduire le texte", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut("-")
                    .disabled(!reading.canReduce)
                Button { reading.enlarge() } label: { Label("Agrandir le texte", systemImage: "textformat.size.larger") }
                    .keyboardShortcut("+")
                    .disabled(!reading.canEnlarge)
            }
            .help("Taille du texte (⌘− / ⌘+)")
            Picker("Fond", selection: Binding(get: { reading.theme }, set: { reading.theme = $0 })) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(book.format == .pdf)
            .help(book.format == .pdf ? "Un PDF garde ses couleurs" : "Fond de la page")
        }
    }

    // MARK: Chargement

    private func load() async {
        let start = reading.savedPosition(of: book)
        let book = book, reading = reading
        if book.format == .pdf {
            let controller = PDFPageController(url: book.url)
            guard controller.document != nil else {
                failure = "Ce PDF est illisible."
                return
            }
            content = .pdf(controller)
            // Après la mise en place de la vue : PDFKit ignore un saut de page fait avant.
            try? await Task.sleep(for: .milliseconds(50))
            controller.apply(scale: reading.textScale)
            controller.go(to: start?.chapter ?? 0)
            controller.onMove = { reading.record($0, for: book) }
        } else {
            let directories = library.directories
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ReaderBook.prepare(book, directories: directories)
                }.value
                let controller = EPUBPageController(book: prepared)
                controller.apply(scale: reading.textScale, theme: reading.theme)
                controller.onMove = { reading.record($0, for: book) }
                content = .epub(controller)
                controller.open(chapter: start?.chapter ?? 0, fraction: start?.fraction ?? 0)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func applySettings() {
        switch content {
        case .epub(let c): c.apply(scale: reading.textScale, theme: reading.theme)
        case .pdf(let c): c.apply(scale: reading.textScale)
        case nil: break
        }
    }
}
