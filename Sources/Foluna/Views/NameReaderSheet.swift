import FolunaCore
import SwiftUI

/// Première connexion d'une Kindle : son nom de liseuse.
struct NameReaderSheet: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var adoptExisting = true

    /// Livres de la bibliothèque déjà présents sur cette liseuse.
    private var booksOnDevice: [Book] {
        kindle.documents.compactMap { kindle.libraryBook(for: $0, in: library) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Label("Nouvelle liseuse", systemImage: "ipad.landscape.badge.play").font(.title3.weight(.semibold))
            Text("Cette liseuse est branchée pour la première fois. Donnez-lui un nom : Foluna la reconnaîtra ensuite automatiquement et lui tiendra une étagère de livres.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Nom", text: $name, prompt: Text("ex. Liseuse de Léa"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            let onDevice = booksOnDevice.count
            if onDevice > 0 {
                Toggle("Ajouter à son étagère les \(onDevice) livres de la bibliothèque déjà présents sur cette liseuse",
                       isOn: $adoptExisting)
            }
            HStack {
                Spacer()
                Button("Plus tard") {
                    kindle.postponeNaming()
                    dismiss()
                }
                Button("Enregistrer", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.margin)
        .frame(width: Layout.sheet)
        .noInitialFocus()
        .onAppear { name = kindle.device?.name ?? kindle.brand?.label ?? String(localized: "Liseuse") }
    }

    private func save() {
        let existing = adoptExisting ? booksOnDevice : []
        kindle.nameCurrentReader(name)
        if let reader = kindle.currentReader, !existing.isEmpty {
            library.addToShelf(existing, reader: reader.id)
        }
        dismiss()
    }
}
