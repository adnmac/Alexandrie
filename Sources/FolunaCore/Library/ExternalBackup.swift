import Foundation

/// Sauvegarde de la bibliothèque dans un dossier choisi par l'utilisateur (iCloud Drive, disque externe).
///
///     <dossier choisi>/Sauvegarde Foluna/
///         Données/2026-11-08/library.json, clippings.json…   une copie par jour, les 30 dernières gardées
///         Imports/                                          copie à jour des livres importés ou téléchargés
///         Covers/                                           copie à jour des couvertures
///
/// Les caches qui se reconstruisent (conversions, texte indexé, livres préparés pour la lecture) ne sont pas copiés.
public enum ExternalBackup {
    public static let folderName = "Sauvegarde Foluna"
    /// Nom d'avant Foluna : un dossier existant est renommé à la première sauvegarde.
    public static let legacyFolderName = "Sauvegarde Alexandrie"  // nom d'origine : ne pas changer
    /// Fichiers de données copiés chaque jour (ceux qui manquent sont ignorés).
    public static let dataFiles = ["library.json", "folders.json", "readers.json", "reading.json",
                                   "clippings.json", "researches.json", "opds.json", "zotero.json"]
    /// Dossiers tenus à jour (fichiers nouveaux ou modifiés copiés, fichiers disparus retirés).
    public static let mirroredFolders = ["Imports", "Covers"]
    public static let defaultKeep = 30

    public struct Snapshot: Hashable, Sendable, Identifiable {
        public let url: URL
        public let date: Date
        public var id: URL { url }
    }

    public struct Report: Equatable, Sendable {
        public var snapshot: URL
        public var dataFiles: Int
        /// Fichiers copiés et retirés dans les dossiers tenus à jour.
        public var copied: Int
        public var removed: Int
    }

    public enum Failure: LocalizedError, Equatable {
        case destinationMissing(String)
        case nothingToSave
        case emptySnapshot

        public var errorDescription: String? {
            switch self {
            case .destinationMissing(let path): String(localized: "Dossier de sauvegarde introuvable (\(path)) : disque débranché ou dossier déplacé.")
            case .nothingToSave: String(localized: "Aucune donnée à sauvegarder pour l'instant.")
            case .emptySnapshot: String(localized: "Cette sauvegarde ne contient aucun fichier de données.")
            }
        }
    }

