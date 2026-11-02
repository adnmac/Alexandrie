import AlexandrieCore
import AppKit
import SwiftUI

struct BookDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @State private var draft: Book
    /// Tous les fichiers du même livre (lui compris).
    let files: [Book]

    init(book: Book, files: [Book] = []) {
        _draft = State(initialValue: book)
        self.files = files
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CoverView(book: draft)
                    .frame(height: 280)
                    .frame(maxWidth: .infinity)

                transferStatus

                HStack {
                    Button {
                        Task { await kindle.send([draft], library: library) }
                    } label: {
                        Label("Envoyer à la Kindle", systemImage: "arrow.down.to.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!kindle.isConnected || kindle.isBusy || (draft.isDRMProtected && draft.format == .epub))
                    Menu {
                        BookActions(book: draft)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.large)
                }
                if !kindle.isConnected {
                    Text("Branchez votre Kindle par câble USB pour l'envoyer.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if draft.format == .epub {
                    Text("Sera converti en AZW3 avant l'envoi (la Kindle ne lit pas l'EPUB par USB).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.isDRMProtected {
                    Label("Ce livre est protégé par DRM : il ne peut pas être converti.", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.orange)
                }

                Form {
                    Section {
                        MetadataFields(edits: $draft.edits)
                        TextField("Étiquettes", text: tagsBinding, prompt: Text("Séparées par des virgules"))
                    } header: {
                        Text("Informations")
                    } footer: {
                        Text("Corrections enregistrées dans Alexandrie et appliquées aux copies envoyées sur la Kindle. Le fichier d'origine n'est jamais modifié.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, -20)
                .onChange(of: draft) { _, new in library.update(new, propagatingTo: files.map(\.id)) }

                if let hint = draft.seriesHint { seriesHintBox(hint) }

                CatalogSection(book: $draft)

                if files.count > 1 { filesSection }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    info("Format", draft.format.label)
                    info("Taille", ByteCountFormatter.string(fromByteCount: draft.fileSize, countStyle: .file))
                    info("Ajouté le", draft.addedAt.formatted(date: .long, time: .omitted))
                    if let sent = draft.lastSentAt { info("Envoyé le", sent.formatted(date: .long, time: .shortened)) }
                    info("Emplacement", draft.isImported ? "Imports d'Alexandrie" : draft.path)
                }
                .font(.callout)
            }
            .padding(20)
        }
        .onChange(of: library.book(id: draft.id)) { _, new in
            // Mise à jour externe (envoi terminé, rescan) sans écraser une saisie en cours.
            guard let new else { return }
            if new.lastSentAt != draft.lastSentAt { draft.lastSentAt = new.lastSentAt; draft.sentFilename = new.sentFilename }
            if new.catalogCheckedAt != draft.catalogCheckedAt {
                draft.catalogRecord = new.catalogRecord
                draft.catalogCheckedAt = new.catalogCheckedAt
                draft.catalogDismissed = new.catalogDismissed
            }
        }
    }

    /// Série et numéro lus dans le titre, à valider.
    private func seriesHintBox(_ hint: SeriesNames.TitleHint) -> some View {
        let series = hint.series ?? draft.series ?? ""
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Le titre indique la série « \(series) », n° \(SeriesNames.format(hint.index)).")
                HStack {
                    Button("Appliquer") { applySeries(hint, cleanTitle: false) }
                        .buttonStyle(.borderedProminent)
                    if hint.title != draft.title {
                        Button("Appliquer et titrer « \(hint.title) »") { applySeries(hint, cleanTitle: true) }
                            .lineLimit(1)
                    }
                    Button("Ignorer") { draft.seriesHintDismissed = true }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Série détectée", systemImage: "books.vertical")
        }
    }

    private func applySeries(_ hint: SeriesNames.TitleHint, cleanTitle: Bool) {
        if let s = hint.series { draft.series = s }
        draft.seriesIndex = hint.index
        if cleanTitle { draft.title = hint.title }
    }

    /// Fichiers du même livre : celui de la fiche (envoyé à la Kindle) est marqué.
    private var filesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files.sorted { $0.format.rawValue < $1.format.rawValue }) { f in
                    HStack {
                        Text(f.format.label).font(.caption.weight(.bold).monospaced()).frame(width: 44, alignment: .leading)
                        Text((f.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            .help(f.path)
                        if f.id == draft.id {
                            Text("principal").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                                .help("Fichier affiché ici et envoyé à la Kindle")
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: f.fileSize, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([f.url])
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Afficher dans le Finder")
                    }
                    .font(.callout)
                }
                Text("Les corrections des informations s'appliquent à tous ces fichiers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label("\(files.count) fichiers pour ce livre", systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder private var transferStatus: some View {
        switch kindle.transfers[draft.id] {
        case .queued: Label("En attente…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .converting: HStack { ProgressView().controlSize(.small); Text("Conversion en AZW3…") }
        case .sending: HStack { ProgressView().controlSize(.small); Text("Copie sur la Kindle…") }
        case .done: Label("Envoyé sur la Kindle", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case nil: EmptyView()
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    private var tagsBinding: Binding<String> {
        Binding(get: { draft.tags.joined(separator: ", ") },
                set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
}

struct MultiSelectionView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let books: [Book]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("\(books.count) livres sélectionnés").font(.title2.weight(.semibold))
            let epubs = books.filter { $0.format == .epub }.count
            if epubs > 0 {
                Text("\(epubs) EPUB seront convertis en AZW3.").foregroundStyle(.secondary)
            }
            Button("Envoyer à la Kindle") { Task { await kindle.send(books, library: library) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!kindle.isConnected || kindle.isBusy)
            let done = books.filter { kindle.transfers[$0.id] == .done }.count
            let failed = books.filter { if case .failed = kindle.transfers[$0.id] { true } else { false } }.count
            if done + failed > 0 {
                Text("\(done) envoyé(s), \(failed) échec(s)").foregroundStyle(failed > 0 ? .orange : .secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Résultat de la vérification en ligne : propositions à appliquer ou ignorer, une par une.
struct CatalogSection: View {
    @Environment(LibraryStore.self) private var library
    @Binding var book: Book

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Catalogue en ligne", systemImage: "building.columns")
        }
    }

    @ViewBuilder private var content: some View {
        let suggestions = book.catalogSuggestions
        if library.catalogChecking == book.id {
            HStack { ProgressView().controlSize(.small); Text("Vérification auprès de la BnF…") }
        } else if library.catalogQueue.contains(book.id) {
            Label("En attente de vérification", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if let error = library.catalogErrors[book.id] {
            Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
            checkButton("Réessayer")
        } else if let record = book.catalogRecord {
            if suggestions.isEmpty {
                Label("Informations conformes à la notice \(record.source)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("La notice \(record.source) propose \(suggestions.count == 1 ? "une correction" : "\(suggestions.count) corrections") :")
                    .font(.callout.weight(.medium))
                ForEach(suggestions) { d in
                    row(d)
                    if d.id != suggestions.last?.id { Divider() }
                }
                HStack {
                    Button("Tout appliquer") { apply(Set(suggestions.map(\.field))) }
                        .buttonStyle(.borderedProminent)
                    Button("Tout ignorer") { dismiss(Set(suggestions.map(\.field))) }
                }
            }
            // Sur une seule ligne si la colonne est assez large, sinon le bouton passe dessous.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    recordInfo(record)
                    Spacer()
                    checkButton("Revérifier").controlSize(.small).fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    recordInfo(record)
                    checkButton("Revérifier").controlSize(.small).fixedSize()
                }
            }
        } else if book.catalogCheckedAt != nil {
            Label("Aucune notice trouvée à la BnF ni sur Open Library.", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
            checkButton("Revérifier")
        } else {
            Text("Compare l'ISBN, le titre, les auteurs, l'éditeur et la date avec la BnF puis Open Library.")
                .font(.caption).foregroundStyle(.secondary)
            checkButton("Vérifier en ligne")
        }
    }

    @ViewBuilder private func recordInfo(_ record: CatalogRecord) -> some View {
        HStack(spacing: 12) {
            if record.match == .titleAuthor {
                Text("Trouvée par titre et auteur").font(.caption).foregroundStyle(.secondary)
            }
            if let url = record.url.flatMap(URL.init(string:)) {
                Link("Voir la notice", destination: url).font(.caption).fixedSize()
            }
        }
    }

    /// Libellé et boutons sur une ligne, valeurs en dessous sur toute la largeur : lisible même dans une colonne étroite.
    private func row(_ d: CatalogDifference) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(d.field.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Appliquer") { apply([d.field]) }.controlSize(.small).fixedSize()
                Button {
                    dismiss([d.field])
                } label: {
                    Image(systemName: "xmark")
                }
                .controlSize(.small)
                .help("Ignorer cette proposition")
            }
            if let current = d.current {
                Text(current).strikethrough().foregroundStyle(.secondary)
            }
            Text(d.proposed).fontWeight(.medium).textSelection(.enabled)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkButton(_ title: String) -> some View {
        Button(title) { library.checkCatalog([book.id]) }
    }

    /// Modifie le brouillon de la fiche (enregistré automatiquement), pour ne pas être écrasé par lui.
    private func apply(_ fields: Set<CatalogField>) {
        guard let record = book.catalogRecord else { return }
        var edits = book.edits
        CatalogComparison.apply(fields, from: record, to: &edits)
        book.edits = edits
    }

    private func dismiss(_ fields: Set<CatalogField>) {
        book.catalogDismissed = (book.catalogDismissed ?? []).union(fields)
    }
}
