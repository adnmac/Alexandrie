import AlexandrieCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Page d'une thématique (S-080) : toutes ses notes et surlignages, de tous les livres de la bibliothèque,
/// triés par couleur nommée, par livre ou par date, filtrables par couleur et exportables dans cet ordre.
struct ThematicNotesView: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(ResearchStore.self) private var researches
    @Environment(ZoteroStore.self) private var zotero
    let thematicID: String
    /// Recherche de la barre d'outils : filtre aussi les passages.
    let search: String
    /// Livre dont la fiche est affichée à droite (titre normalisé).
    @Binding var selectedBook: String?
    @AppStorage("thematicOrder") private var order: ThematicOrder = .color
    @State private var colors: Set<String> = []
    @State private var filter = ""
    @State private var managesThematics = false

    var body: some View {
        if let research = researches.research(id: thematicID) {
            let sections = ResearchExport.sections(research, clippings: shownClippings(research), order: order)
            let total = researches.highlightCount(research: research.id)
            VStack(spacing: 0) {
                header(research, sections: sections, total: total)
                Divider()
                if sections.isEmpty {
                    ContentUnavailableView(total == 0 ? String(localized: "Aucun passage") : String(localized: "Aucun passage ne correspond"),
                                           systemImage: total == 0 ? "tag" : "line.3.horizontal.decrease.circle",
                                           description: Text(total == 0
                                               ? String(localized: "Choisissez « \(research.name) » dans la fenêtre de lecture, ou cochez-la sur un passage, pour l'y ranger.")
                                               : String(localized: "Changez les couleurs gardées ou la recherche.")))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.clippings) { c in
                                        passage(c)
                                        Divider()
                                    }
                                } header: {
                                    if !section.title.isEmpty { sectionHeader(section) }
                                }
                            }
                        }
                        .padding(.horizontal, Space.lg)
                    }
                }
            }
            .sheet(isPresented: $managesThematics) { ResearchesSheet(selected: research.id) }
        } else {
            ContentUnavailableView("Thématique introuvable", systemImage: "tag",
                                   description: Text("Elle a été supprimée."))
        }
    }

    // MARK: En-tête

    private func header(_ research: Research, sections: [ThematicSection], total: Int) -> some View {
        let shown = sections.reduce(0) { $0 + $1.clippings.count }
        let books = Set(sections.flatMap(\.clippings).map { ShelfSync.normalize($0.title) }).count
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(research.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(verbatim: (shown == total ? String(localized: "\(total) passages")
                                    : String(localized: "\(shown) sur \(total) passages"))
                         + " · " + String(localized: "\(books) livres"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Exporter") {
                    Button("Copier tout (\(shown))") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            ResearchExport.markdown(research, clippings: shownClippings(research), order: order), forType: .string)
                    }
                    Button("Enregistrer en Markdown…") { export(research) }
                    Divider()
                    Button("Envoyer à Zotero") { Task { await zotero.send(thematicID: research.id) } }
                        .disabled(zotero.sending != nil)
                }
                .fixedSize()
                .help("Copier ou enregistrer dans l'ordre et avec les couleurs choisis ; Zotero reçoit une note par livre, rattachée à sa référence")
                if zotero.sending != nil { ProgressView().controlSize(.small).help("Envoi à Zotero…") }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    orderPicker
                    colorMenu(research)
                    Spacer(minLength: Space.sm)
                    legendButton
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    orderPicker
                    HStack {
                        colorMenu(research)
                        Spacer(minLength: Space.sm)
                        legendButton
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

    private var orderPicker: some View {
        Picker("Trier", selection: $order) { ForEach(ThematicOrder.allCases) { Text($0.label).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private var legendButton: some View {
        Button("Légende…") { managesThematics = true }
            .help("Nommer les couleurs de cette thématique")
    }

    /// Couleurs gardées : celles de la légende présentes dans la thématique, par leur nom.
    private func colorMenu(_ research: Research) -> some View {
        let all = ResearchExport.sections(research, clippings: kindle.clippings, order: .color)
        return Menu {
            Button {
                colors = []
            } label: {
                if colors.isEmpty { Label("Toutes les couleurs", systemImage: "checkmark") } else { Text("Toutes les couleurs") }
            }
            Divider()
            ForEach(all) { section in
                Toggle(isOn: Binding(get: { colors.contains(section.id) }, set: { on in
                    if on { colors.insert(section.id) } else { colors.remove(section.id) }
                })) {
                    Label { Text("\(section.title) (\(section.clippings.count))") } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(HighlightMark(hex: section.id, label: "").swatch)
                    }
                }
            }
        } label: {
            let chosen = all.filter { colors.contains($0.id) }.map(\.title)
            Text(chosen.isEmpty ? String(localized: "Couleurs") : chosen.count == 1 ? chosen[0] : String(localized: "\(chosen.count) couleurs"))
        }
        .fixedSize()
        .help("Couleurs gardées dans la liste, la copie et l'export")
    }

    // MARK: Passages

    private func sectionHeader(_ section: ThematicSection) -> some View {
        HStack(spacing: Space.sm) {
            if let hex = section.hex {
                Circle()
                    .fill(HighlightMark(hex: hex, label: "").swatch)
                    .frame(width: Layout.colorSwatch, height: Layout.colorSwatch)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(section.title).font(.headline).lineLimit(1)
            Text("\(section.clippings.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityAddTraits(.isHeader)
    }

    /// Un passage, précédé de son livre quand la page n'est pas triée par livre ; un clic sur le livre montre sa fiche.
    private func passage(_ c: Clipping) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if order != .book {
                Button {
                    selectedBook = ShelfSync.normalize(c.title)
                } label: {
                    Label(c.title + (c.author.isEmpty ? "" : " — \(c.author)"), systemImage: "book.closed")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.top, Space.md)
                .help("Montrer la fiche du livre")
            }
            NoteRow(clipping: c)
        }
        .onTapGesture(count: 1) { if order == .book { selectedBook = ShelfSync.normalize(c.title) } }
    }

    /// Passages gardés : couleurs choisies et recherche (champ de la page et barre d'outils).
    private func shownClippings(_ research: Research) -> [Clipping] {
        var list = kindle.clippings.filter { $0.thematicIDs.contains(research.id) }
        if !colors.isEmpty { list = list.filter { colors.contains($0.colorHex) } }
        for query in [filter, search].map({ $0.trimmingCharacters(in: .whitespaces) }) where !query.isEmpty {
            list = list.filter { $0.matches(query) || $0.title.localizedStandardContains(query) }
        }
        return list
    }

    private func export(_ research: Research) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Exporter la thématique")
        panel.nameFieldStringValue = research.name.safeFilename + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ResearchExport.markdown(research, clippings: shownClippings(research), order: order)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            kindle.lastError = String(localized: "Export impossible : \(error.localizedDescription)")
        }
    }
}
