import Foundation

/// Copies datées de l'index (dossier Sauvegardes de l'app) : une par jour, les plus récentes gardées.
public enum IndexBackups {
    public struct Backup: Hashable, Sendable {
        public let url: URL
        public let date: Date
    }


    private static var dayFormat: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Copie l'index s'il n'existe pas encore de sauvegarde du jour, puis ne garde que les `keep` plus récentes.
    /// Renvoie la copie créée, nil si celle du jour existait déjà (ou s'il n'y a pas d'index).
    @discardableResult
    /// `name` distingue les fichiers sauvegardés (« library », « clippings »).
    public static func backUpToday(_ index: URL, to dir: URL, name: String = "library", now: Date = Date(),
                                   keep: Int = 10) throws -> URL? {
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(name + "-" + dayFormat.string(from: now) + ".json")
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        try FileManager.default.copyItem(at: index, to: target)
        for old in list(dir, name: name).dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
        return target
    }

    /// Sauvegardes du jour, de la plus récente à la plus ancienne.
    public static func list(_ dir: URL, name: String = "library") -> [Backup] {
        let prefix = name + "-"
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Backup? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", name.hasPrefix(prefix),
                  let date = dayFormat.date(from: String(name.dropFirst(prefix.count))) else { return nil }
            return Backup(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }
}
