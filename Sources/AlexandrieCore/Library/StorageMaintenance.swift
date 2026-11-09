import Foundation

/// Ménage du dossier de l'app : couvertures et copies converties qui ne servent plus.
public enum StorageMaintenance {
    public struct Report: Equatable, Sendable {
        public var removedFiles = 0
        public var freedBytes: Int64 = 0
    }

    /// Supprime les couvertures des livres disparus et les conversions périmées
    /// (livre disparu, ou copie faite avant une correction des informations).
    @discardableResult
    public static func purge(keeping books: [Book], directories: AppDirectories) -> Report {
        // Les livres d'un format inconnu de cette version (gardés dans l'index) conservent leur couverture.
        let fingerprints = Set(books.map(\.fingerprint)).union(LibraryIndex.otherFormatFingerprints(directories.index))
        let covers = Set(fingerprints.map { CoverStore(directory: directories.covers).url(for: $0).lastPathComponent })
        let conversions = Set(books.flatMap { b in
            [KindleTransfer.cachedCopy(of: b, directories: directories),
             KindleTransfer.exportedEPUB(of: b, directories: directories)].map(\.lastPathComponent)
        })
        var report = Report()
        for (dir, keep) in [(directories.covers, covers), (directories.conversions, conversions)] {
            for file in files(in: dir) where !keep.contains(file.url.lastPathComponent) {
                if (try? FileManager.default.removeItem(at: file.url)) != nil {
                    report.removedFiles += 1
                    report.freedBytes += file.size
                }
            }
        }
        return report
    }

    /// Taille totale des fichiers d'un dossier (non récursif : les dossiers de l'app sont plats).
    public static func size(of directory: URL) -> Int64 {
        files(in: directory).reduce(0) { $0 + $1.size }
    }

    /// Vide un dossier de cache ; son contenu est recréé à la demande.
    public static func clear(_ directory: URL) {
        for file in files(in: directory) { try? FileManager.default.removeItem(at: file.url) }
    }

    private static func files(in directory: URL) -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, Int64(v.fileSize ?? 0))
        }
    }
}

extension StorageMaintenance {
    /// Livres préparés pour la lecture dont le fichier a disparu ou changé (empreinte inconnue).
    public static func purgeReading(keeping books: [Book], directories: AppDirectories) {
        let keep = Set(books.map(\.fingerprint)).union(LibraryIndex.otherFormatFingerprints(directories.index))
        let folders = (try? FileManager.default.contentsOfDirectory(at: directories.reading, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
