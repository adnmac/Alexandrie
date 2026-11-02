import AlexandrieCore
import AppKit
import SwiftUI

/// Livres présents sur la Kindle branchée, présentés comme la bibliothèque.
struct KindleView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let search: String
    let gridMode: Bool
    @Binding var selection: KindleDocument.ID?
    @State private var pendingDelete: KindleDocument?

    var body: some View {
        if let device = kindle.device {
            VStack(spacing: 0) {
                header(device)
                Divider()
                if documents.isEmpty {
                    ContentUnavailableView(kindle.documents.isEmpty ? "La Kindle ne contient aucun livre" : "Aucun résultat",
                                           systemImage: "books.vertical")
                } else if gridMode {
                    grid
                } else {
                    table
                }
            }
            .confirmationDialog("Supprimer « \(pendingDelete.map(title) ?? "") » de la Kindle ?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Supprimer", role: .destructive) {
                    if let doc = pendingDelete { Task { await kindle.delete(doc) } }
                }
            } message: {
                Text("Le fichier et ses données de lecture seront effacés de l'appareil. Votre bibliothèque n'est pas modifiée.")
            }
        } else {
            ContentUnavailableView {
                Label("Aucune Kindle détectée", systemImage: "cable.connector")
            } description: {
                Text(disconnectedHelp)
            } actions: {
                Button("Rechercher à nouveau") { Task { await kindle.refresh() } }
            }
        }
    }

    private func header(_ device: any KindleDevice) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.title2.weight(.semibold))
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
                HStack(spacing: 6) {
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
        Button("Supprimer de la Kindle…", role: .destructive) { pendingDelete = doc }
    }

    private var disconnectedHelp: String {
        var s = "Branchez votre Kindle au Mac avec un câble USB et déverrouillez-la."
        if kindle.mtpAvailable {
            s += "\nLes Kindle récentes (MTP) sont détectées automatiquement ; fermez Android File Transfer s'il est ouvert."
        } else {
            s += "\nLes Kindle récentes (depuis fin 2024) utilisent le protocole MTP : installez libmtp avec « brew install libmtp » puis relancez Alexandrie."
        }
        return s
    }
}

struct KindleBookCard: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let document: KindleDocument
    let isSelected: Bool

    var body: some View {
        let info = kindle.infos[document.id]
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: info.flatMap(kindle.catalog.coverURL), cacheKey: info?.coverKey ?? document.id,
                       title: info?.title ?? document.name, subtitle: info?.authorLine ?? "")
                .frame(height: 200)
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
                    .padding(6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay {
                    if info == nil { ProgressView().controlSize(.small) }
                }
            // Format entre la couverture et le titre, comme dans la bibliothèque.
            Text(info?.format ?? document.fileExtension.uppercased())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
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
                    .help(KindleEditor.canEdit(document, info: info) ? "Réécrire titre, auteurs, date… dans le fichier sur la Kindle"
                          : "Non modifiable : format \(info.format) ou livre protégé par DRM")
                    .sheet(isPresented: $isEditing) {
                        KindleEditSheet(document: document, info: info)
                    }
                }

                if info?.isDRMProtected == true {
                    Label("Protégé par DRM (livre acheté) : lisible sur la Kindle, non convertible.", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.orange)
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

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
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
