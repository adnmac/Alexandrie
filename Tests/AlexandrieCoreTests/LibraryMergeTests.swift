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
