import AlexandrieCore
import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Binding var selection: SidebarItem?
    /// États replié/déplié mémorisés : la liste des auteurs peut compter des centaines d'entrées.
    @AppStorage("sidebarAuthorsExpanded") private var authorsExpanded = false
    @AppStorage("sidebarFormatsExpanded") private var formatsExpanded = true
    @AppStorage("sidebarSeriesExpanded") private var seriesExpanded = false

    var body: some View {
        List(selection: $selection) {
            Section("Bibliothèque") {
                row("Tous les livres", "books.vertical", .all, count: library.books.count)
                row("Ajoutés récemment", "clock", .recent)
                row("Envoyés à la Kindle", "checkmark.circle", .sent,
                    count: library.books.filter { $0.lastSentAt != nil }.count)
                row("À vérifier", "exclamationmark.bubble", .toReview, count: library.pendingSuggestionCount)
            }

            Section("Kindle") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kindle.device?.name ?? "Non connectée")
                        if let device = kindle.device {
                            Text(device.connection.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: kindle.isConnected ? "ipad.landscape.badge.play" : "ipad.landscape")
                        .foregroundStyle(kindle.isConnected ? Color.green : Color.secondary)
                }
                .tag(SidebarItem.kindle)
            }

            let formats = BookFormat.allCases.map { f in (f, library.books.filter { $0.format == f }.count) }
                .filter { $0.1 > 0 }
            // Titres en lignes ordinaires plutôt qu'en en-têtes de section : macOS ajoute aux en-têtes
            // son propre chevron (visible au survol seulement), qui masquerait celui-ci.
            Section {
                CollapsibleHeader(title: "Formats", count: formats.count, tint: .blue, isExpanded: $formatsExpanded)
                if formatsExpanded {
                    ForEach(formats, id: \.0) { f, n in row(f.label, "doc", .format(f), count: n) }
                }
            }

            let series = SeriesNames.groups(library.books)
            Section {
                CollapsibleHeader(title: "Séries", count: series.count, tint: .green, isExpanded: $seriesExpanded)
                if seriesExpanded {
                    ForEach(series) { s in
                        row(s.name, "books.vertical", .series(s.key), count: s.bookCount)
                            .help(s.variants.count > 1 ? "Noms regroupés : " + s.variants.joined(separator: " · ") : s.name)
                    }
                }
            }

            let authors = AuthorNames.groups(library.books)
            Section {
                CollapsibleHeader(title: "Auteurs", count: authors.count, tint: .orange, isExpanded: $authorsExpanded)
                if authorsExpanded {
                    ForEach(authors) { a in
                        row(a.name, "person", .author(a.key), count: a.bookCount)
                            .help(a.variants.count > 1 ? "Graphies regroupées : " + a.variants.joined(separator: " · ") : a.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ icon: String, _ tag: SidebarItem, count: Int? = nil) -> some View {
        Label(title, systemImage: icon)
            .badge(count ?? 0)
            .tag(tag)
    }
}

/// En-tête de section repliable à fond teinté, avec un chevron toujours visible.
struct CollapsibleHeader: View {
    let title: String
    let count: Int
    let tint: Color
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Replier \(title.lowercased())" : "Déplier \(title.lowercased())")
        .accessibilityLabel("\(title), \(isExpanded ? "déplié" : "replié")")
    }
}
