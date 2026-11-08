import AlexandrieCore
import SwiftUI

/// Où chercher depuis le champ de recherche (S-082) : les fiches des livres, ou leur texte.
enum SearchScope: String, Hashable {
    case titles, content
}

/// Barre « Chercher dans » sous la barre d'outils (S-082), comme celle du Finder : les fiches ou le texte.
struct SearchScopeBar: View {
    @Binding var scope: SearchScope
    /// Écriture exacte (S-084) : majuscules et accents comptent.
    @Binding var exact: Bool

    var body: some View {
        // Colonne étroite : le libellé « Chercher dans » cède sa place, le choix se comprend seul.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm) {
                Text("Chercher dans :").font(.callout).foregroundStyle(.secondary).fixedSize()
                controls
            }
            HStack(spacing: Space.sm) { controls }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    @ViewBuilder private var controls: some View {
        Picker("Chercher dans", selection: $scope) {
            Text("Titres, auteurs…").tag(SearchScope.titles)
            Text("Contenu des livres").tag(SearchScope.content)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Chercher dans les titres, auteurs, séries, genres et notes, ou dans le texte des livres")
        if scope == .content {
            Toggle("Écriture exacte", isOn: $exact)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Majuscules et accents comptent : « Odyssée » ne trouve plus « odyssée »")
        }
        Spacer(minLength: 0)
    }
}

/// Résultats de la recherche dans le contenu des livres (S-082) : chaque livre avec son nombre de passages
/// et quelques extraits, le mot trouvé en gras. Un extrait ouvre la fenêtre de lecture à ce passage (S-083).
struct ContentSearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ContentIndexer.self) private var indexer
    let query: String
    /// Écriture exacte (S-084).
    let exact: Bool
    /// Sélection de la bibliothèque : un clic sur un livre montre sa fiche.
    @Binding var selection: Set<String>
    @State private var results: [ContentResult] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            if indexer.isIndexing { progress }
            if results.isEmpty {
                if searching {
                    ProgressView("Recherche dans le texte des livres…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Aucun livre ne contient « \(query) »", systemImage: "text.magnifyingglass",
                                           description: Text(indexer.isIndexing
                                               ? String(localized: "Les livres pas encore indexés seront cherchés dès qu'ils le seront.")
                                               : exact ? String(localized: "En écriture exacte, majuscules et accents comptent ; décochez-la pour trouver toutes les écritures.")
                                               : String(localized: "La recherche ignore les accents et les majuscules ; le dernier mot peut être un début de mot.")))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: String(localized: "\(results.count) livres") + " · "
                             + String(localized: "\(results.reduce(0) { $0 + $1.count }) passages"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Space.sm)
                        ForEach(results) { result in
                            row(result)
                            Divider()
                        }
                    }
                    .padding(.horizontal, Space.lg)
                }
            }
        }
        // La recherche attend une courte pause de la frappe, et reprend quand l'indexation avance.
        .task(id: "\(query)|\(exact)|\(indexer.indexed.count)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            let found = await indexer.search(query, in: library.visibleBooks, exact: exact)
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }

    /// Ouvre la fenêtre de lecture au passage, avec les renvois de la recherche (S-083, S-085).
    private func open(_ result: ContentResult, at snippet: ContentSearch.Snippet?) {
        guard let snippet else { return ReaderWindows.open(result.book.id) }
        ReaderLaunch.shared.open(result.book, at: ReaderTarget(section: snippet.section, text: snippet.match,
                                                               occurrence: snippet.occurrence, query: query, exact: exact))
    }

    private var progress: some View {
        let total = indexer.indexed.count + indexer.remaining
        return HStack(spacing: Space.sm) {
            ProgressView(value: Double(indexer.indexed.count), total: Double(max(total, 1)))
                .frame(maxWidth: Layout.indexProgress)
            Text("Indexation du texte : \(indexer.indexed.count) livres sur \(total) ; les résultats s'enrichissent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    private func row(_ result: ContentResult) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            // Comme dans la grille : un clic montre la fiche, un double-clic ouvre la fenêtre de lecture.
            CoverView(book: result.book)
                .frame(width: Layout.resultCover, height: Layout.resultCover * 3 / 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(result, at: result.snippets.first) }
                .onTapGesture { selection = [result.book.id] }
                .help("Clic : fiche du livre ; double-clic : lire")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Couverture de \(result.book.title)")
                .accessibilityAction { selection = [result.book.id] }
                .accessibilityAction(named: "Lire") { open(result, at: result.snippets.first) }
            VStack(alignment: .leading, spacing: Space.xs) {
                Button {
                    selection = [result.book.id]
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.book.title).font(.headline).lineLimit(2)
                        Text(verbatim: result.book.authorLine + " · " + String(localized: "\(result.count) passages"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Montrer la fiche du livre")
                ForEach(Array(result.snippets.enumerated()), id: \.offset) { _, snippet in
                    Button {
                        open(result, at: snippet)
                    } label: {
                        Text("\(snippet.before)\(Text(snippet.match).bold().foregroundStyle(.primary))\(snippet.after)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(result.book.format == .pdf ? String(localized: "Ouvrir la page \(snippet.section + 1) à ce passage")
                          : String(localized: "Ouvrir la fenêtre de lecture à ce passage"))
                }
                if result.count > result.snippets.count {
                    Text(String(localized: "et \(result.count - result.snippets.count) autres passages"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, Space.md)
        .background(selection.contains(result.book.id) ? Palette.accent.opacity(Surface.bannerTint) : .clear)
    }
}
