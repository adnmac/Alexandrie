import Foundation
import Testing
@testable import AlexandrieCore

@Suite struct LibraryFoldersTests {
    @Test func ownerIsTheMostPreciseFolder() {
        let folders = ["/Volumes/Disque/Livres", "/Users/moi/Livres"]
        #expect(LibraryFolders.owner(of: "/Users/moi/Livres/Roman/a.epub", among: folders) == "/Users/moi/Livres")
        #expect(LibraryFolders.owner(of: "/Volumes/Disque/Livres/b.pdf", among: folders) == "/Volumes/Disque/Livres")
        // « Livres anciens » n'est pas dans « Livres ».
        #expect(LibraryFolders.owner(of: "/Users/moi/Livres anciens/c.epub", among: folders) == nil)
    }

    @Test func refusesFoldersAlreadyRead() {
        let folders = ["/Users/moi/Livres"]
        #expect(LibraryFolders.conflict(adding: "/Users/moi/Livres/", to: folders) == .same)
        #expect(LibraryFolders.conflict(adding: "/Users/moi/Livres/Romans", to: folders) == .inside("/Users/moi/Livres"))
        #expect(LibraryFolders.conflict(adding: "/Users/moi", to: folders) == .contains("/Users/moi/Livres"))
        #expect(LibraryFolders.conflict(adding: "/Users/moi/Livres anciens", to: folders) == nil)
        #expect(LibraryFolders.conflict(adding: "/Volumes/Disque", to: folders) == nil)
    }

    @Test func legacyBookmarkBecomesTheFirstFolder() throws {
        let base = tempDirectory()
        let folder = base.appendingPathComponent("Livres", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = try #require(LibraryFolders.bookmark(folder))
        let file = base.appendingPathComponent("folders.json")

        let migrated = LibraryFolders.load(file, legacy: legacy)
        #expect(migrated.map(\.path) == [folder.standardizedFileURL.path])
        #expect(migrated.first?.bookmark == legacy)
        #expect(LibraryFolders.load(file, legacy: nil).isEmpty)

        // Une fois la liste enregistrée, l'ancien signet n'est plus lu.
        let second = LibraryFolders.Entry(path: "/Volumes/Disque/Livres", bookmark: nil)
        try LibraryFolders.save(migrated + [second], to: file)
        #expect(LibraryFolders.load(file, legacy: nil).map(\.path) == [folder.standardizedFileURL.path, "/Volumes/Disque/Livres"])
    }

    @Test func unreachableFolderKeepsItsPath() {
        let entry = LibraryFolders.Entry(path: "/Volumes/Absent/Livres", bookmark: Data([1, 2, 3]))
        let (resolved, changed) = entry.resolved()
        #expect(resolved == entry)
        #expect(!changed)
    }
}
