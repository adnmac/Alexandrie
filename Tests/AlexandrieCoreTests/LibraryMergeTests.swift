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
