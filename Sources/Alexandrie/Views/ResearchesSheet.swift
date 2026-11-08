import AlexandrieCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Feuille « Thématiques » (S-075, S-079) : les thématiques et la légende de chacune, une catégorie par couleur.
/// Chaque changement est enregistré aussitôt et redessine les surlignages concernés.
struct ResearchesSheet: View {
    @Environment(ResearchStore.self) private var researches
    @Environment(\.dismiss) private var dismiss
    @State var selected: String?
    @State private var confirmDelete: Research?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
            Divider()
            HStack {
                Text("Une thématique classe des surlignages de plusieurs livres ; ses couleurs nomment des catégories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.lg)
        }
        .frame(width: Layout.sheetWide, height: Layout.researchesHeight)
        .onAppear { if selected == nil { selected = researches.researches.first?.id } }
        .confirmationDialog("Supprimer la thématique « \(confirmDelete?.name ?? "") » ?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { research in
            Button("Supprimer", role: .destructive) {
                researches.delete(research.id)
                selected = researches.researches.first?.id
            }
        } message: { research in
            let count = researches.highlightCount(research: research.id)
            Text(count == 0 ? String(localized: "Aucun surlignage n'y est rangé.")
                 : String(localized: "Ses \(count) surlignages restent, avec leur couleur et leurs autres thématiques."))
        }
    }

    // MARK: Liste des thématiques

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(researches.researches) { research in
                    Text(research.name.isEmpty ? String(localized: "Sans titre") : research.name)
                        .lineLimit(1)
                        .tag(Optional(research.id))
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: Space.xs) {
                Button {
                    selected = researches.addResearch().id
                } label: { Image(systemName: "plus") }
                    .help("Nouvelle thématique")
                    .accessibilityLabel("Nouvelle thématique")
                Button {
                    confirmDelete = researches.research(id: selected)
                } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                    .help("Supprimer la thématique choisie")
                    .accessibilityLabel("Supprimer la thématique")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(Space.sm)
        }
        .frame(width: Layout.researchesSidebar)
    }

    // MARK: Légende de la thématique choisie

    @ViewBuilder private var detail: some View {
        if let research = researches.research(id: selected) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    TextField("Nom", text: binding(research, \.name), prompt: Text("Rénovation des voiries"))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Couleurs").font(.headline)
                        ForEach(research.themes) { theme in
                            themeRow(theme, in: research)
                        }
                        Button {
                            var copy = research
                            copy.addTheme()
                            researches.update(copy)
                        } label: {
                            Label("Ajouter une couleur", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, Space.xs)
                    }
                    Divider()
                    exportRow(research)
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("Aucune thématique", systemImage: "tag")
            } description: {
                Text("Créez une thématique pour classer vos surlignages et nommer ses couleurs : jaune = construction, bleu = analyse des coûts…")
            } actions: {
                Button("Nouvelle thématique") { selected = researches.addResearch().id }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Export de toute la thématique (S-078) : ses livres, classés par couleur nommée, pour rédiger.
    private func exportRow(_ research: Research) -> some View {
        let passages = researches.highlightCount(research: research.id)
        let books = researches.bookCount(research: research.id)
        return HStack {
            Text(passages == 0 ? String(localized: "Aucun passage rangé dans cette thématique.")
                 : String(localized: "\(passages) passages") + " · " + String(localized: "\(books) livres"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Exporter la thématique…") { export(research) }
                .disabled(passages == 0)
                .help("Markdown de tous ses livres, un titre par couleur nommée, chaque passage avec sa source et sa note")
        }
    }

    private func export(_ research: Research) {
        guard let md = researches.exportMarkdown(research: research.id) else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Exporter la thématique")
        panel.nameFieldStringValue = research.name.safeFilename + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Export impossible")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func themeRow(_ theme: ResearchTheme, in research: Research) -> some View {
        let count = researches.highlightCount(research: research.id, color: theme.color)
        return HStack(spacing: Space.sm) {
            ColorPicker("Couleur de « \(theme.displayName) »", selection: colorBinding(theme, in: research), supportsOpacity: false)
                .labelsHidden()
            TextField("Catégorie", text: themeNameBinding(theme, in: research), prompt: Text(theme.displayName))
                .textFieldStyle(.roundedBorder)
            Text(count == 0 ? "" : "\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: Layout.countColumn, alignment: .trailing)
                .help(String(localized: "\(count) surlignages de cette couleur dans la thématique"))
            Button {
                var copy = research
                copy.themes.removeAll { $0.id == theme.id }
                researches.update(copy)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(research.themes.count <= 1)
                .help(count == 0 ? String(localized: "Retirer cette couleur de la légende")
                      : String(localized: "Retirer cette couleur de la légende : ses \(count) surlignages la gardent, sans nom"))
                .accessibilityLabel("Retirer la couleur \(theme.displayName)")
        }
    }

    // MARK: Liaisons

    private func binding(_ research: Research, _ path: WritableKeyPath<Research, String>) -> Binding<String> {
        Binding(get: { researches.research(id: research.id)?[keyPath: path] ?? "" }, set: { value in
            guard var copy = researches.research(id: research.id) else { return }
            copy[keyPath: path] = value
            researches.update(copy)
        })
    }

    private func themeNameBinding(_ theme: ResearchTheme, in research: Research) -> Binding<String> {
        Binding(get: { researches.research(id: research.id)?.theme(id: theme.id)?.name ?? "" }, set: { value in
            change(theme, in: research) { $0.name = value }
        })
    }

    private func colorBinding(_ theme: ResearchTheme, in research: Research) -> Binding<Color> {
        Binding(get: { HighlightMark(theme).swatch }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let hex = HighlightColor.hex(red: Int((c.redComponent * 255).rounded()), green: Int((c.greenComponent * 255).rounded()),
                                         blue: Int((c.blueComponent * 255).rounded()))
            change(theme, in: research) { $0.color = hex }
        })
    }

    private func change(_ theme: ResearchTheme, in research: Research, _ edit: (inout ResearchTheme) -> Void) {
        guard var copy = researches.research(id: research.id),
              let i = copy.themes.firstIndex(where: { $0.id == theme.id }) else { return }
        edit(&copy.themes[i])
        researches.update(copy)
    }
}
