import Foundation
import Testing
@testable import AlexandrieCore

@Suite struct LibraryIndexTests {
    @Test func missingIndexIsEmpty() throws {
        #expect(try LibraryIndex.load(temp("json")).isEmpty)
    }

    @Test func corruptIndexThrowsAndIsQuarantined() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent("library.json")
        try Data("[{\"path\": 1".utf8).write(to: url)
        #expect(throws: (any Error).self) { try LibraryIndex.load(url) }

        let moved = try LibraryIndex.quarantine(url, now: Date(timeIntervalSince1970: 0))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(moved.lastPathComponent.hasPrefix("library.corrupt-"))
        #expect(try Data(contentsOf: moved) == Data("[{\"path\": 1".utf8))
    }

    @Test func roundTrip() throws {
        let lib = SampleLibrary()
        var book = try lib.index("Candide.epub")
        book.title = "Candide corrigé"
        let url = lib.dir.appendingPathComponent("library.json")
        try LibraryIndex.save([book], to: url)
        #expect(try LibraryIndex.load(url) == [book])
    }

    /// Index écrit par une version plus récente (format inconnu ici) : lisible, et l'entrée inconnue survit
    /// aux enregistrements, pour revenir intacte avec la version qui la connaît.
    @Test func unknownFormatIsKeptAside() throws {
        let lib = SampleLibrary()
        var book = try lib.index("Candide.epub")
        let url = lib.dir.appendingPathComponent("library.json")
        try LibraryIndex.save([book], to: url)
        // Entrée ajoutée au texte tel quel : l'entrée connue n'est pas réécrite.
        let future = #"{"path":"/Livres/Futur.xyz","format":"xyz","fingerprint":"futur-1","fileSize":123456789012,"#
            + #""modifiedAt":784111777.25,"champNouveau":{"a":1},"tags":["x"],"hasCover":true}"#
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        try Data((text.dropLast() + "," + future + "]").utf8).write(to: url)

        #expect(try LibraryIndex.load(url) == [book])
        #expect(LibraryIndex.otherFormatFingerprints(url) == ["futur-1"])

        book.title = "Candide corrigé"
        try LibraryIndex.save([book], to: url)
        #expect(try LibraryIndex.load(url) == [book])
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let kept = try #require(saved.first { $0["format"] as? String == "xyz" })
        #expect(kept["path"] as? String == "/Livres/Futur.xyz")
        #expect((kept["champNouveau"] as? [String: Any])?["a"] as? Int == 1)
        #expect(kept["fileSize"] as? Int == 123_456_789_012)
        #expect(kept["modifiedAt"] as? Double == 784111777.25)
        #expect(kept["hasCover"] as? Bool == true)
    }

    /// Retour possible à la 0.6.0 : `library.json` ne contient que les formats qu'elle sait lire ; les autres
    /// livres sont dans `library.formats.json`, relus avec l'index.
    @Test func recentFormatsStayOutOfMainIndex() throws {
        let lib = SampleLibrary()
        let epub = try lib.index("Candide.epub")
        let fb2 = try lib.index("Fleuve.fb2")
        let cbz = try lib.index("Album.cbz")
        let url = lib.dir.appendingPathComponent("library.json")
        try LibraryIndex.save([epub, fb2, cbz], to: url)

        let formatsOf060: Set<String> = ["epub", "mobi", "azw3", "azw", "pdf"]
        let main = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(main.allSatisfy { formatsOf060.contains($0["format"] as? String ?? "") })
        #expect(main.count == 1)
        let side = LibraryIndex.formatsFile(of: url)
        #expect(side.lastPathComponent == "library.formats.json")
        #expect(Set(try LibraryIndex.load(url).map(\.id)) == [epub.id, fb2.id, cbz.id])

        // Plus aucun livre d'un format récent : le fichier voisin disparaît.
        try LibraryIndex.save([epub], to: url)
        #expect(!FileManager.default.fileExists(atPath: side.path))
        #expect(try LibraryIndex.load(url) == [epub])
    }

    /// Fichier voisin abîmé : mis de côté seul, l'index principal reste lu.
    @Test func damagedFormatsFileKeepsMainIndex() throws {
        let lib = SampleLibrary()
        let epub = try lib.index("Candide.epub")
        let url = lib.dir.appendingPathComponent("library.json")
        try LibraryIndex.save([epub], to: url)
        let side = LibraryIndex.formatsFile(of: url)
        try Data("[{\"path\": 1".utf8).write(to: side)
        #expect(try LibraryIndex.load(url) == [epub])
        #expect(!FileManager.default.fileExists(atPath: side.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// La copie du jour garde aussi les livres des formats récents ; elle n'apparaît qu'une fois dans la liste.
    @Test func dailyBackupCopiesFormatsFile() throws {
        let lib = SampleLibrary()
        let url = lib.dir.appendingPathComponent("library.json")
        try LibraryIndex.save([try lib.index("Candide.epub"), try lib.index("Fleuve.fb2")], to: url)
        let dir = lib.dir.appendingPathComponent("Sauvegardes")
        let copy = try #require(try IndexBackups.backUpToday(url, to: dir, now: Date(timeIntervalSince1970: 0)))
        #expect(IndexBackups.list(dir).map(\.url.lastPathComponent) == [copy.lastPathComponent])
        #expect(try LibraryIndex.load(copy).count == 2)
    }

    /// Une entrée abîmée d'un format connu rend toujours l'index illisible (il sera mis de côté).
    @Test func damagedKnownEntryStillThrows() throws {
        let url = tempDirectory().appendingPathComponent("library.json")
        try Data(#"[{"path": "/a.epub", "format": "epub"}]"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try LibraryIndex.load(url) }
    }
}

@Suite struct LibraryMergeTests {
    @Test func keepsUnchangedFiles() throws {
        let lib = SampleLibrary()
        let book = try lib.index("Candide.epub")
        let plan = LibraryMerge.plan(files: FolderScanner.scan([lib.dir]), known: [book], importsPath: lib.imports)
        #expect(plan.kept.map(\.id) == [book.id])
        #expect(plan.changed.isEmpty)
    }

    @Test func renamedFileKeepsEdits() throws {
        let lib = SampleLibrary()
        var book = try lib.index("Candide.epub")
        book.title = "Candide, ou l’Optimisme"
        book.tags = ["conte"]
        let renamed = lib.dir.appendingPathComponent("Voltaire - Candide.epub")
        try FileManager.default.moveItem(at: book.url, to: renamed)

        let plan = LibraryMerge.plan(files: FolderScanner.scan([lib.dir]), known: [book], importsPath: lib.imports)
        #expect(plan.changed.isEmpty)
        let kept = try #require(plan.kept.first)
        #expect(kept.url.lastPathComponent == renamed.lastPathComponent)
        #expect(kept.title == "Candide, ou l’Optimisme")
        #expect(kept.tags == ["conte"])
        #expect(kept.asin == book.asin)
    }

    @Test func modifiedFileIsReadAgainWithPrevious() throws {
        let lib = SampleLibrary()
        let book = try lib.index("Candide.epub")
        try lib.write("Candide.epub", bytes: 9_000)

        let plan = LibraryMerge.plan(files: FolderScanner.scan([lib.dir]), known: [book], importsPath: lib.imports)
        #expect(plan.kept.isEmpty)
        #expect(plan.changed.count == 1)
        #expect(plan.changed.first?.previous?.id == book.id)
    }

    @Test func newFileHasNoPrevious() throws {
        let lib = SampleLibrary()
        let book = try lib.index("Candide.epub")
        try lib.write("Zadig.epub", bytes: 3_000)

        let plan = LibraryMerge.plan(files: FolderScanner.scan([lib.dir]), known: [book], importsPath: lib.imports)
        #expect(plan.kept.map(\.id) == [book.id])
        #expect(plan.changed.count == 1)
        #expect(plan.changed.first?.previous == nil)
    }

    @Test func movedCopyIsMatchedOnce() throws {
        let lib = SampleLibrary()
        let book = try lib.index("Candide.epub")
        let a = lib.dir.appendingPathComponent("a.epub"), b = lib.dir.appendingPathComponent("b.epub")
        try FileManager.default.copyItem(at: book.url, to: a)
        try FileManager.default.moveItem(at: book.url, to: b)

        let plan = LibraryMerge.plan(files: FolderScanner.scan([lib.dir]), known: [book], importsPath: lib.imports)
        #expect(plan.kept.count == 1)
        #expect(plan.changed.count == 1)
        #expect(plan.changed.first?.previous == nil)
    }

    @Test func carryOverKeepsAppEdits() throws {
        let lib = SampleLibrary()
        var previous = try lib.index("Candide.epub")
        previous.title = "Titre corrigé"
        previous.lastSentAt = Date(timeIntervalSince1970: 1)
        var fresh = try lib.index("Candide.epub")
        LibraryMerge.carryOver(from: previous, to: &fresh)
        #expect(fresh.title == "Titre corrigé")
        #expect(fresh.asin == previous.asin)
        #expect(fresh.lastSentAt == previous.lastSentAt)
    }
}

/// Dossier temporaire de faux livres (contenu illisible : le titre vient du nom de fichier).
struct SampleLibrary {
    let dir = tempDirectory()
    var imports: String { dir.appendingPathComponent("Imports").path }
    var covers: CoverStore { CoverStore(directory: dir) }

    func write(_ name: String, bytes: Int) throws {
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ name.count) })
            .write(to: dir.appendingPathComponent(name))
    }

    func index(_ name: String) throws -> Book {
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try write(name, bytes: 5_000) }
        let file = try #require(FolderScanner.scan([dir]).first { $0.url.lastPathComponent == name })
        return FolderScanner.makeBook(file, imported: false, coverStore: covers)
    }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("alexandrie-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct KindleQueueTests {
    @Test func pendingSendSurvivesRenameAndReread() throws {
        let lib = SampleLibrary()
        var book = try lib.index("Candide.epub")
        book.pendingSendAt = Date(timeIntervalSince1970: 100)
        // Fichier renommé : le livre est retrouvé par son empreinte, toujours en attente.
        let renamed = lib.dir.appendingPathComponent("Voltaire - Candide.epub")
        try FileManager.default.moveItem(at: book.url, to: renamed)
        let plan = LibraryMerge.plan(files: FolderScanner.scan([lib.dir]), known: [book], importsPath: lib.imports)
        #expect(plan.kept.first?.pendingSendAt == book.pendingSendAt)
        // Fichier relu (modifié) : l'attente est reprise.
        var fresh = try lib.index("Voltaire - Candide.epub")
        LibraryMerge.carryOver(from: book, to: &fresh)
        #expect(fresh.pendingSendAt == book.pendingSendAt)
    }

    @Test func drmEPUBCannotBeQueued() throws {
        var book = try SampleLibrary().index("Candide.epub")
        #expect(book.canSendToKindle)
        book.isDRMProtected = true
        #expect(!book.canSendToKindle)
        book.format = .azw3
        #expect(book.canSendToKindle)
    }
}

