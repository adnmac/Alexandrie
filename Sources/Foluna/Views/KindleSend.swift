import FolunaCore
import SwiftUI

/// Bouton d'envoi : envoi immédiat si la liseuse est branchée ; sinon mise en attente, avec le choix
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
                    library.undoable(String(localized: "Envoyer à la connexion")) { library.queueForKindle(books, reader: reader) }
                    SendNotifier.prepare()
                }
            } label: { label() }
        } else {
            Menu {
                Section("Envoyer à la connexion de") {
                    ForEach(kindle.readers) { reader in
                        Button(reader.name) {
                            library.undoable(String(localized: "Envoyer à la connexion")) { library.queueForKindle(books, reader: reader.id) }
                            SendNotifier.prepare()
                        }
                    }
                }
            } label: { label() }
        }
    }
}

/// Libellé des boutons d'envoi : envoi immédiat, ou mise en attente si la liseuse est débranchée.
enum KindleSendLabel {
    @MainActor static func title(_ kindle: KindleMonitor) -> String {
        if kindle.isConnected { return kindle.currentReader.map { String(localized: "Envoyer sur « \($0.name) »") } ?? String(localized: "Envoyer à la liseuse") }
        if kindle.readers.count == 1 { return String(localized: "Envoyer à la connexion de « \(kindle.readers[0].name) »") }
        return String(localized: "Envoyer à la connexion")
    }
    @MainActor static func icon(_ kindle: KindleMonitor) -> String {
        kindle.isConnected ? "arrow.down.to.line.compact" : "clock.arrow.circlepath"
    }
}
