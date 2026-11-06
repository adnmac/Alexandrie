import AlexandrieCore
import SwiftUI

/// Revue en lot des propositions du catalogue : cocher, puis appliquer ou ignorer d'un coup.
struct CatalogReviewSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [CatalogReview.Row] = []
    @State private var selected = Set<String>()
    @State private var field: CatalogField?
    @State private var coversRead = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("Aucune proposition à revoir", systemImage: "checkmark.seal",
                                       description: Text("Toutes les propositions du catalogue ont été traitées."))
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 580)
        .onAppear(perform: reload)
        .task { await readCovers() }
    }

    // MARK: - En-tête et pied

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Revue des propositions du catalogue").font(.title3.weight(.semibold))
                let books = Set(rows.map(\.book.id)).count
                Text("\(books) livres, \(rows.count) propositions"
                     + (coverTotal > 0 && coversRead < coverTotal ? " · lecture des couvertures \(coversRead)/\(coverTotal)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Champ", selection: $field) {
                Text("Tous les champs").tag(CatalogField?.none)
                ForEach(fieldsPresent) { f in Text(f.label).tag(CatalogField?.some(f)) }
            }
            .frame(width: 220)
        }
        .padding(Space.lg)
    }

    private var footer: some View {
        HStack {
            Menu("Cocher") {
                Button("Tout (\(visibleRows.count))") { selected.formUnion(visibleRows.map(\.id)) }
                Button("Tout sauf ce que la couverture contredit") {
                    selected.formUnion(visibleRows.filter { !isContradicted($0) }.map(\.id))
                }
                Button("Seulement ce que la couverture confirme") {
                    selected.formUnion(visibleRows.filter { verdict($0) == .confirmed }.map(\.id))
                }
                Divider()
                ForEach(fieldsPresent) { f in
                    Button("Tous les « \(f.label) »") { selected.formUnion(rows.filter { $0.difference.field == f }.map(\.id)) }
                }
                Divider()
                Button("Rien") { selected.removeAll() }
            }
            .fixedSize()
            Text(selected.isEmpty ? "Aucune proposition cochée" : "\(selected.count) cochée(s)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Fermer") { dismiss() }
            Button("Ignorer la sélection") { act(apply: false) }
                .disabled(selected.isEmpty)
                .help("Ces propositions ne seront plus faites pour la notice actuelle")
            Button("Appliquer la sélection") { act(apply: true) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
        }
        .padding(Space.lg)
    }

    // MARK: - Tableau

    private var table: some View {
        Table(visibleRows) {
            TableColumn("") { r in
                Toggle("", isOn: Binding(get: { selected.contains(r.id) },
                                         set: { if $0 { selected.insert(r.id) } else { selected.remove(r.id) } }))
                    .labelsHidden()
            }
            .width(24)
            TableColumn("Livre") { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.book.title).lineLimit(1)
                    Text(r.book.authorLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(r.book.title)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Champ") { r in Text(r.difference.field.label).foregroundStyle(.secondary) }
                .width(80)
            TableColumn("Actuel") { r in
                Text(r.difference.current ?? "—").strikethrough(r.difference.current != nil)
                    .foregroundStyle(.secondary).lineLimit(2).help(r.difference.current ?? "")
            }
            .width(min: 120, ideal: 200)
            TableColumn("Proposé") { r in
                Text(r.difference.proposed).fontWeight(.medium).lineLimit(2).help(r.difference.proposed)
            }
            .width(min: 120, ideal: 220)
            TableColumn("Couverture") { r in coverLabel(r) }
                .width(min: 110, ideal: 150)
        }
    }

    @ViewBuilder private func coverLabel(_ r: CatalogReview.Row) -> some View {
        switch verdict(r) {
        case .confirmed?:
            Label("Confirmé", systemImage: "checkmark.circle").foregroundStyle(Palette.success).font(.caption)
        case .contradicted(let value)?:
            Label(value.map { "« \($0) »" } ?? "Contredit", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Palette.warning).font(.caption)
                .help(value.map { "La couverture indique « \($0) »" } ?? "La couverture porte la valeur actuelle")
        case nil:
            Text("—").foregroundStyle(.tertiary).font(.caption)
        }
    }

    // MARK: - Données

    private var visibleRows: [CatalogReview.Row] {
        field.map { f in rows.filter { $0.difference.field == f } } ?? rows
    }

    private var fieldsPresent: [CatalogField] {
        let present = Set(rows.map(\.difference.field))
        return CatalogField.allCases.filter(present.contains)
    }

    private var coverTotal: Int { Set(rows.filter(\.book.hasCover).map(\.book.fingerprint)).count }

    private func verdict(_ r: CatalogReview.Row) -> CoverVerdict? {
        guard let cover = library.coverTexts[r.book.fingerprint] else { return nil }
        return CoverCheck.verdict(for: r.difference, book: r.book.edits, cover: cover, publishers: library.publisherNames)
    }

    private func isContradicted(_ r: CatalogReview.Row) -> Bool {
        if case .contradicted? = verdict(r) { return true }
        return false
    }

    private func reload() {
        // Mêmes livres et mêmes propositions que la fiche : celles du fichier principal de chaque livre.
        rows = CatalogReview.rows(BookGroups.make(library.visibleBooks, identities: library.identities))
        selected = selected.intersection(rows.map(\.id))
    }

    private func act(apply: Bool) {
        let chosen = rows.filter { selected.contains($0.id) }
        if apply {
            library.undoable("Appliquer la revue") { library.applyReview(chosen) }
        } else {
            library.undoable("Ignorer des propositions") { library.dismissReview(chosen) }
        }
        selected.removeAll()
        reload()
    }

    /// Couvertures lues une à une en arrière-plan (la première lecture charge le modèle de macOS).
    private func readCovers() async {
        var seen = Set<String>()
        for r in rows where r.book.hasCover && seen.insert(r.book.fingerprint).inserted {
            if Task.isCancelled { return }
            await library.readCover(r.book)
            coversRead = seen.count
        }
    }
}
