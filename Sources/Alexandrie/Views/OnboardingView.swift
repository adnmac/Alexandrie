import AlexandrieCore
import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library
    /// Vérification en ligne : rien n'est envoyé sans un oui (audit, § 3).
    @State private var checkOnline = false

    var body: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Bienvenue dans Foluna")
                .font(.largeTitle.weight(.semibold))
            Text("Choisissez le dossier où se trouvent vos livres (EPUB, MOBI, AZW3, PDF).\nIl sera indexé en lecture seule : aucun fichier n'y sera modifié.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            CatalogConsentChoice(checkOnline: $checkOnline)
                .frame(maxWidth: Layout.sheet)
            Button("Choisir le dossier…") {
                library.autoCheckCatalog = checkOnline
                Panels.addLibraryFolder(library)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Case « Compléter les informations en ligne », avec ce qui est envoyé et à qui.
struct CatalogConsentChoice: View {
    @Binding var checkOnline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Toggle("Compléter les informations des livres en ligne", isOn: $checkOnline)
                .toggleStyle(.checkbox)
            Text("L'ISBN, ou à défaut le titre et l'auteur, de chaque nouveau livre est envoyé au catalogue de la BnF puis à Open Library. Rien n'est modifié sans votre accord. Ce choix se change dans les Réglages.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.xl)
        }
    }
}

/// Bibliothèque déjà en place sans réponse sur la vérification en ligne (versions d'avant l'audit) : la
/// question est posée une fois, au lancement.
struct CatalogConsentSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var checkOnline = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Vérification en ligne des livres").font(.title3.weight(.semibold))
            Text("Foluna peut compléter les informations de vos nouveaux livres (ISBN, éditeur, série) à partir de catalogues publics. Elle ne le fait plus sans votre accord.")
                .fixedSize(horizontal: false, vertical: true)
            CatalogConsentChoice(checkOnline: $checkOnline)
            HStack {
                Spacer()
                Button("Continuer") {
                    library.autoCheckCatalog = checkOnline
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.sheet)
        .interactiveDismissDisabled()
    }
}
