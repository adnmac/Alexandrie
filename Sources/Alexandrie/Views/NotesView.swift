import AlexandrieCore
import AppKit
import SwiftUI

/// Toutes les notes et surlignages importés des Kindle, regroupés par livre (les plus récents d'abord).
struct NotesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let search: String
    /// Sélection de la bibliothèque : choisir un livre ouvre sa fiche à droite.
    @Binding var selection: Set<String>

    private struct BookNotes: Identifiable {
        let id: String
        let title: String
        let author: String
        let book: Book?
        let clippings: [Clipping]
    }

    var body: some View {
        let groups = notesByBook
        if groups.isEmpty {
            ContentUnavailableView(search.isEmpty ? "Aucune note pour l'instant" : "Aucun résultat",
                                   systemImage: "highlighter",
                                   description: Text(search.isEmpty
                                        ? "Les surlignages et notes faits sur une Kindle sont importés à chacune de ses connexions."
                                        : "Aucune note ou surlignage ne contient « \(search) »."))
        } else {
            List {
                ForEach(groups) { g in
                    Section {
                        ForEach(g.clippings) { c in row(c) }
                    } header: {
                        header(g)
                    }
                }
            }
        }
    }

    private func header(_ g: BookNotes) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(g.title).font(.headline)
                if !g.author.isEmpty { Text(g.author).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(g.clippings.count == 1 ? "1 relevé" : "\(g.clippings.count) relevés")
                .font(.caption).foregroundStyle(.secondary)
            if let book = g.book {
                Button("Fiche") { selection = [book.id] }
                    .controlSize(.small)
                    .help("Ouvrir la fiche du livre à droite")
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ c: Clipping) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.text)
                .font(c.kind == .note ? .body.italic() : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label((c.kind == .note ? "Note · " : "") + [c.location, c.added].filter { !$0.isEmpty }.joined(separator: " · "),
                  systemImage: c.kind == .note ? "note.text" : "highlighter")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.text, forType: .string)
            }
        }
    }

    /// Relevés regroupés par livre, le livre aux relevés les plus récents en tête ; filtrés par la recherche.
    private var notesByBook: [BookNotes] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var order: [String] = []
        var grouped: [String: [Clipping]] = [:]
        for c in kindle.clippings.reversed() where c.kind != .bookmark {
            guard query.isEmpty || c.text.localizedStandardContains(query) || c.title.localizedStandardContains(query) else { continue }
            let key = ShelfSync.normalize(c.title)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(c)
        }
        return order.map { key in
            let list = grouped[key]!
            let book = library.books(titleKey: key).first { $0.trashedAt == nil }
            return BookNotes(id: key, title: book?.title ?? list[0].title, author: book?.authorLine ?? list[0].author,
                             book: book, clippings: list.reversed())
        }
    }
}
