import FolunaCore
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
    /// Surlignage ouvert depuis les notes (S-072) : sa position exacte, plutôt que le texte à retrouver.
    var anchor: ReaderAnchor?
    let id = UUID()

    /// Passage d'un surlignage fait dans l'app.
    init(anchor: ReaderAnchor, text: String) {
        self.init(section: anchor.chapter, text: text, occurrence: 0)
        self.anchor = anchor
    }

    init(section: Int, text: String, occurrence: Int, query: String = "", exact: Bool = false) {
        self.section = section
        self.text = text
        self.occurrence = occurrence
        self.query = query
        self.exact = exact
    }
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
    /// Panneau des notes de bas de page ouvert (S-103), pour tous les livres ; ses notes suivent la page.
    @AppStorage("readerNotesVisible") private var showsNotes = false
    @AppStorage("readerNotesFollow") private var notesFollow = true
    /// Une note courte s'ouvre en bulle sur son appel quand le panneau est fermé.
    @AppStorage("readerShortNotesInBubble") private var shortNotesInBubble = true
    @State private var footnotes = FootnotesModel()
    /// Livre lu en face (S-104) ; il prend la place du panneau des notes.
    @State private var compare: CompareSession?
    @State private var choosesCompanion = false
    /// Fenêtre au premier plan : elle remplit le menu Lecture.
    @Environment(\.controlActiveState) private var activeState
    @State private var menuOwner = UUID()

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
            readingArea
                .safeAreaInset(edge: .top, spacing: 0) { if !hits.isEmpty { hitsBar } }
        }
        .navigationTitle(book.title)
        .navigationSubtitle(book.authorLine)
        .toolbar { toolbar }
        .task { await load() }
        .onChange(of: reading.textScale(for: book)) { applySettings() }
        .onChange(of: reading.theme) { applySettings() }
        .onChange(of: reading.font) { applySettings() }
        .onChange(of: kindle.readerHighlights(of: book)) { showHighlights() }
        // Un thème renommé ou recoloré : les passages sont redessinés.
        .onChange(of: researches.list.researches) { redrawHighlights() }
        .sheet(isPresented: $managesResearches) {
            ResearchesSheet(selected: researches.activeResearch(for: book)?.id)
        }
        .sheet(isPresented: $choosesCompanion) {
            CompanionPickerSheet(book: book) { startCompare(with: $0) }
        }
        .onChange(of: showsNotes) { if showsNotes { refreshNotes(reload: true) } }
        .onAppear { publishMenu() }
        .onChange(of: activeState) { publishMenu() }
        .onChange(of: menuValues) { publishMenu() }
        .onChange(of: ReaderLaunch.shared.targets[book.id]) { jumpToTarget() }
        .onDisappear {
            reading.saveNow()
            ReaderMenuState.shared.clear(owner: menuOwner)
        }
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        switch content {
        case .epub(let controller):
            VStack(spacing: 0) {
                if compare != nil {
                    ReaderPaneHeader(book: book)
                    Divider()
                }
                EPUBPageView(controller: controller)
                ReaderFooter(previous: controller.previous, next: controller.next,
                             text: String(localized: "Page \(controller.page + 1) sur \(controller.pageCount) du chapitre"),
                             percent: controller.percent)
            }
            .background(reading.theme.paperColor)
        case .pdf(let controller):
            VStack(spacing: 0) {
                PDFPageView(controller: controller)
                ReaderFooter(previous: controller.previous, next: controller.next,
                             text: String(localized: "Page \(controller.page + 1) sur \(controller.pageCount)"), percent: controller.percent)
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

    // MARK: Fenêtre divisée (S-103, S-104)

    private var epub: EPUBPageController? {
        if case .epub(let c) = content { c } else { nil }
    }

    /// La page seule, ou avec le livre comparé, ou avec le panneau des notes ; dessous dans une fenêtre étroite.
    @ViewBuilder private var readingArea: some View {
        if epub != nil, let compare {
            GeometryReader { geo in
                let vertical = geo.size.width < Layout.readerSplitWidth
                ReaderSplit(vertical: vertical) {
                    comparePane(compare.isSwapped ? AnyView(ComparePane(session: compare)) : AnyView(page), vertical: vertical)
                } second: {
                    comparePane(compare.isSwapped ? AnyView(page) : AnyView(ComparePane(session: compare)), vertical: vertical)
                }
                // Côtés échangés : les deux volets repartent à moitié chacun, au lieu de garder l'ancienne séparation.
                .id(compare.isSwapped)
            }
        } else if epub != nil, showsNotes {
            GeometryReader { geo in
                let vertical = geo.size.width < Layout.readerSplitWidth
                ReaderSplit(vertical: vertical) {
                    page
                } second: {
                    notesPanel
                        .frame(minWidth: vertical ? nil : Layout.notesPanelMin, idealWidth: vertical ? nil : Layout.notesPanel,
                               maxWidth: vertical ? nil : Layout.notesPanelMax,
                               minHeight: vertical ? Layout.notesPanelMinHeight : nil)
                }
            }
        } else {
            page
        }
    }

    /// Volet d'une comparaison : les deux livres ont la même taille minimale et prennent la place offerte.
    private func comparePane(_ content: AnyView, vertical: Bool) -> some View {
        content.frame(minWidth: vertical ? nil : Layout.readerPageMin, maxWidth: .infinity,
                      minHeight: vertical ? Layout.readerPageMinHeight : nil, maxHeight: .infinity)
    }

    // MARK: Notes de bas de page (S-103)

    private var notesPanel: some View {
        ReaderNotesPanel(model: footnotes, follows: $notesFollow, closesOnEscape: hits.isEmpty,
                         onReturn: { note in
                             guard let c = epub, let index = footnotes.referenceIndex(of: note.id) else { return }
                             footnotes.active = note.id
                             c.showReference(index)
                         },
                         onClose: { showsNotes = false })
    }

    /// Clic sur un appel de note : dans le panneau s'il est ouvert ou si la note est longue, sinon en bulle.
    /// Pendant une comparaison, toujours en bulle, dans la page où est l'appel.
    private func openFootnote(_ url: URL, label: String, rect: CGRect, in controller: EPUBPageController) {
        Task {
            guard let note = await FootnotesModel.resolve(url, label: label, root: controller.book.root) else {
                // Ancre introuvable : le lien est suivi comme un autre.
                controller.follow(url)
                return
            }
            let isMain = controller === epub
            if compare == nil, isMain, showsNotes || !(shortNotesInBubble && note.isShort) {
                showsNotes = true
                await footnotes.reloadIfNeeded(controller)
                footnotes.active = note.id
            } else {
                FootnotePopover.show(note, at: rect, in: controller.webView, openInPanel: compare == nil && isMain ? {
                    showsNotes = true
                    Task {
                        await footnotes.reloadIfNeeded(controller)
                        footnotes.active = note.id
                    }
                } : nil)
            }
        }
    }

    /// Page tournée dans le livre de la fenêtre : notes du chapitre relues ou suivies, livre d'en face synchronisé.
    private func mainMoved(_ controller: EPUBPageController) {
        compare?.moved(controller, main: controller)
        if showsNotes { refreshNotes(reload: false) }
    }

    private func refreshNotes(reload: Bool) {
        guard let c = epub else { return }
        Task {
            if reload || footnotes.chapter != c.chapter {
                footnotes.active = nil
                await footnotes.reload(c)
            } else if notesFollow {
                await footnotes.updatePage(c)
            }
        }
    }

    // MARK: Comparaison (S-104)

    /// Ouvre un autre livre en face, à la position correspondante ; le choix est repris à la prochaine ouverture.
    private func startCompare(with other: Book) {
        guard let main = epub else { return }
        let directories = library.directories
        Task { [main] in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ReaderBook.prepare(other, directories: directories)
                }.value
                let companion = EPUBPageController(book: prepared)
                companion.editable = false
                companion.apply(scale: reading.textScale(for: book), theme: reading.theme, font: reading.font)
                companion.highlights = kindle.readerHighlights(of: other)
                let session = CompareSession(book: other, controller: companion, mainWeights: main.book.weights)
                companion.onMove = { [weak session, weak main, weak companion] _ in
                    guard let session, let main, let companion else { return }
                    session.moved(companion, main: main)
                }
                companion.onNoteReference = { [weak companion] url, label, rect in
                    guard let companion else { return }
                    openFootnote(url, label: label, rect: rect, in: companion)
                }
                compare = session
                reading.setCompanion(other, for: book)
                let place = session.alignment.counterpart(chapter: main.chapter, fraction: main.fraction)
                companion.open(chapter: place.chapter, fraction: place.fraction)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Impossible d'ouvrir « \(other.title) » en face")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func stopCompare() {
        compare = nil
        reading.setCompanion(nil, for: book)
    }

    /// Synchronisation remise : le livre d'en face revient au passage de celui de la fenêtre.
    private func setLocked(_ locked: Bool) {
        guard let compare else { return }
        compare.isLocked = locked
        if locked, let main = epub { compare.moved(main, main: main) }
    }

    // MARK: Menu Lecture

    private var menuValues: ReaderMenuState.Values {
        ReaderMenuState.Values(canRead: epub != nil, showsNotes: showsNotes, isComparing: compare != nil,
                               isLocked: compare?.isLocked ?? true)
    }

    /// Remplit le menu Lecture si cette fenêtre est au premier plan, sinon le lui rend.
    private func publishMenu() {
        guard activeState == .key else {
            ReaderMenuState.shared.clear(owner: menuOwner)
            return
        }
        ReaderMenuState.shared.update(owner: menuOwner, values: menuValues, actions: ReaderMenuState.Actions(
            toggleNotes: { showsNotes.toggle() },
            chooseCompanion: { choosesCompanion = true },
            toggleLock: { setLocked(!(compare?.isLocked ?? true)) },
            swapSides: { compare?.isSwapped.toggle() },
            stopComparing: { stopCompare() }))
    }

    private var compareMenu: some View {
        Menu {
            if let compare {
                Button("Échanger les côtés") { compare.isSwapped.toggle() }
                Divider()
                Button("Comparer avec un autre livre…") { choosesCompanion = true }
                Button("Arrêter la comparaison") { stopCompare() }
            } else {
                Button("Comparer avec un autre livre…") { choosesCompanion = true }
            }
        } label: {
            // Le symbole porte le nom : dans la barre d'outils, VoiceOver lit celui du symbole sinon.
            Label { Text("Comparer") } icon: {
                Image(systemName: "rectangle.split.2x1").accessibilityLabel(Text("Comparer"))
            }
        }
        .menuIndicator(.hidden)
        .disabled(epub == nil)
        .help(compare.map { String(localized: "Comparaison avec « \($0.book.title) »") }
              ?? String(localized: "Lire en face une traduction ou une autre édition (⌥⌘C)"))
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
        switch content {
        case .epub(let c):
            ReaderBook.currentEntry(in: entries, chapter: c.chapter, page: c.page, fragmentPages: c.fragmentPages)
        case .pdf(let c): entries.last { $0.chapter <= c.page }?.id
        case nil: nil
        }
    }

    @ViewBuilder private var contents: some View {
        if entries.isEmpty {
            ContentUnavailableView("Pas de table des matières", systemImage: "list.bullet",
                                   description: Text("Ce livre n'en contient pas."))
        } else {
            List(entries, selection: Binding(get: { currentEntry }, set: { id in
                guard let entry = entries.first(where: { $0.id == id }) else { return }
                switch content {
                case .epub(let c):
                    c.open(entry)
                    focusPage(c.webView)
                case .pdf(let c):
                    c.go(to: entry.chapter)
                    focusPage(c.view)
                case nil: break
                }
            })) { entry in
                Text(entry.title.isEmpty ? String(localized: "Sans titre") : entry.title)
                    .lineLimit(2)
                    .padding(.leading, CGFloat(entry.depth) * Space.md)
                    .tag(entry.id)
            }
        }
    }

    /// Après un clic dans la table des matières, le clavier revient à la page : les flèches et Espace tournent
    /// les pages, au lieu de parcourir la liste et d'ouvrir chaque chapitre (Tab ramène dans la liste).
    private func focusPage(_ view: NSView) {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
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
        if book.format == .pdf { return String(localized: "Page \(hit.section + 1)") }
        let entry = entries.last { $0.chapter <= hit.section }
        return entry.map { $0.title.isEmpty ? String(localized: "Chapitre \(hit.section + 1)") : $0.title } ?? "Chapitre \(hit.section + 1)"
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
        ToolbarItemGroup(placement: .primaryAction) {
            // ⌥⌘N et ⌥⌘C sont dans le menu Lecture.
            Toggle(isOn: $showsNotes) { Label("Notes de bas de page", systemImage: "list.number") }
                .disabled(epub == nil || compare != nil)
                .help(compare != nil ? String(localized: "Pendant une comparaison, les notes s'ouvrent en bulle sur leur appel")
                      : String(localized: "Panneau des notes de bas de page du chapitre (⌥⌘N)"))
            compareMenu
            if let compare {
                Toggle(isOn: Binding(get: { compare.isLocked }, set: { setLocked($0) })) {
                    Label("Synchroniser les deux textes", systemImage: compare.isLocked ? "link" : "link.badge.plus")
                }
                .help(compare.isLocked ? String(localized: "Les deux textes avancent ensemble ; cliquer pour les lire séparément")
                      : String(localized: "Les deux textes avancent séparément ; cliquer pour les remettre en face"))
            }
        }
        ToolbarItem(placement: .primaryAction) { researchMenu }
        ToolbarItem(placement: .primaryAction) {
            Button { highlight() } label: { Label("Surligner", systemImage: "highlighter") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!hasSelection)
                .help("Surligner la sélection (⇧⌘H) ; un clic sur le passage surligné y ajoute une note")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { reading.reduce(book) } label: { Label("Réduire le texte", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut("-")
                    .disabled(!reading.canReduce(book))
                // Taille propre au livre (S-105) : ⌘0 le ramène à la taille par défaut.
                Button { reading.resetTextScale(for: book) } label: { Label("Taille par défaut", systemImage: "textformat.size") }
                    .keyboardShortcut("0")
                    .disabled(!reading.hasOwnScale(book))
                Button { reading.enlarge(book) } label: { Label("Agrandir le texte", systemImage: "textformat.size.larger") }
                    .keyboardShortcut("+")
                    .disabled(!reading.canEnlarge(book))
            }
            .help("Taille du texte de ce livre (⌘− / ⌘+, ⌘0 pour la taille par défaut)")
            textMenu
        }
    }

    /// Police (S-095) et fond (S-069), réunis sous une icône : deux menus déroulants se réduisaient à leurs
    /// flèches dans une fenêtre étroite. Police et fond valent pour tous les livres ; un PDF garde polices et couleurs.
    private var textMenu: some View {
        Menu {
            Picker("Police", selection: Binding(get: { reading.font }, set: { reading.font = $0 })) {
                Text(ReaderFont.book.label).tag(ReaderFont.book)
                Divider()
                ForEach(ReaderFont.serif) { Text($0.label).font($0.preview).tag($0) }
                Divider()
                ForEach(ReaderFont.sansSerif) { Text($0.label).font($0.preview).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Fond", selection: Binding(get: { reading.theme }, set: { reading.theme = $0 })) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            // La taille reste propre à chaque livre (S-105) ; celle-ci devient celle des livres jamais réglés.
            Button("Utiliser cette taille par défaut") { reading.useAsDefault(book) }
                .disabled(!reading.hasOwnScale(book))
        } label: {
            Label { Text("Police et fond") } icon: {
                Image(systemName: "textformat").accessibilityLabel(Text("Police et fond"))
            }
        }
        .menuIndicator(.hidden)
        .disabled(book.format == .pdf)
        .help(book.format == .pdf ? String(localized: "Un PDF garde ses polices et ses couleurs")
              : String(localized: "Police et fond : \(reading.font.label), \(reading.theme.label.lowercased())"))
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
            Label(researches.activeResearch(for: book)?.name ?? String(localized: "Aucune thématique"), systemImage: "tag")
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
            alert.messageText = String(localized: "Supprimer ce surlignage et sa note ?")
            alert.informativeText = String(localized: "Il disparaît aussi de « Notes et surlignages ». Le fichier du livre n'est pas modifié.")
            alert.addButton(withTitle: String(localized: "Supprimer")).hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Annuler"))
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
                failure = String(localized: "Ce PDF est illisible.")
                return
            }
            controller.actions = highlightActions
            controller.markOf = { [researches] in researches.mark(of: $0) }
            controller.onOpenNote = { openNote($0, at: $1) }
            content = .pdf(controller)
            showHighlights()
            // Après la mise en place de la vue : PDFKit ignore un saut de page fait avant.
            try? await Task.sleep(for: .milliseconds(50))
            controller.apply(scale: reading.textScale(for: book))
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
                controller.apply(scale: reading.textScale(for: book), theme: reading.theme, font: reading.font)
                controller.onMove = { [weak controller] position in
                    reading.record(position, for: book)
                    if let controller { mainMoved(controller) }
                }
                controller.onNoteReference = { [weak controller] url, label, rect in
                    guard let controller else { return }
                    openFootnote(url, label: label, rect: rect, in: controller)
                }
                controller.actions = highlightActions
                controller.markOf = { [researches] in researches.mark(of: $0) }
                controller.onOpenNote = { openNote($0, at: $1) }
                content = .epub(controller)
                showHighlights()
                // Un passage trouvé l'emporte sur la position de lecture.
                if ReaderLaunch.shared.targets[book.id] != nil { jumpToTarget() } else {
                    controller.open(chapter: start?.chapter ?? 0, fraction: start?.fraction ?? 0)
                }
                // Comparaison laissée ouverte à la dernière lecture (S-104).
                if let fingerprint = reading.companion(of: book),
                   let other = library.visibleBooks.first(where: { $0.fingerprint == fingerprint && ReaderBook.canRead($0) }) {
                    startCompare(with: other)
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
        case .epub(let c):
            if let a = target.anchor { c.open(chapter: a.chapter, start: a.start, end: a.end) }
            else { c.open(chapter: target.section, text: target.text, occurrence: target.occurrence) }
        case .pdf(let c):
            if let a = target.anchor { c.show(page: a.chapter, range: NSRange(location: a.start, length: a.end - a.start)) }
            else { c.show(page: target.section, text: target.text, occurrence: target.occurrence) }
        case nil: break
        }
    }

    private func applySettings() {
        switch content {
        case .epub(let c): c.apply(scale: reading.textScale(for: book), theme: reading.theme, font: reading.font)
        case .pdf(let c): c.apply(scale: reading.textScale(for: book))
        case nil: break
        }
        compare?.controller.apply(scale: reading.textScale(for: book), theme: reading.theme, font: reading.font)
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
