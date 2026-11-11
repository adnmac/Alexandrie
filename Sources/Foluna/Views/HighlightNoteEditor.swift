import FolunaCore
import SwiftUI

/// Note d'un surlignage (S-071) : la même fiche dans « Notes et surlignages » et dans la fenêtre
/// de lecture, qui enregistrent toutes deux par `KindleMonitor.setNote`.
struct HighlightNoteEditor: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(ResearchStore.self) private var researches
    let clipping: Clipping
    /// Rappel du passage, utile dans la fenêtre de lecture où la fiche s'ouvre par-dessus la page.
    var showsPassage = false
    let done: () -> Void
    @State private var draft = ""
    @State private var mark = HighlightMark(.yellow)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if showsPassage {
                if clipping.kind == .highlight {
                    colorPicker
                    thematicPicker
                }
                Text("« \(clipping.displayText) »")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $draft)
                .font(.body)
                .focused($focused)
                .frame(minHeight: 88)
                .overlay(RoundedRectangle(cornerRadius: Radius.field).strokeBorder(.quaternary))
                .accessibilityLabel("Note")
            HStack {
                if clipping.hasNote {
                    Button("Supprimer la note", role: .destructive) { save("") }
                        .buttonStyle(.borderless)
                        .help("Retire la note ; le surlignage reste")
                }
                Spacer()
                Button("Annuler", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Enregistrer la note (⌘↩)")
            }
            .controlSize(.small)
        }
        .onAppear {
            draft = clipping.note ?? ""
            mark = researches.mark(of: clipping)
            focused = true
        }
    }

    /// Couleur du surlignage (S-073, S-079), changée aussitôt et retenue pour les prochains.
    /// Son nom (catégorie de la légende) s'affiche au-dessus des pastilles.
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(mark.label)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: Space.sm) {
                ForEach(researches.marks(for: kindle.clipping(id: clipping.id) ?? clipping)) { m in
                    Button {
                        mark = m
                        researches.apply(m, to: clipping.id)
                    } label: {
                        Circle()
                            .fill(m.swatch)
                            .frame(width: Layout.colorSwatch, height: Layout.colorSwatch)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: m.key == mark.key ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(m.label)
                    .accessibilityLabel(m.label)
                    .accessibilityAddTraits(m.key == mark.key ? .isSelected : [])
                }
            }
        }
    }

    /// Thématiques du surlignage (S-079), à cocher : un passage peut en avoir plusieurs.
    @ViewBuilder private var thematicPicker: some View {
        if !researches.researches.isEmpty {
            let current = kindle.clipping(id: clipping.id)?.thematicIDs ?? clipping.thematicIDs
            // Beaucoup de thématiques : la rangée défile plutôt que d'élargir la bulle.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                Image(systemName: "tag").foregroundStyle(.secondary).accessibilityHidden(true)
                ForEach(researches.researches) { thematic in
                    Toggle(thematic.name, isOn: Binding(get: { current.contains(thematic.id) }, set: { on in
                        researches.setThematic(thematic.id, on: on, for: clipping.id)
                        mark = researches.mark(of: kindle.clipping(id: clipping.id) ?? clipping)
                    }))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .lineLimit(1)
                }
                }
            }
        }
    }

    private func save(_ text: String) {
        kindle.setNote(clipping.id, text)
        done()
    }
}
