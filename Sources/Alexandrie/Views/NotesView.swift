import AlexandrieCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Colonne centrale de la vue Notes : les livres annotés, le plus récemment annoté en tête.
struct NotesBookList: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let search: String
    @Binding var selection: String?

    /// « 2 surl. · 1 note » : chaque partie seulement si elle n'est pas vide, au singulier pour 1.
    static func countLine(highlights: Int, notes: Int) -> String {
        [highlights > 0 ? "\(highlights) surl." : nil, notes > 0 ? (notes == 1 ? "1 note" : "\(notes) notes") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let books = filtered
        if books.isEmpty {
            ContentUnavailableView(search.isEmpty ? "Aucune note pour l'instant" : "Aucun résultat",
                                   systemImage: "highlighter",
                                   description: Text(search.isEmpty
                                        ? "Les surlignages et notes faits sur une Kindle sont importés à chacune de ses connexions ; ceux faits dans la fenêtre de lecture s'y ajoutent."
                                        : "Aucun livre ni aucune note ne contient « \(search) »."))
        } else {
            List(books, selection: $selection) { b in
                let book = library.books(titleKey: b.id).first { $0.trashedAt == nil }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book?.title ?? b.title).lineLimit(2)
                    HStack {
                        Text(book?.authorLine ?? b.author).lineLimit(1)
                        Spacer()
                        let notes = b.clippings.filter { $0.kind == .note }.count
                        Text(Self.countLine(highlights: b.clippings.count - notes, notes: notes))
                            .monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(b.id)
            }
        }
    }

    private var filtered: [ClippingBook] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let all = kindle.clippingBooks
        guard !query.isEmpty else { return all }
        return all.filter { b in
            b.title.localizedStandardContains(query) || b.author.localizedStandardContains(query)
                || b.clippings.contains { $0.matches(query) }
        }
    }
}

