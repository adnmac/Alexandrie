import AlexandrieCore
import AppKit
import SwiftUI

/// Commandes sur les livres sélectionnés dans la fenêtre au premier plan.
///
/// La fenêtre principale la publie (`focusedSceneValue`) ; la barre des menus la lit. Les menus SwiftUI
/// ne suivent que ce qu'on leur passe ainsi : jamais l'état observé directement. Le self-test appelle
/// les mêmes fonctions que les menus.
@MainActor
struct BookCommands {
    /// Fichiers principaux des livres sélectionnés.
    let books: [Book]
    /// Page affichée dans la barre latérale.
    let list: SidebarItem?
    let library: LibraryStore
    let kindle: KindleMonitor
    /// Après « Mettre à la corbeille » : la fenêtre sélectionne le livre suivant.
    var afterTrash: () -> Void = {}
    /// Ouvre ou ferme Coup d'œil sur la sélection (fourni par la fenêtre).
    var toggleQuickLook: () -> Void = {}

    // MARK: Envoyer à la Kindle

    /// « Envoyer sur « Kindle de Léa » », « Envoyer à la connexion »… comme le bouton de la fiche.
    var sendTitle: String { KindleSendLabel.title(kindle) }

    var canSend: Bool {
        guard list != .trash, !kindle.isBusy else { return false }
        let sendable = books.filter(\.canSendToKindle)
        guard !sendable.isEmpty else { return false }
        // Kindle débranchée et tout déjà en attente : la commande n'aurait aucun effet.
        return kindle.isConnected || sendable.contains { !$0.isPendingSend }
    }

    /// Envoie tout de suite si la Kindle est branchée, sinon met en attente (annulable avec ⌘Z).
    func send() {
        guard canSend else { return }
        if kindle.isConnected {
            let books = books, kindle = kindle, library = library
            Task { await kindle.send(books, library: library) }
        } else {
            let reader = kindle.readers.count == 1 ? kindle.readers[0].id : nil
            library.undoable("Envoyer à la connexion") { library.queueForKindle(books, reader: reader) }
        }
    }
}

extension BookCommands {
    // MARK: Mettre à la corbeille

    /// Seulement dans les pages de la bibliothèque : dans « Envoyés », « En attente » ou une étagère,
    /// le menu du livre propose de le retirer de la liste, pas de le jeter.
    var canTrash: Bool { !books.isEmpty && list?.allowsTrash == true }

    /// Met les livres sélectionnés à la corbeille d'Alexandrie, en une action annulable (⌘Z).
    func trash() {
        guard canTrash else { return }
        library.undoable("Mettre à la corbeille") { books.forEach(library.moveToTrash) }
        afterTrash()
    }
}

extension BookCommands {
    // MARK: Coup d'œil

    var canQuickLook: Bool { !books.isEmpty }
}

extension SidebarItem {
    /// Pages où « Mettre à la corbeille » est proposé (menu du livre, menu Livre, touche Supprimer).
    var allowsTrash: Bool {
        switch self {
        case .all, .recent, .toReview, .format, .author, .series, .genre: true
        case .sent, .pending, .shelf, .trash, .kindle, .notes: false
        }
    }
}

extension FocusedValues {
    /// Sélection de la fenêtre principale au premier plan, pour la barre des menus.
    @Entry var bookCommands: BookCommands?
}
