import AlexandrieCore
import SwiftUI

/// Champs de correction des informations d'un livre (à placer dans un `Form`).
struct MetadataFields: View {
    @Binding var edits: MetadataEdits
    /// Le genre n'existe que dans Alexandrie : masqué pour les livres corrigés sur la Kindle.
    var showsGenre = true
    /// Texte brut des auteurs : analysé à chaque frappe sans effacer la virgule en cours de saisie.
    @State private var authorsText: String

    init(edits: Binding<MetadataEdits>, showsGenre: Bool = true) {
        _edits = edits
        self.showsGenre = showsGenre
        _authorsText = State(initialValue: edits.wrappedValue.authors.joined(separator: ", "))
    }

    var body: some View {
        TextField("Titre", text: $edits.title)
        TextField("Auteurs", text: $authorsText, prompt: Text("Séparés par des virgules"))
            .onChange(of: authorsText) { _, text in
                edits.authors = Self.parseAuthors(text)
            }
            .onChange(of: edits.authors) { _, authors in
                // Changement venu d'ailleurs (proposition du catalogue appliquée).
                if Self.parseAuthors(authorsText) != authors { authorsText = authors.joined(separator: ", ") }
            }
        TextField("Éditeur", text: optional(\.publisher))
        HStack {
            TextField("Série", text: optional(\.series), prompt: Text("ex. Brunetti"))
            TextField("N°", text: seriesIndexText, prompt: Text("—"))
                .frame(width: 70)
                .disabled(edits.series == nil)
        }
        if showsGenre {
            TextField("Genre", text: optional(\.genre), prompt: Text("ex. Roman policier"))
        }
        TextField("Date de publication", text: optional(\.publishedDate), prompt: Text("AAAA ou AAAA-MM-JJ"))
        TextField("ISBN", text: optional(\.isbn), prompt: Text("978…"))
        if let isbn = edits.isbn, !isbn.isEmpty, !ISBN.isValid(isbn) {
            Label("ISBN invalide (clé de contrôle incorrecte)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        TextField("Langue", text: optional(\.language), prompt: Text("fr, en, de…"))
        TextField("Résumé", text: optional(\.summary), axis: .vertical)
            .lineLimit(3...10)
    }

    private var seriesIndexText: Binding<String> {
        Binding(get: { edits.seriesIndex.map(SeriesNames.format) ?? "" },
                set: { edits.seriesIndex = Double($0.replacingOccurrences(of: ",", with: ".")) })
    }

    static func parseAuthors(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func optional(_ key: WritableKeyPath<MetadataEdits, String?>) -> Binding<String> {
        Binding(get: { edits[keyPath: key] ?? "" },
                set: { edits[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
}

/// Correction d'un livre directement sur la Kindle (réécriture du fichier sur l'appareil).
struct KindleEditSheet: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(\.dismiss) private var dismiss
    let document: KindleDocument
    @State private var edits: MetadataEdits
    @State private var isSaving = false
    @State private var error: String?

    init(document: KindleDocument, info: KindleBookInfo) {
        self.document = document
        _edits = State(initialValue: info.edits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    MetadataFields(edits: $edits, showsGenre: false)
                } header: {
                    Text("Corriger « \(document.name) »")
                } footer: {
                    Text("Les informations sont réécrites dans le fichier sur la Kindle ; le texte du livre, sa couverture et votre position de lecture ne changent pas. La Kindle peut mettre à jour l'affichage après déconnexion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("Enregistrement sur la Kindle…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer sur la Kindle") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || edits.normalized.title.isEmpty)
            }
            .padding()
        }
        .frame(width: 520)
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            if let message = await kindle.update(document, with: edits) {
                error = message
                isSaving = false
            } else {
                dismiss()
            }
        }
    }
}