@Suite struct LibraryTrashTests {
    @Test func trashedStateSurvivesReread() throws {
        let lib = SampleLibrary()
        var book = try lib.index("Candide.epub")
        book.trashedAt = Date(timeIntervalSince1970: 7)
        var fresh = try lib.index("Candide.epub")
        LibraryMerge.carryOver(from: book, to: &fresh)
        #expect(fresh.trashedAt == book.trashedAt)
    }

    @Test func emptyMovesFilesAndReportsFailures() throws {
        let lib = SampleLibrary()
        let a = try lib.index("Candide.epub"), b = try lib.index("Zadig.epub")
        var gone = try lib.index("Micromégas.epub")
        try FileManager.default.removeItem(at: gone.url)
        gone.title = "déjà supprimé"
        // Fausse corbeille : déplace dans un dossier temporaire, refuse Zadig.
        let bin = tempDirectory()
        let result = LibraryTrash.empty([a, b, gone]) { url in
            if url.lastPathComponent == "Zadig.epub" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }
        #expect(Set(result.removed) == [a.id, gone.id])
        #expect(result.failures.map(\.path) == [b.path])
        #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent("Candide.epub").path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }
}

@Suite struct ShelfTests {
    @Test func shelvesSurviveRereadAndRename() throws {
        let lib = SampleLibrary()
        var book = try lib.index("Candide.epub")
        book.shelves = ["vol:LEA", "mtp:PAUL"]
        var fresh = try lib.index("Candide.epub")
        LibraryMerge.carryOver(from: book, to: &fresh)
        #expect(fresh.shelfIDs == ["vol:LEA", "mtp:PAUL"])
        let renamed = lib.dir.appendingPathComponent("Voltaire - Candide.epub")
        try FileManager.default.moveItem(at: book.url, to: renamed)
        let plan = LibraryMerge.plan(files: FolderScanner.scan([lib.dir]), known: [book], importsPath: lib.imports)
        #expect(plan.kept.first?.shelfIDs == ["vol:LEA", "mtp:PAUL"])
    }

