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

    // MARK: Fichiers

    var canReveal: Bool { !books.isEmpty }

    func reveal() {
        guard canReveal else { return }
        NSWorkspace.shared.activateFileViewerSelecting(books.map(\.url))
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

extension SidebarItem {
    /// Pages où « Mettre à la corbeille » est proposé (menu du livre, menu Livre, touche Supprimer).
    var allowsTrash: Bool {
        switch self {
        case .all, .recent, .toReview, .format, .author, .series, .genre: true
        case .sent, .pending, .shelf, .trash, .kindle, .notes: false
        }
    }
}

extension SidebarItem {
    /// Forme texte, pour garder la page d'un lancement à l'autre (`@SceneStorage`).
    var storageKey: String {
        switch self {
        case .all: "all"
        case .recent: "recent"
        case .sent: "sent"
        case .toReview: "toReview"
        case .kindle: "kindle"
        case .pending: "pending"
        case .trash: "trash"
        case .notes: "notes"
        case .shelf(let id): "shelf:" + id
        case .format(let f): "format:" + f.rawValue
        case .author(let key): "author:" + key
        case .series(let key): "series:" + key
        case .genre(let key): "genre:" + key
        }
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? parts[1] : nil) {
        case ("all", nil): self = .all
        case ("recent", nil): self = .recent
        case ("sent", nil): self = .sent
        case ("toReview", nil): self = .toReview
        case ("kindle", nil): self = .kindle
        case ("pending", nil): self = .pending
        case ("trash", nil): self = .trash
        case ("notes", nil): self = .notes
        case ("shelf", let id?): self = .shelf(id)
        case ("format", let f?): guard let format = BookFormat(rawValue: f) else { return nil }; self = .format(format)
        case ("author", let key?): self = .author(key)
        case ("series", let key?): self = .series(key)
        case ("genre", let key?): self = .genre(key)
        default: return nil
        }
    }
}

extension FocusedValues {
    /// Sélection de la fenêtre principale au premier plan, pour la barre des menus.
    @Entry var bookCommands: BookCommands?
}
