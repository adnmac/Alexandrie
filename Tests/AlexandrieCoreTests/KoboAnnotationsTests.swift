import Foundation
import SQLite3
import Testing
@testable import AlexandrieCore

@Suite struct KoboAnnotationsTests {
    /// Base d'exemple au schéma de la Kobo ; `color` false : modèle noir et blanc, sans colonne `Color`.
    func makeDatabase(color: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kobo-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE content (ContentID TEXT PRIMARY KEY, ContentType INTEGER, Title TEXT, Attribution TEXT);
            CREATE TABLE Bookmark (BookmarkID TEXT PRIMARY KEY, VolumeID TEXT, ContentID TEXT, Text TEXT, Annotation TEXT,
                DateCreated TEXT, ChapterProgress REAL, Hidden TEXT, Type TEXT\(color ? ", Color INTEGER" : ""));
            INSERT INTO content VALUES ('file:///mnt/onboard/Books/candide.epub', 6, 'Candide', 'Voltaire');
            INSERT INTO content VALUES ('file:///mnt/onboard/Books/candide.epub!!ch3', 9, 'Chapitre troisième', NULL);
            INSERT INTO Bookmark VALUES ('b1', 'file:///mnt/onboard/Books/candide.epub', 'file:///mnt/onboard/Books/candide.epub!!ch3',
                'Il faut cultiver notre jardin.', 'La phrase finale', '2026-11-08T09:30:00.000', 0.4, 'false', 'highlight'\(color ? ", 2" : ""));
            INSERT INTO Bookmark VALUES ('b2', 'file:///mnt/onboard/Books/candide.epub', NULL,
                'Tout est au mieux.', NULL, '2026-11-07T08:00:00Z', NULL, 'false', 'highlight'\(color ? ", 0" : ""));
            INSERT INTO Bookmark VALUES ('b3', 'file:///mnt/onboard/Books/Inconnu - Auteur.kepub.epub', NULL,
                NULL, 'Note seule', '2026-11-08T10:00:00', 0.1, 'false', 'note'\(color ? ", NULL" : ""));
            INSERT INTO Bookmark VALUES ('b4', 'file:///mnt/onboard/Books/candide.epub', NULL,
                NULL, NULL, '2026-11-08T11:00:00', 0.5, 'false', 'dogear'\(color ? ", NULL" : ""));
            INSERT INTO Bookmark VALUES ('b5', 'file:///mnt/onboard/Books/candide.epub', NULL,
                'Supprimé', NULL, '2026-11-08T12:00:00', 0.5, 'true', 'highlight'\(color ? ", NULL" : ""));
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func readsHighlightsAndNotes() throws {
        let url = try makeDatabase()
        let before = try Data(contentsOf: url)
        let clippings = try KoboAnnotations.read(database: url)
        #expect(clippings.map(\.uid) == ["kobo:b2", "kobo:b1", "kobo:b3"], "ordre de création ; signets et passages masqués écartés")
        let garden = clippings[1]
        #expect(garden.title == "Candide" && garden.author == "Voltaire" && garden.kind == .highlight)
        #expect(garden.text == "Il faut cultiver notre jardin." && garden.note == "La phrase finale")
        #expect(garden.location == "Chapitre troisième · 40 %")
        #expect(garden.color == .blue)
        #expect(garden.added.hasPrefix("dimanche 8 novembre 2026"))
        #expect(clippings[0].color == nil, "0 : jaune, la couleur par défaut")
        let alone = clippings[2]
        #expect(alone.kind == .note && alone.text == "Note seule" && alone.note == nil)
        #expect(alone.title == "Inconnu - Auteur", "titre tiré du fichier quand le livre manque dans `content`")
        #expect(try Data(contentsOf: url) == before, "base de la liseuse jamais modifiée")
        // Identifiants stables : une seconde lecture donne les mêmes relevés.
        #expect(try KoboAnnotations.read(database: url).map(\.id) == clippings.map(\.id))
    }

    @Test func toleratesBlackAndWhiteModels() throws {
        let clippings = try KoboAnnotations.read(database: try makeDatabase(color: false))
        #expect(clippings.count == 3 && clippings.allSatisfy { $0.color == nil })
    }

    @Test func refusesOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vide-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE autre (x TEXT);", nil, nil, nil)
        sqlite3_close(db)
        #expect(throws: KoboAnnotations.Failure.self) { try KoboAnnotations.read(database: url) }
        #expect(throws: KoboAnnotations.Failure.self) {
            try KoboAnnotations.read(database: url.appendingPathExtension("absente"))
        }
    }
}
