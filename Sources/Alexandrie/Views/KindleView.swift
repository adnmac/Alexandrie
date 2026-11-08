import AlexandrieCore
import AppKit
import SwiftUI

/// Livres présents sur la liseuse branchée, présentés comme la bibliothèque.
struct KindleView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let search: String
    let gridMode: Bool
    @Binding var selection: KindleDocument.ID?
    @State private var pendingDelete: KindleDocument?
    @State private var pendingTidy: [KindleDocument] = []

    var body: some View {
        if let device = kindle.device {
            VStack(spacing: 0) {
                header(device)
                Divider()
                missingBanner
                offShelfBanner
                if documents.isEmpty {
                    ContentUnavailableView(kindle.documents.isEmpty ? "La liseuse ne contient aucun livre" : "Aucun résultat",
                                           systemImage: "books.vertical")
                } else if gridMode {
                    grid
                } else {
                    table
                }
            }
            .confirmationDialog("Supprimer « \(pendingDelete.map(title) ?? "") » de la liseuse ?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Supprimer", role: .destructive) {
                    if let doc = pendingDelete { Task { await kindle.delete(doc) } }
                }
            } message: {
                Text("Le fichier et ses données de lecture seront effacés de l'appareil. Votre bibliothèque n'est pas modifiée.")
            }
        } else {
            ContentUnavailableView {
                if let name = kindle.ejectedName {
                    Label("« \(name) » a été éjectée", systemImage: "eject.circle")
                } else {
                    Label("Aucune liseuse détectée", systemImage: "cable.connector")
                }
            } description: {
                Text(kindle.ejectedName != nil ? "Vous pouvez débrancher la liseuse en toute sécurité." : disconnectedHelp)
            } actions: {
                Button("Rechercher à nouveau") { Task { await kindle.refresh() } }
            }
        }
    }

    /// Livres de la liseuse qui ne sont plus sur l'étagère : les y remettre, ou les retirer de l'appareil.
    @ViewBuilder private var offShelfBanner: some View {
        let off = kindle.offShelfDocuments(in: library)
        if let reader = kindle.currentReader, !off.isEmpty {
            HStack(spacing: Space.md) {
                Image(systemName: "tray.and.arrow.up.fill").font(.title2).foregroundStyle(Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(off.count == 1
                         ? "1 livre de cette liseuse n'est plus sur l'étagère de « \(reader.name) »"
                         : "\(off.count) livres de cette liseuse ne sont plus sur l'étagère de « \(reader.name) »")
                        .font(.callout.weight(.semibold))
                    Text(off.prefix(3).map(\.book.title).joined(separator: " · ") + (off.count > 3 ? " …" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(off.map(\.book.title).joined(separator: "\n"))
                Spacer(minLength: 8)
                Button("Remettre sur l'étagère") {
                    library.undoable("Ajouter à l'étagère") { library.addToShelf(off.map(\.book), reader: reader.id) }
                }
                Button("Retirer de la liseuse…") { pendingTidy = off.map(\.document) }
                    .disabled(kindle.isBusy)
            }
            .banner(Palette.warning)
            .confirmationDialog(pendingTidy.count == 1 ? "Retirer ce livre de la liseuse ?" : "Retirer ces \(pendingTidy.count) livres de la liseuse ?",
                                isPresented: Binding(get: { !pendingTidy.isEmpty }, set: { if !$0 { pendingTidy = [] } })) {
                Button("Retirer de la liseuse", role: .destructive) {
                    let docs = pendingTidy
                    Task { await kindle.delete(docs) }
                }
            } message: {
                Text("Les fichiers et leurs données de lecture (position, notes sur l'appareil) seront effacés de la liseuse. Votre bibliothèque n'est pas modifiée, et les notes déjà importées restent dans Alexandrie.")
            }
            Divider()
        }
    }

    /// Livres de l'étagère absents de la liseuse branchée : mise à jour proposée, jamais imposée.
    @ViewBuilder private var missingBanner: some View {
        let missing = kindle.missingFromShelf(in: library)
        if let reader = kindle.currentReader, !missing.isEmpty {
            HStack(spacing: Space.md) {
                Image(systemName: "books.vertical.circle.fill").font(.title2).foregroundStyle(Palette.info)
                VStack(alignment: .leading, spacing: 2) {
                    Text(missing.count == 1
                         ? "1 livre de l'étagère de « \(reader.name) » n'est pas sur cette liseuse"
                         : "\(missing.count) livres de l'étagère de « \(reader.name) » ne sont pas sur cette liseuse")
                        .font(.callout.weight(.semibold))
                    Text(missing.prefix(3).map(\.title).joined(separator: " · ") + (missing.count > 3 ? " …" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(missing.map(\.title).joined(separator: "\n"))
                Spacer(minLength: 8)
                Button(missing.count == 1 ? "Envoyer" : "Envoyer les \(missing.count)") {
                    Task { await kindle.send(missing, library: library) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(kindle.isBusy)
            }
            .banner(Palette.info)
            Divider()
        }
    }

    private func header(_ device: any KindleDevice) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kindle.displayName ?? device.name).font(.title2.weight(.semibold))
                Text("\(device.connection.rawValue) · \(kindle.documents.count) livres"
                     + (kindle.freeSpace.map { " · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) libres" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let p = kindle.catalogProgress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .frame(width: 120)
                Text("Lecture des fiches \(p.done)/\(p.total)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await kindle.refresh() }
            } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
            .disabled(kindle.isBusy)
            Button {
                Task { await kindle.eject() }
            } label: {
                if kindle.isEjecting {
                    HStack(spacing: Space.sm) { ProgressView().controlSize(.small); Text("Éjection…") }
                } else {
                    Label("Éjecter", systemImage: "eject")
                }
            }
            .disabled(!kindle.canEject || kindle.isBusy)
            .help(kindle.canEject ? "Éjecter la liseuse avant de la débrancher (⌘E)"
                  : "Kindle en MTP : vous pouvez la débrancher directement")
        }
        .padding()
    }

    // MARK: - Données

    private func title(_ doc: KindleDocument) -> String { kindle.infos[doc.id]?.title ?? doc.name }

    private var documents: [KindleDocument] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let list = kindle.documents.filter { doc in
            guard !query.isEmpty else { return true }
            let info = kindle.infos[doc.id]
            return [doc.name, info?.title ?? "", info?.authorLine ?? ""].contains { $0.localizedStandardContains(query) }
        }
        return list.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }

    // MARK: - Grille et liste

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 20)], spacing: 24) {
                ForEach(documents) { doc in
                    KindleBookCard(document: doc, isSelected: selection == doc.id)
                        .onTapGesture { selection = doc.id }
                        .contextMenu { actions(doc) }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var table: some View {
        Table(documents, selection: $selection) {
            TableColumn("Titre") { d in
                HStack(spacing: Space.sm) {
                    Text(title(d)).lineLimit(1)
                    if kindle.libraryBook(for: d, in: library) != nil {
                        Image(systemName: "books.vertical.fill").foregroundStyle(.secondary).help("Dans la bibliothèque")
                    }
                }
            }
            TableColumn("Auteur") { Text(kindle.infos[$0.id]?.authorLine ?? "—").lineLimit(1) }
            TableColumn("Format") { Text(kindle.infos[$0.id]?.format ?? $0.fileExtension.uppercased()).monospaced() }
                .width(60)
            TableColumn("Taille") { Text(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)) }
                .width(70)
        }
        .contextMenu(forSelectionType: KindleDocument.ID.self) { ids in
            if let id = ids.first, let doc = kindle.documents.first(where: { $0.id == id }) { actions(doc) }
        }
    }

    @ViewBuilder private func actions(_ doc: KindleDocument) -> some View {
        if let book = kindle.libraryBook(for: doc, in: library) {
            Button("Afficher dans le Finder (bibliothèque)") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) }
        }
        Button("Supprimer de la liseuse…", role: .destructive) { pendingDelete = doc }
    }

    private var disconnectedHelp: String {
        // Texte court : il s'affiche dans la colonne étroite de la liste.
        if kindle.mtpAvailable {
            return "Branchez-la en USB et déverrouillez\u{2011}la. Fermez Android File Transfer s'il est ouvert."
        }
        return "Branchez-la en USB et déverrouillez\u{2011}la. Les Kindle récentes demandent libmtp : « brew install libmtp », puis relancez Alexandrie."
    }
}

struct KindleBookCard: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let document: KindleDocument
    let isSelected: Bool

    var body: some View {
        let info = kindle.infos[document.id]
        VStack(alignment: .leading, spacing: Space.sm) {
            CoverImage(url: info.flatMap(kindle.catalog.coverURL), cacheKey: info?.coverKey ?? document.id,
                       title: info?.title ?? document.name, subtitle: info?.authorLine ?? "") {
                RoundedRectangle(cornerRadius: Radius.cover)
                    .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 3)  // grid: ok épaisseur de trait, pas un espacement
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 4) {
                            if info?.isDRMProtected == true {
                                Image(systemName: "lock.fill").font(.caption)
                                    .padding(4).background(.ultraThinMaterial, in: Circle())
                                    .help("Protégé par DRM")
                            }
                            if kindle.libraryBook(for: document, in: library) != nil {
                                Image(systemName: "books.vertical.fill").font(.caption)
                                    .padding(4).background(.ultraThinMaterial, in: Circle())
                                    .help("Aussi dans la bibliothèque")
                            }
                        }
                        .padding(Space.sm)
                    }
            }
            .frame(height: 200)
            .overlay {
                if info == nil { ProgressView().controlSize(.small) }
            }
            // Format entre la couverture et le titre, comme dans la bibliothèque.
            Text(info?.format ?? document.fileExtension.uppercased())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, Space.sm).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .lineLimit(1)
            Text(info?.title ?? document.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(info?.authorLine ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct KindleBookDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let document: KindleDocument
    @State private var isEditing = false

    var body: some View {
        let info = kindle.infos[document.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoverImage(url: info.flatMap(kindle.catalog.coverURL), cacheKey: info?.coverKey ?? document.id,
                           title: info?.title ?? document.name, subtitle: info?.authorLine ?? "")
                    .frame(height: 280)
                    .frame(maxWidth: .infinity)
                Text(info?.title ?? document.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(info?.authorLine ?? "").foregroundStyle(.secondary)

                if let info {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Corriger les informations…", systemImage: "pencil")
                    }
                    .disabled(!KindleEditor.canEdit(document, info: info) || kindle.isBusy)
                    .help(KindleEditor.canEdit(document, info: info) ? "Réécrire titre, auteurs, date… dans le fichier sur la liseuse"
                          : "Non modifiable : format \(info.format) ou livre protégé par DRM")
                    .sheet(isPresented: $isEditing) {
                        KindleEditSheet(document: document, info: info)
                    }
                }

                if info?.isDRMProtected == true {
                    Label("Protégé par DRM (livre acheté) : lisible sur la liseuse, non convertible.", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(Palette.warning)
                }
                if info?.isGuessed == true {
                    Label("Format \(document.fileExtension.uppercased()) non analysable : titre déduit du nom de fichier.",
                          systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let book = kindle.libraryBook(for: document, in: library) {
                    Label("Aussi dans la bibliothèque (\(book.format.label))", systemImage: "books.vertical.fill")
                        .font(.callout)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
                    row("Format", info?.format ?? document.fileExtension.uppercased())
                    row("Taille", ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))
                    if let l = info?.language { row("Langue", l) }
                    if let p = info?.publisher { row("Éditeur", p) }
                    if let d = info?.publishedDate { row("Publication", d) }
                    if let t = info?.cdeType { row("Type", Self.typeLabel(t)) }
                    if let a = info?.asin { row("ASIN", a) }
                    row("Emplacement", "documents/" + document.path)
                }
                .font(.callout)

                if let summary = info?.summary {
                    Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(20)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    static func typeLabel(_ cde: String) -> String {
        switch cde {
        case "EBOK": "Livre (EBOK)"
        case "PDOC": "Document personnel (PDOC)"
        case "EBSP": "Extrait (EBSP)"
        default: cde
        }
    }
}
