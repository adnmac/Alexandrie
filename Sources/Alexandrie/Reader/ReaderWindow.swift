import AlexandrieCore
import SwiftUI

/// Ouvre la fenêtre de lecture d'un livre depuis les menus et la grille, qui n'ont pas `openWindow`.
/// La fenêtre principale la branche à son apparition ; une fenêtre déjà ouverte pour ce livre revient devant.
@MainActor
enum ReaderWindows {
    static var open: (Book.ID) -> Void = { _ in }
}

/// Passage à montrer à l'ouverture d'une fenêtre de lecture (S-083) : section (chapitre ou page),
/// texte exact et son rang dans la section.
struct ReaderTarget: Equatable {
    let section: Int
    let text: String
    let occurrence: Int
    /// Recherche d'où vient le passage (S-085) : ses renvois sont listés dans la fenêtre de lecture.
    var query = ""
    var exact = false
    let id = UUID()
}

/// Passages demandés par la recherche dans le contenu, par livre : la fenêtre de lecture les prend en
/// s'ouvrant, ou tout de suite si elle l'est déjà.
@MainActor @Observable
final class ReaderLaunch {
    static let shared = ReaderLaunch()
    private(set) var targets: [Book.ID: ReaderTarget] = [:]

    func open(_ book: Book, at target: ReaderTarget) {
        targets[book.id] = target
        ReaderWindows.open(book.id)
    }

    func take(_ id: Book.ID) -> ReaderTarget? {
        targets.removeValue(forKey: id)
    }
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
    @Environment(KindleMonitor.self) private var kindle
    @Environment(ResearchStore.self) private var researches
    @State private var content: Content?
    /// Feuille « Recherches » ouverte (S-075).
    @State private var managesResearches = false
    @State private var failure: String?
    /// Table des matières ouverte ou fermée, pour tous les livres.
    @AppStorage("readerContentsVisible") private var showsContents = false
    /// Renvois de la recherche dans le contenu (S-085) : passages du mot cherché, celui affiché, et la recherche.
    @State private var hits: [ContentSearch.Snippet] = []
    @State private var hitIndex = 0
    @State private var hitQuery = ""
    /// Colonne de gauche : table des matières ou renvois de la recherche.
    @State private var sidebarMode: SidebarMode = .contents

    enum SidebarMode: Hashable { case contents, hits }

