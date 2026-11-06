import AlexandrieCore
import SwiftUI

/// Bouton d'envoi : envoi immédiat si la Kindle est branchée ; sinon mise en attente, avec le choix
/// de la liseuse quand plusieurs sont connues.
struct KindleSendButton<Content: View>: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    let books: [Book]
    @ViewBuilder let label: () -> Content

    var body: some View {
        if kindle.isConnected || kindle.readers.count < 2 {
            Button {
                if kindle.isConnected {
                    Task { await kindle.send(books, library: library) }
                } else {
                    // Mise en attente annulable (⌘Z), comme la commande Kindle > Envoyer.
                    let reader = kindle.readers.first.map(\.id)
                    library.undoable("Envoyer à la connexion") { library.queueForKindle(books, reader: reader) }
                }
            } label: { label() }
        } else {
            Menu {
                Section("Envoyer à la connexion de") {
                    ForEach(kindle.readers) { reader in
                        Button(reader.name) { library.queueForKindle(books, reader: reader.id) }
                    }
                }
            } label: { label() }
        }
    }
}

/// Libellé des boutons d'envoi : envoi immédiat, ou mise en attente si la Kindle est débranchée.
enum KindleSendLabel {
    @MainActor static func title(_ kindle: KindleMonitor) -> String {
        if kindle.isConnected { return kindle.currentReader.map { "Envoyer sur « \($0.name) »" } ?? "Envoyer à la Kindle" }
        if kindle.readers.count == 1 { return "Envoyer à la connexion de « \(kindle.readers[0].name) »" }
        return "Envoyer à la connexion"
    }
    @MainActor static func icon(_ kindle: KindleMonitor) -> String {
        kindle.isConnected ? "arrow.down.to.line.compact" : "clock.arrow.circlepath"
    }
}
