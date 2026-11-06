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
                                        ? "Les surlignages et notes faits sur une Kindle sont importés à chacune de ses connexions."
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
                || b.clippings.contains { $0.displayText.localizedStandardContains(query) }
        }
    }
}

/// Colonne de droite de la vue Notes : les relevés d'un livre, filtrables, modifiables et exportables.
struct NotesEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
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
                }
                .fixedSize()
            }
            // Colonne étroite : l'ordre passe sous le filtre plutôt que d'écraser le compteur.
            ViewThatFits(in: .horizontal) {
                HStack {
                    kindPicker
                    orderPicker
                    Spacer(minLength: 8)
                    count(entry, shown: shown)
                }
                VStack(alignment: .leading, spacing: 8) {
                    kindPicker
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
        }
        .padding(Space.lg)
    }

    private var kindPicker: some View {
        Picker("Afficher", selection: $kind) { ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
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
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { list = list.filter { $0.displayText.localizedStandardContains(query) } }
        // Les relevés arrivent dans l'ordre du fichier de la Kindle, donc par date d'ajout.
        if order == .reading { list = list.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }.map(\.element) }
        return list
    }

    private func export(_ entry: ClippingBook, book: Book?, clippings: [Clipping]) {
        let title = book?.title ?? entry.title
        let panel = NSSavePanel()
        panel.title = "Exporter les notes"
        panel.nameFieldStringValue = "Notes - \(title)".safeFilename + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = KindleClippings.markdown(title: title, author: book?.authorLine ?? entry.author, clippings: clippings)
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
    let clipping: Clipping
    @State private var editing = false
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
                HStack(spacing: 8) {
                    Label((clipping.kind == .note ? "Note · " : "")
                          + [clipping.location, clipping.added].filter { !$0.isEmpty }.joined(separator: " · "),
                          systemImage: clipping.kind == .note ? "note.text" : "highlighter")
                    if clipping.isEdited { Text("· modifiée").foregroundStyle(Palette.warning) }
                    Spacer()
                    Button("Modifier") {
                        draft = clipping.displayText
                        editing = true
                    }
                    if clipping.isEdited {
                        Button("Rétablir l'original") { kindle.revertClipping(clipping.id) }
                    }
                    Button("Supprimer", role: .destructive) { confirmDelete = true }
                }
                .font(.caption).foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, Space.md)
        .confirmationDialog("Supprimer ce relevé d'Alexandrie ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { kindle.deleteClipping(clipping.id) }
        } message: {
            Text("Il disparaît d'Alexandrie et ne reviendra pas au prochain import. La Kindle n'est pas modifiée.")
        }
    }
}