/// Colonne de droite de la vue Notes : les relevés d'un livre, filtrables, modifiables et exportables.
struct NotesEditor: View {
    @Environment(ZoteroStore.self) private var zotero
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(ResearchStore.self) private var researches
    let bookKey: String

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "Tout", highlights = "Surlignages", notes = "Notes"
        var id: Self { self }
    }

    enum Order: String, CaseIterable, Identifiable {
        case reading = "Ordre de lecture", added = "Date d'ajout"
        var id: Self { self }
    }

    @State private var kind: KindFilter = .all
    @State private var order: Order = .reading
    @State private var filter = ""
    /// Couleurs (teintes « #RRGGBB ») et thématiques gardées (S-074, S-079), retenues d'un livre et d'un
    /// lancement à l'autre ; vide = toutes.
    @AppStorage("notesHues") private var storedColors = ""
    @AppStorage("notesThematics") private var storedThematics = ""
    @State private var managesResearches = false

    private var colors: Set<String> {
        get { Set(storedColors.split(separator: ",").map(String.init)) }
        nonmutating set { storedColors = newValue.sorted().joined(separator: ",") }
    }

    private var thematics: Set<String> {
        get { Set(storedThematics.split(separator: ",").map(String.init)) }
        nonmutating set { storedThematics = newValue.sorted().joined(separator: ",") }
    }

    var body: some View {
        if let entry = kindle.clippingBooks.first(where: { $0.id == bookKey }) {
            let book = library.books(titleKey: bookKey).first { $0.trashedAt == nil }
            let shown = visible(entry.clippings)
            VStack(spacing: 0) {
                header(entry, book: book, shown: shown)
                Divider()
                if shown.isEmpty {
                    ContentUnavailableView("Aucune note ne correspond", systemImage: "line.3.horizontal.decrease.circle")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { c in
                                NoteRow(clipping: c)
                                Divider()
                            }
                        }
                        .padding(.horizontal, Space.lg)
                    }
                }
            }
        } else {
            ContentUnavailableView("Choisissez un livre", systemImage: "highlighter",
                                   description: Text("Ses notes et surlignages s'afficheront ici."))
        }
    }

    private func header(_ entry: ClippingBook, book: Book?, shown: [Clipping]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book?.title ?? entry.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text((book?.authorLine ?? entry.author) + " · \(entry.clippings.count) relevés")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Exporter") {
                    Button("Copier tout (\(shown.count))") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shown.map(\.displayText).joined(separator: "\n\n"), forType: .string)
                    }
                    Button("Enregistrer en Markdown…") { export(entry, book: book, clippings: shown) }
                    Divider()
                    // Tous les relevés du livre, quels que soient les filtres : la note Zotero reste complète.
                    Button("Envoyer à Zotero") { Task { await zotero.send(bookKey: entry.id) } }
                        .disabled(zotero.sending != nil)
                }
                .fixedSize()
                .help("Copier, enregistrer en Markdown, ou envoyer tous les relevés du livre à Zotero (une note rattachée à sa référence)")
                if zotero.sending != nil { ProgressView().controlSize(.small).help("Envoi à Zotero…") }
            }
            // Colonne étroite : l'ordre passe sous le filtre plutôt que d'écraser le compteur.
            ViewThatFits(in: .horizontal) {
                HStack {
                    kindPicker
                    thematicMenu(entry)
                    colorMenu(entry)
                    orderPicker
                    Spacer(minLength: 8)
                    count(entry, shown: shown)
                }
                VStack(alignment: .leading, spacing: 8) {
                    kindPicker
                    HStack {
                        thematicMenu(entry)
                        colorMenu(entry)
                        orderPicker
                        Spacer(minLength: 8)
                        count(entry, shown: shown)
                    }
                }
                // Colonne étroite : les filtres sur une ligne, l'ordre et le compteur sur la suivante.
                VStack(alignment: .leading, spacing: 8) {
                    kindPicker
                    HStack {
                        thematicMenu(entry)
                        colorMenu(entry)
                    }
                    HStack {
                        orderPicker
                        Spacer(minLength: 8)
                        count(entry, shown: shown)
                    }
                }
            }
            .controlSize(.small)
            TextField("Filtrer ces notes", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            // Filtres gardés d'une fois à l'autre : ce qu'ils cachent se voit, et se rend d'un clic.
            let hidden = entry.clippings.count - shown.count
            if hidden > 0 {
                HStack(spacing: Space.sm) {
                    Label("\(hidden) relevé\(hidden > 1 ? "s" : "") masqué\(hidden > 1 ? "s" : "") par les filtres",
                          systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Tout afficher") {
                        kind = .all
                        thematics = []
                        colors = []
                        filter = ""
                    }
                    .controlSize(.small)
                    .help("Retirer les filtres de type, de thématique, de couleur et de texte")
                }
            }
        }
        .padding(Space.lg)
    }

    private var kindPicker: some View {
        Picker("Afficher", selection: $kind) { ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    /// Thématique qui nomme les couleurs : la seule choisie dans le filtre, sinon celles de chaque surlignage.
    private var namingThematic: String? {
        let chosen = thematics.subtracting([KindleClippings.noThematic])
        return chosen.count == 1 ? chosen.first : nil
    }

    /// Couleurs des surlignages de ce livre (S-074, S-079), nommées ; les couleurs de base d'abord.
    private func marks(_ entry: ClippingBook) -> [HighlightMark] {
        var seen = Set<String>()
        let used = entry.clippings.filter { $0.kind == .highlight }
            .map { researches.mark(of: $0, in: namingThematic) }.filter { seen.insert($0.key).inserted }
        let base = HighlightColor.allCases.map(\.hex)
        return used.sorted { (base.firstIndex(of: $0.key) ?? .max, $0.label) < (base.firstIndex(of: $1.key) ?? .max, $1.label) }
    }

    /// Thématiques des surlignages de ce livre.
    private func thematicsOf(_ entry: ClippingBook) -> [Research] {
        let used = Set(entry.clippings.flatMap(\.thematicIDs))
        return researches.researches.filter { used.contains($0.id) }
    }

    /// Couleurs gardées dans la liste, la copie et l'export (S-074) : toutes, une ou plusieurs.
    private func colorMenu(_ entry: ClippingBook) -> some View {
        let available = marks(entry)
        return Menu {
            Button {
                colors = []
            } label: {
                if colors.isEmpty { Label("Toutes les couleurs", systemImage: "checkmark") } else { Text("Toutes les couleurs") }
            }
            Divider()
            ForEach(available) { mark in
                Toggle(isOn: Binding(get: { colors.contains(mark.key) }, set: { on in
                    if on { colors.insert(mark.key) } else { colors.remove(mark.key) }
                })) {
                    Label { Text(mark.label) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(mark.swatch)
                    }
                }
            }
        } label: {
            Text(title(available.filter { colors.contains($0.key) }.map(\.label), none: "Couleurs", many: "couleurs"))
        }
        .fixedSize()
        .help("Couleurs gardées dans la liste, la copie et l'export ; les notes seules de la Kindle n'ont pas de couleur")
    }

    /// Thématiques gardées (S-079) : une seule nomme aussi les couleurs selon sa légende.
    private func thematicMenu(_ entry: ClippingBook) -> some View {
        let available = thematicsOf(entry)
        return Menu {
            Button {
                thematics = []
            } label: {
                if thematics.isEmpty { Label("Toutes les thématiques", systemImage: "checkmark") } else { Text("Toutes les thématiques") }
            }
            if !available.isEmpty { Divider() }
            ForEach(available) { thematic in
                Toggle(thematic.name, isOn: Binding(get: { thematics.contains(thematic.id) }, set: { on in
                    if on { thematics.insert(thematic.id) } else { thematics.remove(thematic.id) }
                }))
            }
            // Passages qu'aucune thématique ne range : à voir à part, ou avec une thématique.
            if entry.clippings.contains(where: { $0.thematicIDs.isEmpty }) {
                Toggle("Sans thématique", isOn: Binding(get: { thematics.contains(KindleClippings.noThematic) }, set: { on in
                    if on { thematics.insert(KindleClippings.noThematic) } else { thematics.remove(KindleClippings.noThematic) }
                }))
            }
            Divider()
            Button("Gérer les thématiques…") { managesResearches = true }
        } label: {
            let names = available.filter { thematics.contains($0.id) }.map(\.name)
                + (thematics.contains(KindleClippings.noThematic) ? ["Sans thématique"] : [])
            Text(title(names, none: "Thématiques", many: "thématiques"))
        }
        .fixedSize()
        .help("Thématiques gardées dans la liste, la copie et l'export ; une seule nomme les couleurs selon sa légende")
        .sheet(isPresented: $managesResearches) { ResearchesSheet() }
    }

    private func title(_ chosen: [String], none: String, many: String) -> String {
        switch chosen.count {
        case 0: none
        case 1: chosen[0]
        default: "\(chosen.count) \(many)"
        }
    }

    private var orderPicker: some View {
        Picker("Ordre", selection: $order) { ForEach(Order.allCases) { Text($0.rawValue).tag($0) } }
            .labelsHidden().fixedSize()
    }

    private func count(_ entry: ClippingBook, shown: [Clipping]) -> some View {
        Text(shown.count == entry.clippings.count ? "\(shown.count) relevés" : "\(shown.count) sur \(entry.clippings.count)")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }

    private func visible(_ clippings: [Clipping]) -> [Clipping] {
        var list = clippings
        switch kind {
        case .all: break
        case .highlights: list = list.filter { $0.kind == .highlight }
        case .notes: list = list.filter { $0.kind == .note }
        }
        // Un choix fait pour un autre livre n'efface pas tout : seuls comptent les couleurs et thématiques de ce livre.
        // « Sans thématique » ne compte que si l'autre choix filtre quelque chose ou si le livre a des relevés sans thématique.
        let present = Set(list.flatMap(\.thematicIDs)).union(list.contains { $0.thematicIDs.isEmpty } ? [KindleClippings.noThematic] : [])
        let ids = thematics.intersection(present)
        list = KindleClippings.withThematics(list, ids)
        let keys = colors.intersection(list.filter { $0.kind == .highlight }.map(\.colorHex))
        list = KindleClippings.withMarks(list, keys, mark: \.colorHex)
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { list = list.filter { $0.matches(query) } }
        // Les relevés arrivent dans l'ordre du fichier de la Kindle, donc par date d'ajout.
        if order == .reading { list = KindleClippings.readingOrder(list) }
        return list
    }

    private func export(_ entry: ClippingBook, book: Book?, clippings: [Clipping]) {
        let title = book?.title ?? entry.title
        let panel = NSSavePanel()
        panel.title = "Exporter les notes"
        panel.nameFieldStringValue = "Notes - \(title)".safeFilename + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Chaque surlignage nommé par sa couleur (catégorie de sa thématique), sauf le jaune sans thématique.
        let naming = namingThematic
        let md = KindleClippings.markdown(title: title, author: book?.authorLine ?? entry.author, clippings: clippings) { c in
            let mark = researches.mark(of: c, in: naming)
            return c.thematicIDs.isEmpty && mark.key == HighlightColor.yellow.hex ? nil : mark.label
        }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            kindle.lastError = "Export impossible : \(error.localizedDescription)"
        }
    }
}

