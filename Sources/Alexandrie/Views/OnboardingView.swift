import AlexandrieCore
import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Bienvenue dans Alexandrie")
                .font(.largeTitle.weight(.semibold))
            Text("Choisissez le dossier où se trouvent vos livres (EPUB, MOBI, AZW3, PDF).\nIl sera indexé en lecture seule : aucun fichier n'y sera modifié.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choisir le dossier…") { Panels.chooseLibraryFolder(library) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
