import Foundation
import SQLite3

/// Notes et surlignages d'une Kobo, lus dans sa base `.kobo/KoboReader.sqlite`.
/// La base est copiée puis ouverte en lecture seule : le fichier de la liseuse n'est jamais modifié.
///
/// Schéma connu (Kobo 4.x et suivantes), vérifié colonne par colonne :
/// - `Bookmark` : `BookmarkID`, `VolumeID` (le livre), `ContentID` (le chapitre), `Text`, `Annotation`,
///   `DateCreated`, `ChapterProgress`, `Hidden`, `Type` (`highlight`, `note`, `dogear`), `Color` (modèles couleur) ;
/// - `content` : `ContentID`, `Title`, `Attribution` (auteur), `ContentType` (6 : un livre).
public enum KoboAnnotations {
    public enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        public var errorDescription: String? {
            switch self { case .unreadable(let why): "Base de notes de la Kobo illisible : \(why)." }
        }
    }

    /// Chemin de la base sur le disque de la Kobo.
    public static func database(onVolume root: URL) -> URL {
        root.appendingPathComponent(".kobo/KoboReader.sqlite")
    }

    public static func read(database: URL) throws -> [Clipping] {
        // Copie de travail (avec les journaux WAL s'il y en a) : la liseuse peut tenir la base ouverte.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("alexandrie-kobo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("KoboReader.sqlite")
        do { try fm.copyItem(at: database, to: copy) } catch { throw Failure.unreadable(error.localizedDescription) }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: database.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw Failure.unreadable("ouverture impossible")
        }
        defer { sqlite3_close(db) }

        let bookmark = columns(db, "Bookmark")
        guard bookmark.contains("bookmarkid"), bookmark.contains("volumeid"), bookmark.contains("text") else {
            throw Failure.unreadable("table Bookmark absente")
        }
        let content = columns(db, "content")
        func col(_ name: String, in set: Set<String>, table: String, or fallback: String = "NULL") -> String {
            set.contains(name.lowercased()) ? "\(table).\(name)" : fallback
        }
        let hasContent = content.contains("contentid")
        let sql = """
            SELECT b.BookmarkID, b.Text, \(col("Annotation", in: bookmark, table: "b")),
                   \(col("DateCreated", in: bookmark, table: "b")), \(col("ChapterProgress", in: bookmark, table: "b")),
                   \(col("Color", in: bookmark, table: "b")), \(col("Type", in: bookmark, table: "b")),
                   \(col("Hidden", in: bookmark, table: "b")),
                   \(hasContent ? col("Title", in: content, table: "v") : "NULL"),
                   \(hasContent ? col("Attribution", in: content, table: "v") : "NULL"),
                   \(hasContent && bookmark.contains("contentid") ? col("Title", in: content, table: "c") : "NULL"),
                   b.VolumeID
            FROM Bookmark b
            \(hasContent ? "LEFT JOIN content v ON v.ContentID = b.VolumeID" : "")
            \(hasContent && bookmark.contains("contentid") ? "LEFT JOIN content c ON c.ContentID = b.ContentID" : "")
            \(bookmark.contains("datecreated") ? "ORDER BY b.DateCreated" : "")
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [Clipping] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? {
                guard let p = sqlite3_column_text(stmt, i) else { return nil }
                let s = String(cString: p).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            let type = text(6)?.lowercased()
            guard type != "dogear", text(7)?.lowercased() != "true", let id = text(0) else { continue }
            let passage = text(1)
            let note = text(2)
            guard passage != nil || note != nil else { continue }
            let volume = text(11) ?? ""
            let title = text(8) ?? Self.title(fromVolume: volume)
            var c = Clipping(title: title, author: text(9) ?? "", kind: passage == nil ? .note : .highlight,
                             location: location(chapter: text(10), progress: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                                ? nil : sqlite3_column_double(stmt, 4)),
                             added: added(text(3)), text: passage ?? note ?? "")
            c.uid = "kobo:" + id
            if passage != nil { c.note = note }
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL { c.color = color(Int(sqlite3_column_int(stmt, 5))) }
            out.append(c)
        }
        return out
    }

    /// Colonnes d'une table, en minuscules (vide si la table n'existe pas).
    static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_text(stmt, 1) { names.insert(String(cString: p).lowercased()) }
        }
        return names
    }

    /// Titre tiré du chemin du livre (« file:///mnt/onboard/Books/Candide - Voltaire.epub » → « Candide - Voltaire »).
    static func title(fromVolume volume: String) -> String {
        let name = (volume as NSString).lastPathComponent
        let base = name.lowercased().hasSuffix(".kepub.epub") ? String(name.dropLast(".kepub.epub".count))
            : (name as NSString).deletingPathExtension
        return base.isEmpty ? "Livre de la Kobo" : base
    }

    /// « Chapitre premier · 40 % » : la Kobo situe un passage par chapitre et progression dans le chapitre.
    static func location(chapter: String?, progress: Double?) -> String {
        let percent = progress.map { "\(Int(($0 * 100).rounded())) %" }
        return [chapter, percent].compactMap { $0 }.joined(separator: " · ")
    }

    /// Date lisible en français, comme les relevés de la Kindle (« dimanche 8 novembre 2026 10:12:33 »).
    static func added(_ raw: String?) -> String {
        guard let raw else { return "" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        var date: Date?
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSS",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] where date == nil {
            parser.dateFormat = format
            date = parser.date(from: raw)
        }
        guard let date else { return raw }
        let out = DateFormatter()
        out.locale = Locale(identifier: "fr_FR")
        out.dateFormat = "EEEE d MMMM yyyy HH:mm:ss"
        return out.string(from: date)
    }

    /// Couleurs des Kobo couleur (supposé : 0 jaune, 1 rose, 2 bleu, 3 vert ; à confirmer sur un appareil).
    static func color(_ value: Int) -> HighlightColor? {
        switch value {
        case 1: .pink
        case 2: .blue
        case 3: .green
        default: nil
        }
    }
}