/// Un relevé : lecture, modification sur place, retour au texte d'origine, suppression.
struct NoteRow: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(ResearchStore.self) private var researches
    @Environment(LibraryStore.self) private var library
    let clipping: Clipping

    /// Livre d'un surlignage fait dans l'app, s'il est encore dans la bibliothèque (S-072). Un relevé de la
    /// Kindle n'a pas de position fiable : il n'en a pas.
    private var readerBook: Book? {
        guard let anchor = clipping.anchor else { return nil }
        return library.visibleBooks.first { $0.fingerprint == anchor.book }
    }

    /// Ouvre la fenêtre de lecture au passage, sélectionné (S-072).
    private func openInReader() {
        guard let book = readerBook, let anchor = clipping.anchor else { return }
        ReaderLaunch.shared.open(book, at: ReaderTarget(anchor: anchor, text: clipping.text))
    }
    @State private var editing = false
    @State private var editingNote = false
    @State private var draft = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if editing {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 88)
                    .overlay(RoundedRectangle(cornerRadius: Radius.field).strokeBorder(.quaternary))
                HStack {
                    if clipping.isEdited {
                        Text("Texte d'origine : « \(clipping.text) »").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Annuler") { editing = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Enregistrer") {
                        kindle.editClipping(clipping.id, text: draft)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .controlSize(.small)
            } else {
                Text(clipping.displayText)
                    .font(clipping.kind == .note ? .body.italic() : .body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if editingNote {
                    HighlightNoteEditor(clipping: clipping) { editingNote = false }
                } else if let note = clipping.note, clipping.hasNote {
                    // Note du surlignage (S-071), sous son passage.
                    Label {
                        Text(note).italic().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Note : \(note)")
                }
                // Infos sur toute la largeur, actions en dessous : une colonne étroite ne les casse plus.
                VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    // Thème nommé (S-077) : « Anthropologie · chapitre 2 · … ».
                    // Couleur nommée et thématiques (S-079) : « Construction · Voiries · chapitre 2 · … ».
                    let theme = clipping.kind == .highlight && !clipping.thematicIDs.isEmpty
                        ? ([researches.mark(of: clipping).label] + researches.thematicNames(of: clipping)).joined(separator: " · ") : ""
                    let meta = (clipping.kind == .note ? "Note · " : "")
                        + [theme, clipping.location, clipping.added].filter { !$0.isEmpty }.joined(separator: " · ")
                    Label {
                        // Fait dans la fenêtre de lecture (S-070) : marqué « Alexandrie », pas « Kindle ».
                        if clipping.isFromApp {
                            Text("\(Text("Alexandrie").fontWeight(.semibold)) · \(meta)")
                                .help("Surligné dans la fenêtre de lecture d'Alexandrie, pas sur la Kindle")
                        } else {
                            Text(meta)
                        }
                    } icon: {
                        // Surlignage : à sa couleur (S-073).
                        if clipping.kind == .note {
                            Image(systemName: "note.text")
                        } else {
                            Image(systemName: "highlighter").foregroundStyle(researches.mark(of: clipping).swatch)
                        }
                    }
                    if clipping.isEdited { Text("· modifiée").foregroundStyle(Palette.warning) }
                }
                HStack(spacing: Space.sm) {
                    Spacer()
                    if clipping.isFromApp {
                        Button(action: openInReader) { Label("Lire", systemImage: "book") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.hover)
                            .disabled(readerBook == nil)
                            .help(readerBook == nil ? "Le livre n'est plus dans la bibliothèque"
                                  : "Ouvrir la fenêtre de lecture à ce passage")
                    }
                    if clipping.kind == .highlight && !editingNote {
                        Button(clipping.hasNote ? "Modifier la note" : "Ajouter une note") { editingNote = true }
                            .buttonStyle(.hover)
                            .fixedSize()
                            .help(clipping.isFromApp ? "Note visible aussi dans la fenêtre de lecture"
                                  : "Note gardée dans Alexandrie ; la Kindle n'est pas modifiée")
                    }
                    Menu {
                        if clipping.isFromApp {
                            Button("Lire ce passage", action: openInReader).disabled(readerBook == nil)
                            Divider()
                        }
                        Button("Modifier le texte") {
                            draft = clipping.displayText
                            editing = true
                        }
                        if clipping.isEdited {
                            Button("Rétablir l'original") { kindle.revertClipping(clipping.id) }
                        }
                        if clipping.kind == .highlight {
                            Picker("Couleur", selection: Binding(get: { researches.mark(of: clipping).key }, set: { key in
                                if let mark = researches.marks(for: clipping).first(where: { $0.key == key }) {
                                    researches.apply(mark, to: clipping.id)
                                }
                            })) {
                                ForEach(researches.marks(for: clipping)) { Text($0.label).tag($0.key) }
                            }
                            if !researches.researches.isEmpty {
                                Menu("Thématiques") {
                                    ForEach(researches.researches) { thematic in
                                        Toggle(thematic.name, isOn: Binding(get: { clipping.thematicIDs.contains(thematic.id) }, set: { on in
                                            researches.setThematic(thematic.id, on: on, for: clipping.id)
                                        }))
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Supprimer…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Autres actions")
                    .accessibilityLabel("Autres actions")
                }
                }
                .font(.caption).foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, Space.md)
        .confirmationDialog(clipping.isFromApp ? "Supprimer ce surlignage ?" : "Supprimer ce relevé d'Alexandrie ?",
                            isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { kindle.deleteClipping(clipping.id) }
        } message: {
            Text(clipping.isFromApp
                 ? "Il disparaît aussi de la fenêtre de lecture. Le fichier du livre n'est pas modifié."
                 : "Il disparaît d'Alexandrie et ne reviendra pas au prochain import. La Kindle n'est pas modifiée.")
        }
    }
}
