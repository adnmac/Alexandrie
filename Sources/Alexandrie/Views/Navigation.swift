import AlexandrieCore
import SwiftUI

enum SidebarItem: Hashable {
    case all, recent, sent, toReview, kindle
    /// Livres en attente d'envoi (Kindle débranchée).
    case pending
    /// Corbeille d'Alexandrie.
    case trash
    /// Étagère d'une liseuse (identifiant de la Kindle).
    case shelf(String)
    /// Notes et surlignages importés des Kindle.
    case notes
    /// Toutes les notes d'une thématique (S-080), par son identifiant.
    case thematic(String)
    case format(BookFormat)
    /// Clé de regroupement (voir `AuthorNames`), pas une graphie particulière.
    case author(String)
    /// Clé de regroupement de série (voir `SeriesNames`).
    case series(String)
    /// Clé de regroupement de genre (voir `GenreNames`).
    case genre(String)
    /// Dossier de livres (chemin), quand la bibliothèque en a plusieurs.
    case folder(String)
    /// Catalogue OPDS en ligne (S-086), par son identifiant.
    case catalog(String)
}

extension EnvironmentValues {
    /// Liste affichée (barre latérale) : le menu d'un livre propose de le retirer de cette liste.
    @Entry var libraryList: SidebarItem?
}

enum SortOrder: String, CaseIterable, Identifiable {
    case title = "Titre", author = "Auteur", added = "Date d'ajout"
    var id: Self { self }
}

extension SidebarItem {
    /// Page d'une thématique (S-080).
    var isThematic: Bool { if case .thematic = self { true } else { false } }

    /// Catalogue OPDS en ligne (S-086).
    var catalogID: String? { if case .catalog(let id) = self { id } else { nil } }

    /// Pages où « Mettre à la corbeille » est proposé (menu du livre, menu Livre, touche Supprimer).
    var allowsTrash: Bool {
        switch self {
        case .all, .recent, .toReview, .format, .author, .series, .genre, .folder: true
        case .sent, .pending, .shelf, .trash, .kindle, .notes, .thematic, .catalog: false
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
        case .thematic(let id): "thematic:" + id
        case .shelf(let id): "shelf:" + id
        case .format(let f): "format:" + f.rawValue
        case .author(let key): "author:" + key
        case .series(let key): "series:" + key
        case .genre(let key): "genre:" + key
        case .folder(let path): "folder:" + path
        case .catalog(let id): "catalog:" + id
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
        case ("thematic", let id?): self = .thematic(id)
        case ("shelf", let id?): self = .shelf(id)
        case ("format", let f?): guard let format = BookFormat(rawValue: f) else { return nil }; self = .format(format)
        case ("author", let key?): self = .author(key)
        case ("series", let key?): self = .series(key)
        case ("genre", let key?): self = .genre(key)
        case ("folder", let path?): self = .folder(path)
        case ("catalog", let id?): self = .catalog(id)
        default: return nil
        }
    }
}