    @Test func olderIndexWithoutShelvesStillLoads() throws {
        let lib = SampleLibrary()
        let book = try lib.index("Candide.epub")
        let url = lib.dir.appendingPathComponent("library.json")
        try LibraryIndex.save([book], to: url)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("shelves"))
        let loaded = try LibraryIndex.load(url)
        #expect(loaded.first?.shelfIDs.isEmpty == true)
    }
}

@Suite struct ReaderQueueTests {
    @Test func pendingDatePerReader() throws {
        var book = try SampleLibrary().index("Candide.epub")
        #expect(!book.isPendingSend)
        book.pendingFor = ["vol:LEA": Date(timeIntervalSince1970: 20)]
        #expect(book.isPendingSend)
        #expect(book.pendingDate(for: "vol:LEA") == Date(timeIntervalSince1970: 20))
        #expect(book.pendingDate(for: "mtp:PAUL") == nil)
        #expect(book.pendingDate(for: nil) == Date(timeIntervalSince1970: 20))
        // Attente sans liseuse choisie (ancienne file) : valable pour toutes, la plus ancienne date compte.
        book.pendingSendAt = Date(timeIntervalSince1970: 10)
        #expect(book.pendingDate(for: "mtp:PAUL") == Date(timeIntervalSince1970: 10))
        #expect(book.pendingDate(for: nil) == Date(timeIntervalSince1970: 10))
    }

