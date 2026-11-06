import Foundation

/// Dossiers de livres de la bibliothèque (S-060 à S-063) : liste enregistrée, dossier d'un livre,
/// ajouts refusés. Les dossiers sont lus, jamais modifiés.
public enum LibraryFolders {
    /// Raison d'un ajout refusé : le dossier est déjà lu, en entier ou en partie.
    public enum Conflict: Equatable, Sendable {
        /// Déjà dans la liste.
        case same
        /// À l'intérieur d'un dossier de la liste (chemin de ce dossier).
        case inside(String)
        /// Contient un dossier de la liste (chemin de ce dossier).
        case contains(String)

        public var message: String {
            switch self {
            case .same: "Ce dossier fait déjà partie de la bibliothèque."
            case .inside(let parent): "Ce dossier est déjà lu avec « \(LibraryFolders.name(of: parent)) »."
            case .contains(let child): "Ce dossier contient « \(LibraryFolders.name(of: child)) », déjà dans la bibliothèque. Retirez-le d'abord."
            }
        }
    }

    /// Chemin terminé par « / », pour qu'un dossier « Livres » ne contienne pas « Livres anciens ».
    public static func prefix(_ path: String) -> String {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return p.hasSuffix("/") ? p : p + "/"
    }

    /// Nom affiché d'un dossier (son dernier élément).
    public static func name(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Dossier de la liste qui contient ce fichier (le plus précis), ou nil (import, dossier retiré).
    public static func owner(of path: String, among folders: [String]) -> String? {
        folders.filter { path.hasPrefix(prefix($0)) }.max { $0.count < $1.count }
    }

    /// Pourquoi `path` ne peut pas rejoindre `folders`, ou nil s'il le peut.
    public static func conflict(adding path: String, to folders: [String]) -> Conflict? {
        let new = prefix(path)
        for folder in folders {
            let existing = prefix(folder)
            if new == existing { return .same }
            if new.hasPrefix(existing) { return .inside(folder) }
            if existing.hasPrefix(new) { return .contains(folder) }
        }
        return nil
    }

    // MARK: - Liste enregistrée (folders.json)

    /// Un dossier de livres enregistré : son chemin (affiché même quand son disque est débranché)
    /// et un signet qui le suit s'il est déplacé ou renommé.
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var bookmark: Data?

        public init(path: String, bookmark: Data?) {
            self.path = URL(fileURLWithPath: path).standardizedFileURL.path
            self.bookmark = bookmark
        }

        public init(_ url: URL) {
            self.init(path: url.path, bookmark: LibraryFolders.bookmark(url))
        }

        /// Chemin à jour : celui du signet s'il se résout, sinon le chemin enregistré (disque débranché).
        /// `changed` dit si l'entrée doit être réenregistrée.
        public func resolved() -> (entry: Entry, changed: Bool) {
            guard let bookmark else { return (self, false) }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return (self, false) }
            let path = url.standardizedFileURL.path
            guard stale || path != self.path else { return (self, false) }
            return (Entry(path: path, bookmark: stale ? LibraryFolders.bookmark(url) ?? bookmark : bookmark), true)
        }
    }

    /// Dossiers enregistrés. Sans fichier, le signet unique d'avant M7 (`legacy`) devient le premier
    /// dossier : ses livres sont déjà dans l'index, rien n'est réindexé.
    public static func load(_ url: URL, legacy: Data?) -> [Entry] {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            return list
        }
        guard let legacy, let path = legacyPath(legacy) else { return [] }
        return [Entry(path: path, bookmark: legacy)]
    }

    public static func save(_ entries: [Entry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// Chemin d'un ancien signet, lu sans monter de disque.
    static func legacyPath(_ bookmark: Data) -> String? {
        if let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark), let path = values.path {
            return path
        }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                         relativeTo: nil, bookmarkDataIsStale: &stale))?.path
    }

    /// Signet d'un dossier (sans bac à sable : l'app n'en a pas).
    public static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