    enum Content {
        case epub(EPUBPageController)
        case pdf(PDFPageController)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { showsContents ? .all : .detailOnly },
                                                      set: { showsContents = $0 != .detailOnly })) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
        } detail: {
            page
                .safeAreaInset(edge: .top, spacing: 0) { if !hits.isEmpty { hitsBar } }
        }
        .navigationTitle(book.title)
        .navigationSubtitle(book.authorLine)
        .toolbar { toolbar }
        .task { await load() }
        .onChange(of: reading.textScale) { applySettings() }
        .onChange(of: reading.theme) { applySettings() }
        .onChange(of: kindle.readerHighlights(of: book)) { showHighlights() }
        // Un thème renommé ou recoloré : les passages sont redessinés.
        .onChange(of: researches.list.researches) { redrawHighlights() }
        .sheet(isPresented: $managesResearches) {
            ResearchesSheet(selected: researches.activeResearch(for: book)?.id)
        }
        .onChange(of: ReaderLaunch.shared.targets[book.id]) { jumpToTarget() }
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

    // MARK: Renvois de la recherche (S-085)

    /// Colonne de gauche : la table des matières, ou, ouverte depuis la recherche, la liste des renvois.
    @ViewBuilder private var sidebar: some View {
        if hits.isEmpty {
            contents
        } else {
            VStack(spacing: 0) {
                Picker("Afficher", selection: $sidebarMode) {
                    Text("Sommaire").tag(SidebarMode.contents)
                    Text("Renvois (\(hits.count))").tag(SidebarMode.hits)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(Space.sm)
                if sidebarMode == .hits { hitsList } else { contents }
            }
        }
    }

    private var hitsList: some View {
        List(selection: Binding(get: { hitIndex }, set: { if let i = $0 { goToHit(i) } })) {
            ForEach(Array(hits.enumerated()), id: \.offset) { i, hit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hitPlace(hit)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(hit.before)\(Text(hit.match).bold())\(hit.after)")
                        .font(.callout)
                        .lineLimit(3)
                }
                .padding(.vertical, 2)
                .tag(i)
            }
        }
    }

    /// Où se trouve un renvoi : la page d'un PDF, ou le titre du chapitre.
    private func hitPlace(_ hit: ContentSearch.Snippet) -> String {
        if book.format == .pdf { return "Page \(hit.section + 1)" }
        let entry = entries.last { $0.chapter <= hit.section }
        return entry.map { $0.title.isEmpty ? "Chapitre \(hit.section + 1)" : $0.title } ?? "Chapitre \(hit.section + 1)"
    }

    /// Barre au-dessus de la page : le mot cherché, le renvoi affiché, précédent et suivant (⇧⌘G, ⌘G).
    private var hitsBar: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("« \(hitQuery) »").font(.callout.weight(.semibold)).lineLimit(1)
            Text("\(hitIndex + 1) sur \(hits.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            ControlGroup {
                Button { goToHit(hitIndex - 1) } label: { Label("Renvoi précédent", systemImage: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(hitIndex == 0)
                    .help("Renvoi précédent (⇧⌘G)")
                Button { goToHit(hitIndex + 1) } label: { Label("Renvoi suivant", systemImage: "chevron.down") }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(hitIndex >= hits.count - 1)
                    .help("Renvoi suivant (⌘G)")
            }
            .fixedSize()
            Button {
                hits = []
                sidebarMode = .contents
            } label: { Label("Fermer la recherche", systemImage: "xmark.circle.fill") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Fermer la recherche ; la colonne rend la table des matières")
        }
        .controlSize(.small)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    /// Montre un renvoi : sa page, le mot sélectionné.
    private func goToHit(_ index: Int) {
        guard hits.indices.contains(index) else { return }
        hitIndex = index
        let hit = hits[index]
        switch content {
        case .epub(let c): c.open(chapter: hit.section, text: hit.match, occurrence: hit.occurrence)
        case .pdf(let c): c.show(page: hit.section, text: hit.match, occurrence: hit.occurrence)
        case nil: break
        }
    }

    /// Renvois d'une recherche venue de la liste des résultats : chargés, colonne de gauche ouverte dessus.
    private func loadHits(for target: ReaderTarget) {
        guard !target.query.isEmpty else { return }
        let book = book
        Task {
            let found = await AppServices.shared.contentIndexer.passages(of: book, query: target.query, exact: target.exact)
            guard !found.isEmpty else { return }
            hits = found
            hitQuery = target.query
            hitIndex = found.firstIndex { $0.section == target.section && $0.match == target.text && $0.occurrence == target.occurrence } ?? 0
            sidebarMode = .hits
            showsContents = true
        }
    }

    // MARK: Réglages du texte (S-069)

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { researchMenu }
        ToolbarItem(placement: .primaryAction) {
            Button { highlight() } label: { Label("Surligner", systemImage: "highlighter") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!hasSelection)
                .help("Surligner la sélection (⇧⌘H) ; un clic sur le passage surligné y ajoute une note")
        }
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

    // MARK: Thématique (S-076, S-079)

    /// Thématique choisie pour ce livre : les prochains surlignages y sont rangés, et sa légende nomme leurs couleurs.
    private var researchMenu: some View {
        Menu {
            Picker("Thématique", selection: Binding(get: { researches.activeResearch(for: book)?.id },
                                                    set: { researches.setActive($0, for: book) })) {
                Text("Aucune thématique").tag(String?.none)
                ForEach(researches.researches) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Gérer les thématiques…") { managesResearches = true }
        } label: {
            Label(researches.activeResearch(for: book)?.name ?? "Aucune thématique", systemImage: "tag")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Un nom long est coupé : il ne pousse pas les réglages du texte hors de la barre d'outils.
        .frame(maxWidth: Layout.toolbarMenu)
        .help("Thématique de ce livre : les nouveaux surlignages y sont rangés, et sa légende nomme leurs couleurs")
    }

    // MARK: Surlignages (S-070)

    private var hasSelection: Bool {
        switch content {
        case .epub(let c): c.hasSelection
        case .pdf(let c): c.hasSelection
        case nil: false
        }
    }

    /// Surligne la sélection : le passage est enregistré avec les notes, le livre n'est pas modifié.
    /// Avec `withNote`, sa note s'ouvre aussitôt (S-071).
    private func highlight(withNote: Bool = false) {
        let book = book, kindle = kindle
        Task {
            let passage: (anchor: ReaderAnchor, text: String)?
            switch content {
            case .epub(let c): passage = await c.selectedPassage(fingerprint: book.fingerprint)
            case .pdf(let c): passage = c.selectedPassage(fingerprint: book.fingerprint)
            case nil: passage = nil
            }
            guard let passage else { return }
            var clipping = Clipping.readerHighlight(title: book.title, author: book.authorLine, text: passage.text,
                                                    anchor: passage.anchor, isPDF: book.format == .pdf)
            let next = researches.nextMark(for: book)
            clipping.apply(next.mark)
            if let thematic = next.research { clipping.setThematic(thematic, on: true) }
            kindle.addHighlight(clipping)
            showHighlights()
            switch content {
            case .epub(let c):
                c.clearSelection()
                if withNote { openNote(clipping.id, at: await c.noteRect(for: clipping.id)) }
            case .pdf(let c):
                c.clearSelection()
                if withNote { openNote(clipping.id, at: c.noteRect(for: clipping.id)) }
            case nil: break
            }
        }
    }

    /// Commandes des menus contextuels des pages (S-073).
    private var highlightActions: ReaderHighlightActions {
        let kindle = kindle, researches = researches, book = book
        return ReaderHighlightActions(
            highlight: { highlight(withNote: $0) },
            editNote: { editNote($0) },
            delete: { deleteHighlight($0) },
            lookup: { kindle.clipping(id: $0) },
            marks: { id in
                if let c = id.flatMap(kindle.clipping(id:)) { return researches.marks(for: c) }
                return researches.list.marks(in: researches.activeResearch(for: book)?.id)
            },
            mark: { id in
                if let c = id.flatMap(kindle.clipping(id:)) { return researches.mark(of: c) }
                return researches.nextMark(for: book).mark
            },
            setMark: { id, mark in
                if let id { researches.apply(mark, to: id) } else {
                    researches.remember(mark, in: researches.activeResearch(for: book)?.id)
                }
            },
            researchName: { researches.activeResearch(for: book)?.name },
            thematics: { researches.researches.map { ($0.id, $0.name) } },
            setThematic: { id, thematic, on in researches.setThematic(thematic, on: on, for: id) })
    }

    private func redrawHighlights() {
        switch content {
        case .epub(let c): c.redraw()
        case .pdf(let c): c.redraw()
        case nil: break
        }
    }

    /// « Ajouter une note… » du menu : la bulle s'ouvre sur le passage dans la page affichée.
    private func editNote(_ id: Clipping.ID) {
        Task {
            switch content {
            case .epub(let c): openNote(id, at: await c.noteRect(for: id))
            case .pdf(let c): openNote(id, at: c.noteRect(for: id))
            case nil: break
            }
        }
    }

    /// Supprime un surlignage depuis la page ; sa note, s'il en a une, est confirmée d'abord.
    private func deleteHighlight(_ id: Clipping.ID) {
        if kindle.clipping(id: id)?.hasNote == true {
            let alert = NSAlert()
            alert.messageText = "Supprimer ce surlignage et sa note ?"
            alert.informativeText = "Il disparaît aussi de « Notes et surlignages ». Le fichier du livre n'est pas modifié."
            alert.addButton(withTitle: "Supprimer").hasDestructiveAction = true
            alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        kindle.deleteClipping(id)
    }

    /// Ouvre la note d'un surlignage en bulle sur son passage (S-071). Une bulle AppKit, dans sa propre
    /// fenêtre : une bulle SwiftUI resterait sous la vue web ou PDF, qui prendrait ses clics.
    private func openNote(_ id: Clipping.ID, at rect: CGRect?) {
        let view: NSView? = switch content {
        case .epub(let c): c.webView
        case .pdf(let c): c.view
        case nil: nil
        }
        guard let view, let clipping = kindle.clipping(id: id) else { return }
        NotePopover.show(clipping, kindle: kindle, at: rect ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                         in: view)
    }

    private func showHighlights() {
        let list = kindle.readerHighlights(of: book)
        switch content {
        case .epub(let c): c.highlights = list
        case .pdf(let c): c.highlights = list
        case nil: break
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
            controller.actions = highlightActions
            controller.markOf = { [researches] in researches.mark(of: $0) }
            controller.onOpenNote = { openNote($0, at: $1) }
            content = .pdf(controller)
            showHighlights()
            // Après la mise en place de la vue : PDFKit ignore un saut de page fait avant.
            try? await Task.sleep(for: .milliseconds(50))
            controller.apply(scale: reading.textScale)
            controller.go(to: start?.chapter ?? 0)
            jumpToTarget()
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
                controller.actions = highlightActions
                controller.markOf = { [researches] in researches.mark(of: $0) }
                controller.onOpenNote = { openNote($0, at: $1) }
                content = .epub(controller)
                showHighlights()
                // Un passage trouvé l'emporte sur la position de lecture.
                if ReaderLaunch.shared.targets[book.id] != nil { jumpToTarget() } else {
                    controller.open(chapter: start?.chapter ?? 0, fraction: start?.fraction ?? 0)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Passage trouvé par la recherche dans le contenu (S-083), s'il y en a un pour ce livre.
    private func jumpToTarget() {
        guard content != nil, let target = ReaderLaunch.shared.take(book.id) else { return }
        loadHits(for: target)
        switch content {
        case .epub(let c): c.open(chapter: target.section, text: target.text, occurrence: target.occurrence)
        case .pdf(let c): c.show(page: target.section, text: target.text, occurrence: target.occurrence)
        case nil: break
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

/// Bulle de la note d'un surlignage, posée sur le passage cliqué (S-071).
@MainActor
enum NotePopover {
    private static var current: NSPopover?

    static func show(_ clipping: Clipping, kindle: KindleMonitor, at rect: CGRect, in view: NSView) {
        current?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let editor = HighlightNoteEditor(clipping: clipping, showsPassage: true) { [weak popover] in popover?.close() }
            .environment(kindle)
            .environment(AppServices.shared.researches)
            .padding(Space.lg)
            .frame(width: Layout.notePopover)
        let host = NSHostingController(rootView: editor)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        current = popover
    }
}