    @Test func queueAndSentMarksSurviveReread() throws {
        let lib = SampleLibrary()
        var book = try lib.index("Candide.epub")
        book.pendingFor = ["vol:LEA": Date(timeIntervalSince1970: 1)]
        book.sentTo = ["mtp:PAUL": Date(timeIntervalSince1970: 2)]
        var fresh = try lib.index("Candide.epub")
        LibraryMerge.carryOver(from: book, to: &fresh)
        #expect(fresh.pendingFor == book.pendingFor)
        #expect(fresh.sentTo == book.sentTo)
    }
}

@Suite struct IndexBackupsTests {
    @Test func oneBackupPerDayKeepingTheMostRecent() throws {
        let dir = tempDirectory(), backups = dir.appendingPathComponent("Sauvegardes")
        let index = dir.appendingPathComponent("library.json")
        try Data("[]".utf8).write(to: index)
        let day: (Int) -> Date = { Date(timeIntervalSince1970: TimeInterval($0) * 86_400 + 3_600) }
        #expect(try IndexBackups.backUpToday(index, to: backups, now: day(1), keep: 3) != nil)
        // Même jour : pas de seconde copie (elle garderait l'état d'avant les changements du jour).
        #expect(try IndexBackups.backUpToday(index, to: backups, now: day(1), keep: 3) == nil)
        for d in 2...5 { try IndexBackups.backUpToday(index, to: backups, now: day(d), keep: 3) }
        let kept = IndexBackups.list(backups)
        #expect(kept.count == 3)
        #expect(kept.first?.date ?? .distantPast > kept.last?.date ?? .distantFuture)
        #expect(kept.map(\.url.lastPathComponent) == ["library-1970-01-06.json", "library-1970-01-05.json", "library-1970-01-04.json"])
    }

    @Test func noIndexNoBackup() throws {
        let dir = tempDirectory()
        #expect(try IndexBackups.backUpToday(dir.appendingPathComponent("library.json"), to: dir.appendingPathComponent("S")) == nil)
    }
}
