import AlexandrieCore
import SwiftUI

/// « Catalogues en ligne » (S-089) : ajouter l'adresse d'un catalogue OPDS public, renommer, retirer,
/// rétablir les catalogues proposés.
struct OPDSCatalogsSheet: View {
    @Environment(OPDSStore.self) private var opds
    @Environment(\.dismiss) private var dismiss
    @State private var selection: OPDSCatalog.ID?
    @State private var name = ""
    @State private var address = ""
    @State private var adding = false
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Label("Catalogues en ligne", systemImage: "globe").font(.title3.weight(.semibold))
            Text("Catalogues OPDS publics de livres gratuits. Rien n'est demandé en ligne tant qu'un catalogue n'est pas ouvert dans la barre latérale ; seuls les livres sans DRM peuvent être ajoutés.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(opds.catalogs) { catalog in
                    CatalogNameRow(catalog: catalog) { opds.rename(catalog.id, to: $0) }
                        .tag(catalog.id)
                }
            }
            .frame(height: Layout.catalogsList)
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .onDeleteCommand(perform: removeSelected)

            HStack {
                Button("Retirer", action: removeSelected)
                    .disabled(selection == nil)
                Button("Rétablir les catalogues proposés") { opds.restoreSuggestions() }
                    .disabled(OPDSCatalog.suggested.allSatisfy { s in opds.catalogs.contains { $0.id == s.id && $0.name == s.name } })
                Spacer()
            }

            GroupBox("Ajouter un catalogue") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    TextField("Adresse", text: $address, prompt: Text("https://exemple.org/opds"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    TextField("Nom", text: $name, prompt: Text("Facultatif : le nom donné par le catalogue"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    HStack {
                        if adding {
                            ProgressView().controlSize(.small)
                            Text("Vérification du catalogue…").font(.caption).foregroundStyle(.secondary)
                        } else if let addError {
                            Label(addError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(Palette.warning)
                        }
                        Spacer()
                        Button("Ajouter", action: add)
                            .disabled(adding || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(Space.xs)
            }

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.margin)
        .frame(width: Layout.sheet)
        .noInitialFocus()
    }

    private func add() {
        guard !adding, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        adding = true
        addError = nil
        Task {
            switch await opds.add(name: name, address: address) {
            case .success(let catalog):
                selection = catalog.id
                name = ""
                address = ""
            case .failure(let error):
                addError = error.message
            }
            adding = false
        }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        opds.remove(id)
        selection = nil
    }
}

/// Nom d'un catalogue, modifiable sur place ; l'adresse en dessous.
private struct CatalogNameRow: View {
    let catalog: OPDSCatalog
    let rename: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            TextField("Nom", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { rename(name) }
                .onAppear { name = catalog.name }
                .onChange(of: catalog.name) { _, new in name = new }
            Text(catalog.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, Space.xs)
    }
}
