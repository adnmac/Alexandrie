import AlexandrieCore
import AppKit
import SwiftUI

/// Commandes sur les livres sélectionnés dans la fenêtre au premier plan.
///
/// La fenêtre principale la recopie dans `MenuState` ; la barre des menus en reçoit les valeurs. Le self-test appelle
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

    // MARK: Envoyer à la liseuse

    /// « Envoyer sur « Kindle de Léa » », « Envoyer à la connexion »… comme le bouton de la fiche.
    var sendTitle: String { KindleSendLabel.title(kindle) }

    var canSend: Bool {
        guard list != .trash, !kindle.isBusy else { return false }
        let sendable = books.filter(kindle.canSend)
        guard !sendable.isEmpty else { return false }
        // Kindle débranchée et tout déjà en attente : la commande n'aurait aucun effet.
        return kindle.isConnected || sendable.contains { !$0.isPendingSend }
    }

    /// Envoie tout de suite si la liseuse est branchée, sinon met en attente (annulable avec ⌘Z).
    func send() {
        guard canSend else { return }
        if kindle.isConnected {
            let books = books, kindle = kindle, library = library
            Task { await kindle.send(books, library: library) }
        } else {
            let reader = kindle.readers.count == 1 ? kindle.readers[0].id : nil
            library.undoable("Envoyer à la connexion") { library.queueForKindle(books, reader: reader) }
            SendNotifier.prepare()
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

    // MARK: Partager

    /// Fichiers principaux des livres sélectionnés, pour Partager (AirDrop, Mail…).
    var shareURLs: [URL] { books.map(\.url) }

    // MARK: Fichiers

    var canReveal: Bool { !books.isEmpty }

    func reveal() {
        guard canReveal else { return }
        NSWorkspace.shared.activateFileViewerSelecting(books.map(\.url))
    }

    /// Lire dans Alexandrie (S-066) : un livre sans DRM, présent sur le disque, hors de la corbeille.
    var canRead: Bool {
        guard books.count == 1, let book = books.first else { return false }
        return book.canRead && book.trashedAt == nil && !library.isUnavailable(book)
    }

    func read() {
        guard canRead, let book = books.first else { return }
        ReaderWindows.open(book.id)
    }

    /// Ouvrir dans l'app par défaut : un livre à la fois, comme le menu du livre.
    var canOpen: Bool { books.count == 1 }

    func open() {
        guard canOpen, let book = books.first else { return }
        NSWorkspace.shared.open(book.url)
    }

    /// Un seul MOBI, AZW3 ou AZW sans DRM.
    var canExportEPUB: Bool {
        guard books.count == 1, let book = books.first else { return false }
        return [.mobi, .azw3, .azw].contains(book.format) && !book.isDRMProtected
    }

    func exportEPUB() {
        guard canExportEPUB, let book = books.first else { return }
        let library = library
        Task { await Panels.exportEPUB(book, library: library) }
    }
}

/// État des menus Livre et Kindle, recopié depuis la fenêtre principale.
///
/// Les `Commands` SwiftUI ne suivent ni un modèle `@Observable`, ni `@FocusedValue` de façon fiable
/// (menus restés actifs sans sélection). Ce qui marche : un `ObservableObject` observé par l'`App`,
/// qui passe les valeurs aux menus ; l'`App` les reconstruit quand elles changent.
@MainActor
final class MenuState: ObservableObject {
    static let shared = MenuState()

    /// Ce que les menus affichent : intitulé d'envoi et éléments actifs.
    struct Values: Equatable {
        var sendTitle = "Envoyer à la liseuse"
        var canSend = false, canTrash = false, canQuickLook = false
        var canOpen = false, canReveal = false, canExportEPUB = false, canRead = false
        var shareURLs: [URL] = []

        init() {}

        @MainActor init(_ c: BookCommands) {
            sendTitle = c.sendTitle
            canSend = c.canSend
            canTrash = c.canTrash
            canQuickLook = c.canQuickLook
            canOpen = c.canOpen
            canReveal = c.canReveal
            canExportEPUB = c.canExportEPUB
            canRead = c.canRead
            shareURLs = c.shareURLs
        }
    }

    @Published private(set) var values = Values()
    /// Commandes de la sélection actuelle, relues quand un élément de menu est choisi.
    var current: BookCommands?

    func update(_ commands: BookCommands) {
        current = commands
        let new = Values(commands)
        if new != values { values = new }
    }
}
