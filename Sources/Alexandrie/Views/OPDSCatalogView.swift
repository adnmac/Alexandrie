import AlexandrieCore
import SwiftUI

/// Page d'un catalogue OPDS (S-086) : chemin parcouru, puis les entrées de la page ouverte.
/// Une entrée de navigation ouvre son sous-catalogue ; un livre montre sa fiche à droite.
/// La recherche du catalogue (S-087) passe par le champ de recherche de la barre d'outils.
struct OPDSCatalogView: View {
    @Environment(OPDSStore.self) private var opds
    let catalogID: String

    var body: some View {
        VStack(spacing: 0) {
            if opds.path(catalogID).count > 1 {
                pathBar
                Divider()
            }
            content
        }
        .task(id: catalogID) { await opds.open(catalogID) }
    }

    @ViewBuilder private var content: some View {
        if opds.catalog(id: catalogID) == nil {
            ContentUnavailableView("Catalogue retiré", systemImage: "globe",
                                   description: Text("Ce catalogue n'est plus dans la liste."))
        } else if let page = opds.current(catalogID) {
            if let error = page.error {
                VStack(spacing: Space.lg) {
                    ContentUnavailableView(page.terms == nil ? "Catalogue injoignable" : "Recherche impossible",
                                           systemImage: "wifi.exclamationmark", description: Text(error))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Réessayer") { Task { await opds.reload(catalogID) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let feed = page.feed {
                if feed.entries.isEmpty {
                    ContentUnavailableView(page.terms.map { "Aucun livre pour « \($0) »" } ?? "Page vide",
                                           systemImage: "books.vertical",
                                           description: Text(page.terms == nil ? "Le catalogue n'a rien à montrer ici."
                                                             : "Essayez un autre mot, un nom d'auteur ou un titre."))
                } else {
                    entries(feed)
                }
            } else {
                ProgressView("Chargement de « \(page.title) »…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Fil d'Ariane : chaque page déjà ouverte y ramène.
    private var pathBar: some View {
        let path = opds.path(catalogID)
        return HStack(spacing: Space.xs) {
            Button {
                opds.back(catalogID, to: path.count - 2)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: .command)
            .help("Page précédente (⌘[)")
            .accessibilityLabel("Page précédente")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(Array(path.enumerated()), id: \.element.id) { index, page in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        if index == path.count - 1 {
                            Text(page.title).fontWeight(.semibold).lineLimit(1)
                        } else {
                            Button(page.title) { opds.back(catalogID, to: index) }
                                .buttonStyle(.link)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    private func entries(_ feed: OPDSFeed) -> some View {
        let selection = Binding<OPDSEntry.ID?>(
            get: { opds.selection[catalogID] },
            set: { id in
                guard let entry = feed.entries.first(where: { $0.id == id }) else { return opds.selection[catalogID] = nil }
                if entry.isBook {
                    opds.selection[catalogID] = entry.id
                } else if let url = entry.navigationURL {
                    Task { await opds.push(catalogID, url: url, title: entry.title) }
                }
            })
        return List(selection: selection) {
            if let subtitle = feed.subtitle, opds.path(catalogID).count == 1 {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(feed.entries) { entry in
                OPDSEntryRow(entry: entry, inLibrary: opds.libraryBook(for: entry) != nil)
                    .tag(entry.id)
            }
            if feed.nextURL != nil {
                HStack {
                    Spacer()
                    if opds.current(catalogID)?.loadingMore == true {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Plus de résultats") { Task { await opds.loadMore(catalogID) } }
                    }
                    Spacer()
                }
                // La page suivante arrive d'elle-même quand la fin de la liste devient visible.
                .onAppear { Task { await opds.loadMore(catalogID) } }
            }
        }
        .gridArea("catalogue")
    }
}

/// Ligne d'une entrée : couverture (livre) ou dossier (sous-catalogue), titre, auteurs, début du résumé.
struct OPDSEntryRow: View {
    let entry: OPDSEntry
    let inLibrary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            if entry.isBook || entry.thumbnailURL != nil {
                OPDSCover(entry: entry)
                    .frame(width: Layout.resultCover, height: Layout.resultCover * 3 / 2)
            } else {
                Image(systemName: "folder")
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                    .frame(width: Layout.resultCover)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(entry.title).font(.headline).lineLimit(2)
                if !entry.authors.isEmpty {
                    Text(entry.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let summary = entry.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if entry.isBook {
                    HStack(spacing: Space.sm) {
                        Text(entry.acquisitions.map(\.format.label).joined(separator: " · "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        if inLibrary {
                            Label("Dans la bibliothèque", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Palette.success)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if !entry.isBook {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.isBook ? "Montre la fiche du livre" : "Ouvre cette partie du catalogue")
    }
}

/// Couverture d'une entrée, chargée par le catalogue ; à défaut, la couverture générée de la bibliothèque.
struct OPDSCover: View {
    @Environment(OPDSStore.self) private var opds
    let entry: OPDSEntry
    @State private var local: URL?

    var body: some View {
        CoverImage(url: local, cacheKey: "opds:" + (entry.thumbnailURL?.absoluteString ?? entry.id),
                   title: entry.title, subtitle: entry.authors.joined(separator: ", ")) { EmptyView() }
            .task(id: entry.thumbnailURL) { local = await opds.cover(for: entry) }
            .accessibilityHidden(true)
    }
}

/// Fiche d'un livre du catalogue (S-088) : couverture, résumé, téléchargement dans la bibliothèque.
struct OPDSEntryDetailView: View {
    @Environment(OPDSStore.self) private var opds
    let catalogID: String

    private var entry: OPDSEntry? {
        guard let id = opds.selection[catalogID] else { return nil }
        return opds.current(catalogID)?.feed?.entries.first { $0.id == id }
    }

    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    OPDSCover(entry: entry)
                        .frame(height: Layout.detailCover)
                        .frame(maxWidth: .infinity)
                        .gridProbe("couverture", area: "fiche-catalogue")
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(entry.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                        if !entry.authors.isEmpty {
                            Text(entry.authors.joined(separator: ", ")).font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridProbe("titre", area: "fiche-catalogue")
                    actions(entry)
                        .gridProbe("actions", area: "fiche-catalogue")
                    if let summary = entry.summary {
                        Text(summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if !entry.related.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(entry.related) { related in
                                Button(related.title) {
                                    Task { await opds.push(catalogID, url: related.url, title: related.title) }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
                        info("Formats", entry.acquisitions.map(\.format.label).joined(separator: ", "))
                        if let language = entry.language { info("Langue", language) }
                        if let size = entry.acquisitions.first?.length {
                            info("Taille", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let catalog = opds.catalog(id: catalogID) { info("Catalogue", catalog.name) }
                    }
                    .font(.callout)
                    .gridProbe("details", area: "fiche-catalogue", edge: "details")
                }
                .padding(Space.margin)
                .gridArea("fiche-catalogue")
            }
            .id(entry.id)
        } else {
            ContentUnavailableView("Aucun livre choisi", systemImage: "book.closed",
                                   description: Text("Choisissez un livre du catalogue pour l'ajouter à la bibliothèque."))
        }
    }

    @ViewBuilder private func actions(_ entry: OPDSEntry) -> some View {
        let book = opds.libraryBook(for: entry)
        VStack(alignment: .leading, spacing: Space.sm) {
            if let book {
                Button {
                    opds.showRequest = book.id
                } label: {
                    Label("Afficher dans la bibliothèque", systemImage: "books.vertical").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Label("Dans la bibliothèque : sa fiche permet de le lire ou de l'envoyer sur la Kindle.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if opds.isDownloading(entry) {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Téléchargement…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: Space.section)
            } else if let first = entry.acquisitions.first {
                HStack {
                    Button {
                        Task { await opds.download(first, of: entry) }
                    } label: {
                        Label("Télécharger \(first.format.label)", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Télécharge le livre et l'ajoute à la bibliothèque, comme « Importer »")
                    if entry.acquisitions.count > 1 {
                        Menu {
                            ForEach(entry.acquisitions.dropFirst()) { other in
                                Button("Télécharger \(other.format.label)") { Task { await opds.download(other, of: entry) } }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .controlSize(.large)
                        .help("Autres formats")
                        .accessibilityLabel("Autres formats")
                    }
                }
                if let failure = opds.downloadError, failure.entry == entry.id {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                } else {
                    Text(first.format == .epub
                         ? "Le livre rejoint la bibliothèque (imports d'Alexandrie) ; il sera converti en AZW3 à l'envoi sur la Kindle."
                         : "Le livre rejoint la bibliothèque (imports d'Alexandrie).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