    public static func root(in destination: URL) -> URL {
        let root = destination.appendingPathComponent(folderName, isDirectory: true)
        let legacy = destination.appendingPathComponent(legacyFolderName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: root)
            if !fm.fileExists(atPath: root.path) { return legacy }
        }
        return root
    }

    static var dayFormat: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    // MARK: - Sauvegarde

    /// Copie les données du jour (remplace une copie du même jour), puis tient à jour Imports et Covers.
    /// Les données sont écrites dans un dossier provisoire puis renommées : une coupure ne laisse jamais
    /// une sauvegarde à moitié écrite sous un nom de date.
    @discardableResult
    public static func backUp(_ directories: AppDirectories, to destination: URL, now: Date = Date(),
                              keep: Int = defaultKeep) throws -> Report {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.destinationMissing(destination.path)
        }
        let sources = dataFiles.map { directories.base.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { throw Failure.nothingToSave }

        let root = root(in: destination)
        let data = root.appendingPathComponent("Données", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let day = data.appendingPathComponent(dayFormat.string(from: now), isDirectory: true)
        let partial = data.appendingPathComponent(".en-cours-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            for source in sources {
                try fm.copyItem(at: source, to: partial.appendingPathComponent(source.lastPathComponent))
            }
            if fm.fileExists(atPath: day.path) { try fm.removeItem(at: day) }
            try fm.moveItem(at: partial, to: day)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        var copied = 0, removed = 0
        for name in mirroredFolders {
            let result = try mirror(directories.base.appendingPathComponent(name, isDirectory: true),
                                    to: root.appendingPathComponent(name, isDirectory: true))
            copied += result.copied
            removed += result.removed
        }
        for old in snapshots(in: destination).dropFirst(max(keep, 1)) { try? fm.removeItem(at: old.url) }
        return Report(snapshot: day, dataFiles: sources.count, copied: copied, removed: removed)
    }

    /// Copies datées, de la plus récente à la plus ancienne.
    public static func snapshots(in destination: URL) -> [Snapshot] {
        let data = root(in: destination).appendingPathComponent("Données", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url in
            dayFormat.date(from: url.lastPathComponent).map { Snapshot(url: url, date: $0) }
        }
        .sorted { $0.date > $1.date }
    }

    /// Rend `target` identique à `source` (taille et date de modification comparées).
    /// Un dossier source absent ne vide jamais la copie.
    static func mirror(_ source: URL, to target: URL) throws -> (copied: Int, removed: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return (0, 0) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        func files(_ dir: URL) -> [String: URL] {
            let list = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return Dictionary(list.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
                .map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let have = files(target)
        let want = files(source)
        var copied = 0, removed = 0
        for (name, url) in want {
            let s = try url.resourceValues(forKeys: Set(keys))
            if let existing = have[name], let t = try? existing.resourceValues(forKeys: Set(keys)),
               t.fileSize == s.fileSize, sameDate(t.contentModificationDate, s.contentModificationDate) { continue }
            let dest = target.appendingPathComponent(name)
            if have[name] != nil { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            if let date = s.contentModificationDate {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: dest.path)
            }
            copied += 1
        }
        for (name, url) in have where want[name] == nil {
            try fm.removeItem(at: url)
            removed += 1
        }
        return (copied, removed)
    }

    /// Dates de modification égales à la seconde près (la copie perd les fractions sur certains volumes).
    static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 1
    }

    // MARK: - Restauration

    /// Remet les données d'une copie datée et les fichiers d'Imports et Covers qui manquent.
    /// L'état actuel est d'abord mis de côté dans `Sauvegardes/avant-restauration-<date>` (rendu).
    /// À faire avant que l'app lise ses données : au lancement (voir `PendingRestore`).
    @discardableResult
    public static func restore(_ snapshot: URL, from destination: URL, into directories: AppDirectories,
                               now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let files = dataFiles.filter { fm.fileExists(atPath: snapshot.appendingPathComponent($0).path) }
        guard !files.isEmpty else { throw Failure.emptySnapshot }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let aside = directories.backups.appendingPathComponent("avant-restauration-\(stamp.string(from: now))", isDirectory: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        for name in dataFiles {
            let current = directories.base.appendingPathComponent(name)
            if fm.fileExists(atPath: current.path) { try fm.moveItem(at: current, to: aside.appendingPathComponent(name)) }
        }
        for name in files {
            try fm.copyItem(at: snapshot.appendingPathComponent(name), to: directories.base.appendingPathComponent(name))
        }
        // Livres et couvertures : seuls les fichiers absents reviennent, rien n'est effacé.
        for folder in mirroredFolders {
            let saved = root(in: destination).appendingPathComponent(folder, isDirectory: true)
            let local = directories.base.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: local, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: saved, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let target = local.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
            }
        }
        return aside
    }
}

/// Restauration demandée, appliquée au lancement suivant avant que l'app lise ses données
/// (à la fermeture, l'app enregistre son état et écraserait des fichiers restaurés en cours de route).
public struct PendingRestore: Codable, Equatable, Sendable {
    public var snapshot: URL
    public var destination: URL

    public init(snapshot: URL, destination: URL) {
        self.snapshot = snapshot
        self.destination = destination
    }

    static func file(_ directories: AppDirectories) -> URL { directories.base.appendingPathComponent("restauration.json") }

    public func schedule(_ directories: AppDirectories) throws {
        try JSONEncoder().encode(self).write(to: Self.file(directories), options: .atomic)
    }

    public static func pending(_ directories: AppDirectories) -> PendingRestore? {
        (try? Data(contentsOf: file(directories))).flatMap { try? JSONDecoder().decode(PendingRestore.self, from: $0) }
    }

    /// Applique la restauration en attente, une seule fois (la demande est effacée même en cas d'échec).
    /// Rend nil s'il n'y en avait pas, sinon le résultat.
    public static func apply(_ directories: AppDirectories, now: Date = Date()) -> Result<URL, any Error>? {
        guard let request = pending(directories) else { return nil }
        try? FileManager.default.removeItem(at: file(directories))
        return Result { try ExternalBackup.restore(request.snapshot, from: request.destination, into: directories, now: now) }
    }
}
