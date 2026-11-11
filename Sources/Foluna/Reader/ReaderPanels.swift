import FolunaCore
import AppKit
import SwiftUI

// MARK: - Fenêtre divisée (S-103, S-104)

/// Page et second panneau côte à côte, ou l'un sous l'autre dans une fenêtre étroite.
struct ReaderSplit<First: View, Second: View>: View {
    let vertical: Bool
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    var body: some View {
        if vertical {
            VSplitView {
                first.frame(minHeight: Layout.readerPageMinHeight)
                second
            }
        } else {
            HSplitView {
                first.frame(minWidth: Layout.readerPageMin)
                second
            }
        }
    }
}

/// Bas d'une page : page précédente et suivante, place dans le chapitre, avancée dans le livre.
struct ReaderFooter: View {
    let previous: () -> Void
    let next: () -> Void
    let text: String
    let percent: Double

    var body: some View {
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
}

/// Titre d'un des deux livres d'une comparaison, au-dessus de sa page.
struct ReaderPaneHeader: View {
    let book: Book

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
            Text(book.authorLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }
}

// MARK: - Notes de bas de page (S-103)

/// Notes du chapitre affiché, lues dans les fichiers du livre, et celles dont l'appel est sur la page.
@MainActor @Observable
final class FootnotesModel {
    private(set) var notes: [Footnote] = []
    /// Note ouverte depuis son appel : marquée et amenée en vue dans le panneau.
    var active: Footnote.ID?
    /// Notes dont l'appel est sur la page affichée (mode « Suivre la lecture »).
    private(set) var onPage: [Footnote.ID] = []
    private(set) var isLoaded = false
    /// Chapitre dont les notes sont listées ; -1 avant le premier chargement.
    private(set) var chapter = -1
    /// Note de chaque appel du chapitre, dans l'ordre du texte (un appel répété renvoie à la même note).
    @ObservationIgnored private var references: [Footnote.ID?] = []

    /// Relit les appels du chapitre affiché et le texte de leurs notes.
    func reload(_ controller: EPUBPageController) async {
        let chapter = controller.chapter
        let refs = await controller.noteReferences()
        let root = controller.book.root
        let found = await Task.detached(priority: .userInitiated) {
            var cache: [String: Data] = [:]
            return refs.map { Footnotes.note(at: $0.url, label: $0.label, under: root, cache: &cache) }
        }.value
        var seen = Set<Footnote.ID>(), list: [Footnote] = []
        for note in found.compactMap({ $0 }) where seen.insert(note.id).inserted { list.append(note) }
        notes = list
        references = found.map { $0?.id }
        self.chapter = chapter
        isLoaded = true
        await updatePage(controller)
    }

    /// Relit les notes si le chapitre a changé depuis le dernier chargement.
    func reloadIfNeeded(_ controller: EPUBPageController) async {
        if chapter != controller.chapter || !isLoaded { await reload(controller) }
    }

    func updatePage(_ controller: EPUBPageController) async {
        let indices = await controller.referencesOnPage()
        var ids: [Footnote.ID] = []
        for i in indices where references.indices.contains(i) {
            if let id = references[i], !ids.contains(id) { ids.append(id) }
        }
        onPage = ids
    }

    /// Premier appel de la note dans le texte du chapitre.
    func referenceIndex(of id: Footnote.ID) -> Int? {
        references.firstIndex { $0 == id }
    }

