import AlexandrieCore
import AppKit
import SwiftUI

struct BookDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(ReadingStore.self) private var reading
    @State private var draft: Book
    /// Tous les fichiers du même livre (lui compris).
    let files: [Book]

    init(book: Book, files: [Book] = []) {
        _draft = State(initialValue: book)
        self.files = files
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                CoverView(book: draft)
                    .frame(height: 280)
                    .frame(maxWidth: .infinity)
                    .gridProbe("couverture", area: "fiche")
                if !files.contains(where: \.hasCover), !draft.hasCover {
                    CoverSearchButton(book: draft)
                }

                transferStatus

                let isPending = library.book(id: draft.id)?.isPendingSend == true
                let isTrashed = library.book(id: draft.id)?.trashedAt != nil
                HStack {
                    if isTrashed {
                        Button {
                            library.undoable(String(localized: "Restaurer")) { library.restoreFromTrash(draft) }
                        } label: {
                            Label("Restaurer", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if isPending && !kindle.isConnected {
                        Button {
                            library.undoable(String(localized: "Retirer de la file d'envoi")) { library.removeFromKindleQueue([draft.id]) }
                        } label: {
                            Label("Retirer de la file d'envoi", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    } else {
                        KindleSendButton(books: [draft]) {
                            Label(KindleSendLabel.title(kindle), systemImage: KindleSendLabel.icon(kindle))
                                .frame(maxWidth: .infinity)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(kindle.isBusy || !kindle.canSend(draft))
                    }
                    Menu {
                        BookActions(book: draft)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.large)
                }
                .gridProbe("actions", area: "fiche")
                if isTrashed {
                    Label("Dans la corbeille de Foluna : ses fichiers sont intacts tant qu'elle n'est pas vidée.",
                          systemImage: "trash")
                        .font(.caption).foregroundStyle(.secondary)
                } else if isPending && !kindle.isConnected {
                    Label("En attente : sera envoyé dès que la liseuse sera branchée.", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !kindle.isConnected {
                    Text("Liseuse non branchée : le livre peut être mis en attente et partira dès sa connexion.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if library.isFormatDisabled(draft) {
                    Label("Format \(draft.format.label) désactivé (Réglages › Formats) : le livre est gardé, mais ni lu ni envoyé.",
                          systemImage: "puzzlepiece.extension")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let brand = kindle.brand, !draft.canSend(to: brand) {
                    Text("Protégé par DRM : il ne peut pas être lu sur cette \(brand.label).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if kindle.brand == .kindle && draft.format == .epub {
                    Text("Sera converti en AZW3 avant l'envoi (la Kindle ne lit pas l'EPUB par USB).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if kindle.brand == .kindle && draft.format.importer != nil && draft.becomesAZW3 {
                    Text("Sera converti en AZW3 avant l'envoi (la Kindle ne lit pas le \(draft.format.label) par USB).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if kindle.brand == .kindle && draft.becomesPDF {
                    Text("Sera envoyé en PDF, une page par image (la Kindle ne lit pas le CBZ).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let brand = kindle.brand, brand.readsEPUB, !draft.isDRMProtected,
                          draft.sentExtension(for: brand) != draft.format.rawValue {
                    Text("Sera converti en EPUB avant l'envoi : la \(brand.label) le lit mieux.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Fenêtre de lecture (S-066, S-068) : lire, ou reprendre là où la lecture s'est arrêtée.
                if draft.canRead && !isTrashed && !library.isUnavailable(draft) {
                    let position = reading.savedPosition(of: draft)
                    Button { ReaderWindows.open(draft.id) } label: {
                        Label(position.map { String(localized: "Reprendre la lecture · \($0.label)") } ?? String(localized: "Lire"), systemImage: "book")
                    }
                    .buttonStyle(.link)
                    .help("Ouvrir le livre dans la fenêtre de lecture (⌘L)")
                }
                if draft.isDRMProtected {
                    Label("Ce livre est protégé par DRM : il ne peut pas être converti.", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(Palette.warning)
                } else if draft.format == .pdf && !isTrashed {
                    PDFKindlePicker(mode: $draft.pdfMode, url: draft.url)
                } else if draft.format == .txt && !isTrashed {
                    Label("Texte brut : paragraphes et chapitres sont reconstitués, la mise en page peut être approximative.",
                          systemImage: "text.alignleft")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Form {
                    Section {
                        MetadataFields(edits: $draft.edits)
                        TextField("Étiquettes", text: tagsBinding, prompt: Text("Séparées par des virgules"))
                    } header: {
                        Text("Informations")
                    } footer: {
                        Text("Corrections enregistrées dans Foluna et appliquées aux copies envoyées sur la liseuse. Le fichier d'origine n'est jamais modifié.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                // Le formulaire groupé a sa propre marge : il s'étend sur celle de la fiche.
                .padding(.horizontal, -Space.margin)
                .onChange(of: draft) { _, new in library.update(new, propagatingTo: files.map(\.id)) }

                if let hint = draft.seriesHint { seriesHintBox(hint) }

                CatalogSection(book: $draft, fileIDs: files.isEmpty ? [draft.id] : files.map(\.id))

                let hiddenCopies = library.hiddenCopies(of: draft)
                let notes = kindle.clippings(for: files.isEmpty ? [draft] : files)
                if !notes.isEmpty { ClippingsSection(clippings: notes, bookKey: ShelfSync.normalize(draft.title)) }

                if files.count > 1 || !hiddenCopies.isEmpty { filesSection(hiddenCopies: hiddenCopies) }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
                    info(String(localized: "Format"), draft.format.label)
                    info(String(localized: "Taille"), ByteCountFormatter.string(fromByteCount: draft.fileSize, countStyle: .file))
                    info(String(localized: "Ajouté le"), draft.addedAt.formatted(date: .long, time: .omitted))
                    if let sent = draft.lastSentAt { info(String(localized: "Envoyé le"), sent.formatted(date: .long, time: .shortened)) }
                    // Fenêtre de lecture (S-068) : où la lecture s'est arrêtée.
                    if let position = reading.savedPosition(of: draft) { info(String(localized: "Lecture"), position.label) }
                    // Par liseuse : étagères et derniers envois (liseuses oubliées ignorées).
                    let shelfNames = kindle.readers.filter { draft.shelfIDs.contains($0.id) }.map(\.name)
                    if !shelfNames.isEmpty { info(String(localized: "Étagères"), shelfNames.joined(separator: ", ")) }
                    ForEach(kindle.readers.filter { draft.sentTo?[$0.id] != nil }) { reader in
                        info(String(localized: "Sur « \(reader.name) »"),
                             String(localized: "envoyé le ") + draft.sentTo![reader.id]!.formatted(date: .long, time: .shortened))
                    }
                    info(String(localized: "Emplacement"), draft.isImported ? String(localized: "Imports de Foluna") : draft.path)
                }
                .font(.callout)
                // Bord à part : le formulaire et les sections entre « actions » et lui ne sont pas sondés.
                .gridProbe("details", area: "fiche", edge: "details")
            }
            .padding(Space.margin)
            .gridArea("fiche")
        }
        // Après ⌘Z : les informations annulées reviennent dans la fiche ouverte.
        .onChange(of: library.undoGeneration) {
            guard let stored = library.book(id: draft.id) else { return }
            draft.edits = stored.edits
            draft.tags = stored.tags
            draft.catalogDismissed = stored.catalogDismissed
        }
        .onChange(of: library.book(id: draft.id)) { _, new in
            // Mise à jour externe (envoi terminé, rescan) sans écraser une saisie en cours.
            guard let new else { return }
            if new.lastSentAt != draft.lastSentAt { draft.lastSentAt = new.lastSentAt; draft.sentFilename = new.sentFilename }
            if new.pendingSendAt != draft.pendingSendAt || new.pendingFor != draft.pendingFor {
                draft.pendingSendAt = new.pendingSendAt
                draft.pendingFor = new.pendingFor
            }
            if new.sentTo != draft.sentTo { draft.sentTo = new.sentTo }
            if new.shelves != draft.shelves { draft.shelves = new.shelves }
            if new.trashedAt != draft.trashedAt { draft.trashedAt = new.trashedAt }
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

    /// Fichiers du même livre : celui de la fiche (envoyé à la liseuse) est marqué.
    private func filesSection(hiddenCopies: [Book]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(files.sorted { $0.format.rawValue < $1.format.rawValue }) { f in
                    HStack {
                        Text(f.format.label).font(.caption.weight(.bold).monospaced()).frame(width: 44, alignment: .leading)
                        Text((f.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            .help(f.path)
                        if f.id == draft.id {
                            Text("principal").font(.caption2).padding(.horizontal, Space.sm).background(.quaternary, in: Capsule())
                                .help("Fichier affiché ici et envoyé à la liseuse")
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
                if files.count > 1 {
                    Text("Les corrections des informations s'appliquent à tous ces fichiers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !hiddenCopies.isEmpty {
                    Text(hiddenCopies.count == 1
                         ? String(localized: "1 copie en double (même format) est masquée ; elle reste sur le disque.")
                         : String(localized: "\(hiddenCopies.count) copies en double (même format) sont masquées ; elles restent sur le disque."))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(hiddenCopies.map(\.path).joined(separator: "\n"))
                }
            }
            .padding(4)
        } label: {
            Label(files.count == 1 ? String(localized: "1 fichier pour ce livre") : String(localized: "\(files.count) fichiers pour ce livre"), systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder private var transferStatus: some View {
        switch kindle.transfers[draft.id] {
        case .queued: Label("En attente…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .converting: HStack { ProgressView().controlSize(.small); Text("Conversion en AZW3…") }
        case .sending: HStack { ProgressView().controlSize(.small); Text("Copie sur la liseuse…") }
        case .done: Label("Envoyé sur la liseuse", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
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
            KindleSendButton(books: books) { Text(KindleSendLabel.title(kindle)) }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(kindle.isBusy || !books.contains(where: kindle.canSend))
            if !kindle.isConnected {
                Text("La liseuse n'est pas branchée : ces livres partiront dès sa connexion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !kindle.readers.isEmpty {
                Menu("Étagères") { ShelfActions(books: books) }
                    .fixedSize()
            }
            let done = books.filter { kindle.transfers[$0.id] == .done }.count
            let failed = books.filter { if case .failed = kindle.transfers[$0.id] { true } else { false } }.count
            if done + failed > 0 {
                Text(verbatim: String(localized: "\(done) envoyés") + ", " + String(localized: "\(failed) échecs")).foregroundStyle(failed > 0 ? AnyShapeStyle(Palette.warning) : AnyShapeStyle(.secondary))
            }
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Résultat de la vérification en ligne : propositions à appliquer ou ignorer, une par une.
/// Livre sans couverture : recherche sur Open Library (par ISBN, sinon titre et auteur).
struct CoverSearchButton: View {
    @Environment(LibraryStore.self) private var library
    let book: Book
    @State private var notFound = false

    var body: some View {
        HStack {
            Spacer()
            if library.coverSearch != nil {
                ProgressView().controlSize(.small)
                Text("Recherche de la couverture…").font(.caption).foregroundStyle(.secondary)
            } else if notFound {
                Text("Aucune couverture trouvée sur Open Library.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Chercher une couverture") {
                    Task { notFound = await library.findCovers(for: [book]) == 0 }
                }
                .controlSize(.small)
            }
            Spacer()
        }
    }
}

/// Résumé des notes Kindle du livre dans la fiche : les dernières, et l'accès à toutes dans la vue Notes.
struct ClippingsSection: View {
    @Environment(KindleMonitor.self) private var kindle
    let clippings: [Clipping]
    let bookKey: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(clippings.suffix(3).reversed()) { c in
                    Text(c.displayText)
                        .font(c.kind == .note ? .callout.italic() : .callout)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }
                Button(clippings.count <= 3 ? String(localized: "Ouvrir dans Notes") : String(localized: "Voir les \(clippings.count) notes et surlignages")) {
                    kindle.notesRequest = bookKey
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label(clippings.count == 1 ? String(localized: "1 note ou surlignage de liseuse") : String(localized: "\(clippings.count) notes et surlignages de liseuse"),
                  systemImage: "highlighter")
        }
    }
}

struct CatalogSection: View {
    @Environment(LibraryStore.self) private var library
    @Binding var book: Book
    /// Fichiers du livre : leur état est mémorisé avant une correction, pour ⌘Z.
    var fileIDs: [Book.ID] = []

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.md) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Catalogue en ligne", systemImage: "building.columns")
        }
        .task(id: "\(book.fingerprint)|\(book.catalogCheckedAt?.timeIntervalSince1970 ?? 0)") {
            if !book.catalogSuggestions.isEmpty { await library.readCover(book) }
        }
    }

    /// Ce que dit la couverture de chaque proposition (vide tant qu'elle n'est pas lue).
    private func coverVerdicts(_ suggestions: [CatalogDifference]) -> [CatalogField: CoverVerdict] {
        guard let cover = library.coverTexts[book.fingerprint] else { return [:] }
        let publishers = library.publisherNames
        var out: [CatalogField: CoverVerdict] = [:]
        for d in suggestions {
            out[d.field] = CoverCheck.verdict(for: d, book: book.edits, cover: cover, publishers: publishers)
        }
        return out
    }

    @ViewBuilder private var content: some View {
        let suggestions = book.catalogSuggestions
        if library.catalogChecking == book.id {
            HStack { ProgressView().controlSize(.small); Text("Vérification auprès de la BnF…") }
        } else if library.catalogQueue.contains(book.id) {
            Label("En attente de vérification", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if let error = library.catalogErrors[book.id] {
            Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(Palette.warning)
            checkButton("Réessayer")
        } else if let record = book.catalogRecord {
            if suggestions.isEmpty {
                Label("Informations conformes à la notice \(record.source)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Palette.success)
            } else {
                let verdicts = coverVerdicts(suggestions)
                let contradicted = Set(verdicts.compactMap { field, v in
                    if case .contradicted = v { return field } else { return nil }
                })
                Text(suggestions.count == 1 ? String(localized: "La notice \(record.source) propose une correction :")
                     : String(localized: "La notice \(record.source) propose \(suggestions.count) corrections :"))
                    .font(.callout.weight(.medium))
                ForEach(suggestions) { d in
                    row(d, verdict: verdicts[d.field])
                    if d.id != suggestions.last?.id { Divider() }
                }
                HStack {
                    Button("Tout appliquer") { apply(Set(suggestions.map(\.field)).subtracting(contradicted)) }
                        .buttonStyle(.borderedProminent)
                        .disabled(contradicted.count == suggestions.count)
                    Button("Tout ignorer") { dismiss(Set(suggestions.map(\.field))) }
                }
                if library.coverReading.contains(book.fingerprint) {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.mini)
                        Text("Lecture de la couverture…")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !contradicted.isEmpty {
                    Text("« Tout appliquer » laisse de côté les propositions contredites par la couverture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // Sur une seule ligne si la colonne est assez large, sinon le bouton passe dessous.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    recordInfo(record)
                    Spacer()
                    checkButton("Revérifier").controlSize(.small).fixedSize()
                }
                VStack(alignment: .leading, spacing: Space.sm) {
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
    private func row(_ d: CatalogDifference, verdict: CoverVerdict?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
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
            if let verdict { verdictLine(verdict, for: d) }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func verdictLine(_ verdict: CoverVerdict, for d: CatalogDifference) -> some View {
        switch verdict {
        case .confirmed:
            Label("Lu sur la couverture", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(Palette.success)
        case .contradicted(let value?):
            VStack(alignment: .leading, spacing: 4) {
                Label("La couverture indique « \(value) »", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Palette.warning)
                if d.field == .publisher {
                    // La couverture confirme la valeur actuelle : on la garde ; sinon on adopte celle de la couverture.
                    Button(value == d.current ? String(localized: "Garder « \(value) »") : String(localized: "Utiliser « \(value) »")) {
                        library.prepareUndo(String(localized: "Corriger l'éditeur"), ids: fileIDs)
                        book.publisher = value
                        book.catalogDismissed = (book.catalogDismissed ?? []).union([.publisher])
                    }
                    .controlSize(.small).fixedSize()
                }
            }
        case .contradicted(nil):
            Label("Absent de la couverture, qui porte la valeur actuelle", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Palette.warning)
        }
    }

    private func checkButton(_ title: String) -> some View {
        Button(title) { library.checkCatalog([book.id]) }
    }

    /// Modifie le brouillon de la fiche (enregistré automatiquement), pour ne pas être écrasé par lui.
    private func apply(_ fields: Set<CatalogField>) {
        guard let record = book.catalogRecord else { return }
        library.prepareUndo(fields.count == 1 ? String(localized: "Appliquer « \(fields.first!.label) »") : String(localized: "Appliquer la notice"), ids: fileIDs)
        var edits = book.edits
        CatalogComparison.apply(fields, from: record, to: &edits)
        book.edits = edits
    }

    private func dismiss(_ fields: Set<CatalogField>) {
        library.prepareUndo(String(localized: "Ignorer des propositions"), ids: fileIDs)
        book.catalogDismissed = (book.catalogDismissed ?? []).union(fields)
    }
}

/// Fiche d'un PDF : ce que la liseuse reçoit (S-064, S-065). Sans texte, le choix redimensionnable est grisé.
struct PDFKindlePicker: View {
    @Binding var mode: PDFKindleMode?
    let url: URL
    /// Lu en arrière-plan : nil tant que le PDF n'a pas été examiné.
    @State private var hasText: Bool?

    var body: some View {
        let current = mode ?? .asIs
        let available = PDFKindleMode.available(hasText: hasText ?? true)
        VStack(alignment: .leading, spacing: Space.xs) {
            Picker("Sur la liseuse", selection: Binding(get: { current }, set: { mode = $0 == .asIs ? nil : $0 })) {
                ForEach(PDFKindleMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m).disabled(!available.contains(m))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text(current.explanation)
                .font(.caption).foregroundStyle(.secondary)
            if hasText == false {
                Label("Ce PDF ne contient pas de texte : il ne peut pas devenir un texte redimensionnable.",
                      systemImage: "doc.viewfinder")
                    .font(.caption).foregroundStyle(current == .reflowable ? Palette.warning : Color.secondary)
            }
        }
        .task(id: url) {
            let url = self.url
            hasText = await Task.detached(priority: .utility) { PDFReflow.hasText(url) }.value
        }
    }
}