    /// Note d'un appel cliqué, lue hors du fil principal.
    static func resolve(_ url: URL, label: String, root: URL) async -> Footnote? {
        await Task.detached(priority: .userInitiated) {
            var cache: [String: Data] = [:]
            return Footnotes.note(at: url, label: label, under: root, cache: &cache)
        }.value
    }
}

/// Panneau des notes du chapitre, à droite de la page (ou dessous) : la note ouverte est marquée ; « Revenir
/// au texte » ramène à son appel. En suivant la lecture, les notes de la page affichée sont marquées et montrées.
struct ReaderNotesPanel: View {
    let model: FootnotesModel
    @Binding var follows: Bool
    /// Échap ferme le panneau, sauf quand la barre des renvois de la recherche l'utilise déjà.
    let closesOnEscape: Bool
    let onReturn: (Footnote) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Text("Notes du chapitre").font(.headline)
                Spacer(minLength: 0)
                Toggle("Suivre la lecture", isOn: $follows)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Marquer et montrer les notes dont l'appel est sur la page affichée")
                Button(action: onClose) { Label("Fermer les notes", systemImage: "xmark") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hover)
                    .keyboardShortcut(closesOnEscape ? KeyboardShortcut.cancelAction : nil)
                    .help("Fermer le panneau des notes (⌥⌘N)")
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            Divider()
            content
        }
        .background(.background)
    }

    @ViewBuilder private var content: some View {
        if !model.isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.notes.isEmpty {
            ContentUnavailableView("Aucune note dans ce chapitre", systemImage: "list.number",
                                   description: Text("Un clic sur un appel de note l'ouvre ici."))
        } else {
            ScrollViewReader { proxy in
                List(model.notes) { note in
                    row(note)
                        .id(note.id)
                        .listRowBackground(background(of: note))
                }
                .listStyle(.plain)
                .onChange(of: model.active) { if let id = model.active { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: model.onPage) {
                    if follows, model.active.map(model.onPage.contains) != true, let first = model.onPage.first {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
                .onAppear { if let id = model.active { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }

    private func row(_ note: Footnote) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(note.label.isEmpty ? "•" : note.label)
                    .font(.callout.weight(.semibold).monospacedDigit())
                Spacer(minLength: 0)
                Button { onReturn(note) } label: { Label("Revenir au texte", systemImage: "arrow.uturn.backward") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hover)
                    .help("Montrer l'appel de cette note dans le texte")
            }
            ForEach(Array(note.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func background(of note: Footnote) -> some View {
        if model.active == note.id {
            Palette.accent.opacity(Surface.bannerTint)
        } else if follows, model.onPage.contains(note.id) {
            Rectangle().fill(.quaternary.opacity(0.5))
        } else {
            Color.clear
        }
    }
}

/// Bulle d'une note posée sur son appel (S-103) : une note courte, ou toute note pendant une comparaison.
@MainActor
enum FootnotePopover {
    private static var current: NSPopover?

    static func show(_ note: Footnote, at rect: CGRect, in view: NSView, openInPanel: (() -> Void)?) {
        current?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let bubble = FootnoteBubble(note: note, openInPanel: openInPanel.map { open in
            { [weak popover] in popover?.close(); open() }
        })
        let host = NSHostingController(rootView: bubble)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: rect.isEmpty ? CGRect(x: rect.minX, y: rect.minY, width: 1, height: 1) : rect,
                     of: view, preferredEdge: .maxY)
        current = popover
    }
}

struct FootnoteBubble: View {
    let note: Footnote
    let openInPanel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(note.label.isEmpty ? String(localized: "Note") : String(localized: "Note \(note.label)"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if note.text.count > Footnote.shortLength * 2 {
                ScrollView { paragraphs }.frame(height: Layout.footnoteBubbleMax)
            } else {
                paragraphs
            }
            if let openInPanel {
                Button("Ouvrir dans le panneau des notes", action: openInPanel)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(Space.lg)
        .frame(width: Layout.notePopover, alignment: .leading)
    }

    private var paragraphs: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(Array(note.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Comparaison (S-104)

/// Livre lu en face de celui de la fenêtre : sa page, et la correspondance entre leurs chapitres.
/// Synchronisés, tourner la page d'un côté amène l'autre au passage en face, dans les deux sens.
@MainActor @Observable
final class CompareSession {
    let book: Book
    let controller: EPUBPageController
    let alignment: SectionAlignment
    var isLocked = true
    /// Livre comparé à gauche plutôt qu'à droite (ou au-dessus plutôt qu'en dessous).
    var isSwapped = false
    /// Une page tournée par la synchronisation ne relance pas la synchronisation dans l'autre sens.
    @ObservationIgnored private var quietUntil: [ObjectIdentifier: Date] = [:]

    init(book: Book, controller: EPUBPageController, mainWeights: [Int]) {
        self.book = book
        self.controller = controller
        alignment = SectionAlignment(left: mainWeights, right: controller.book.weights)
    }

    /// Une page a tourné, dans le livre de la fenêtre (`main`) ou dans celui d'en face.
    func moved(_ source: EPUBPageController, main: EPUBPageController) {
        let id = ObjectIdentifier(source)
        if let until = quietUntil.removeValue(forKey: id), until > Date() { return }
        guard isLocked else { return }
        let fromMain = source === main
        let target = fromMain ? controller : main
        let place = alignment.counterpart(chapter: source.chapter, fraction: source.fraction, fromLeft: fromMain)
        // Déjà sur la bonne page : rien à tourner.
        let page = 1 / Double(max(1, target.pageCount - 1))
        if place.chapter == target.chapter, abs(place.fraction - target.fraction) < page / 2 { return }
        quietUntil[ObjectIdentifier(target)] = Date().addingTimeInterval(1.5)
        target.open(chapter: place.chapter, fraction: place.fraction)
    }
}

/// Page du livre comparé, avec son titre et son bas de page.
struct ComparePane: View {
    let session: CompareSession
    @Environment(ReadingStore.self) private var reading

    var body: some View {
        let controller = session.controller
        VStack(spacing: 0) {
            ReaderPaneHeader(book: session.book)
            Divider()
            EPUBPageView(controller: controller)
            ReaderFooter(previous: controller.previous, next: controller.next,
                         text: String(localized: "Page \(controller.page + 1) sur \(controller.pageCount) du chapitre"),
                         percent: controller.percent)
        }
        .background(reading.theme.paperColor)
    }
}

/// Feuille « Comparer avec un autre livre » : la traduction ou l'autre édition à lire en face.
/// Les livres du même auteur viennent en tête.
struct CompanionPickerSheet: View {
    let book: Book
    let choose: (Book) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Book.ID?

    private var candidates: [Book] {
        library.visibleBooks
            .filter { $0.id != book.id && ReaderBook.canRead($0) }
            .filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.authorLine.localizedStandardContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let all = candidates
        let authors = Set(book.authors)
        let sameAuthor = all.filter { !authors.isDisjoint(with: $0.authors) }
        let others = all.filter { authors.isDisjoint(with: $0.authors) }
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Comparer avec un autre livre").font(.headline)
            Text("Choisissez la traduction ou l'autre édition à lire en face de « \(book.title) ».")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Rechercher un titre ou un auteur", text: $query)
                .textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                if !sameAuthor.isEmpty {
                    Section("Du même auteur") { ForEach(sameAuthor) { row($0) } }
                }
                if !others.isEmpty {
                    Section(sameAuthor.isEmpty ? "Livres" : "Autres livres") { ForEach(others) { row($0) } }
                }
            }
            .frame(height: Layout.companionList)
            .overlay {
                if all.isEmpty {
                    ContentUnavailableView("Aucun livre à comparer", systemImage: "books.vertical",
                                           description: Text("Seuls les EPUB, MOBI et AZW3 sans DRM se lisent en face."))
                }
            }
            .contextMenu(forSelectionType: Book.ID.self, menu: { _ in }, primaryAction: { ids in
                if let id = ids.first { pick(id) }
            })
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Comparer") { if let selection { pick(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.sheet)
        .noInitialFocus()
    }

    private func row(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 2) {  // grid: ok titre et auteur serrés dans une ligne de liste
            Text(book.title).lineLimit(1)
            Text(book.authorLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .tag(book.id)
    }

    private func pick(_ id: Book.ID) {
        guard let book = library.book(id: id) else { return }
        dismiss()
        choose(book)
    }
}
