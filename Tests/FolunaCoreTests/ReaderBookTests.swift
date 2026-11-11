import Foundation
import Testing
@testable import FolunaCore

@Suite struct ReaderBookTests {
    /// Livre indexé à partir de l'EPUB de test (3 chapitres, table hiérarchique, image, feuille de style).
    func sampleBook() throws -> Book {
        let url = try makeSampleEPUB()
        let file = try #require(FolderScanner.scan([url.deletingLastPathComponent()]).first { $0.url.lastPathComponent == url.lastPathComponent })
        return FolderScanner.makeBook(file, imported: false, coverStore: CoverStore(directory: tempDirectory()))
    }

    @Test func epubIsExtractedOnceWithItsTableOfContents() throws {
        let book = try sampleBook()
        let directories = AppDirectories(base: tempDirectory())
        let original = try Data(contentsOf: book.url)

        let reader = try ReaderBook.prepare(book, directories: directories)
        #expect(!reader.chapters.isEmpty)
        #expect(reader.chapters.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(reader.chapters.allSatisfy { $0.path.hasPrefix(directories.reading.path) })
        #expect(reader.weights.count == reader.chapters.count)
        #expect(reader.chapters.count == 3)
        #expect(reader.toc.map(\.title) == ["Chapitre 1", "Section 1.5", "Chapitre 2", "Section 2.5", "Chapitre 3", "Section 3.5"])
        #expect(reader.toc[1].chapter == 0 && reader.toc[1].fragment == "p1-5" && reader.toc[1].depth == 1)
        // Les images et feuilles de style sont à côté des chapitres, aux mêmes chemins relatifs.
        #expect(FileManager.default.fileExists(atPath: reader.chapters[0].deletingLastPathComponent()
            .appendingPathComponent("../Styles/main.css").standardizedFileURL.path))
        #expect(try Data(contentsOf: book.url) == original)

        // Deuxième ouverture : rien n'est réécrit.
        let stamp = try reader.chapters[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = try ReaderBook.prepare(book, directories: directories)
        #expect(again.chapters == reader.chapters)
        #expect(try again.chapters[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
    }

    @Test func drmAndPDFAreNotPreparedAsEPUB() throws {
        var book = try sampleBook()
        book.isDRMProtected = true
        #expect(!ReaderBook.canRead(book))
        #expect(throws: BookError.drmProtected) { try ReaderBook.prepare(book, directories: AppDirectories(base: tempDirectory())) }
    }

    @Test func percentFollowsChapterSizes() {
        let weights = [100, 300, 600]
        #expect(ReadingPosition.percent(chapter: 0, fraction: 0, weights: weights) == 0)
        #expect(ReadingPosition.percent(chapter: 1, fraction: 0.5, weights: weights) == 0.25)
        #expect(ReadingPosition.percent(chapter: 2, fraction: 1, weights: weights) == 1)
        #expect(ReadingPosition.percent(page: 0, of: 200) == 0)
        #expect(ReadingPosition.percent(page: 199, of: 200) == 1)
        #expect(ReadingPosition(chapter: 1, fraction: 0.4, percent: 0.4237).label == "42 % lu")
        #expect(ReadingPosition(chapter: 2, fraction: 1, percent: 1).label == "Terminé")
    }

    @Test func positionsSurviveARelaunch() throws {
        let url = tempDirectory().appendingPathComponent("reading.json")
        let position = ReadingPosition(chapter: 3, fraction: 0.5, percent: 0.42, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try ReadingLog.save(["abc-123": position], to: url)
        #expect(ReadingLog.load(url) == ["abc-123": position])
    }
}

/// Entrée en cours de la table des matières quand un fichier porte plusieurs parties (S-067).
@Suite struct CurrentEntryTests {
    let toc = [
        ReaderBook.Entry(title: "Couverture", chapter: 0, fragment: nil, depth: 0),
        ReaderBook.Entry(title: "Partie 1", chapter: 1, fragment: "p1", depth: 0),
        ReaderBook.Entry(title: "Partie 2", chapter: 1, fragment: "p2", depth: 0),
        ReaderBook.Entry(title: "Partie 3", chapter: 1, fragment: "p3", depth: 0),
        ReaderBook.Entry(title: "Conclusion", chapter: 2, fragment: nil, depth: 0),
    ]
    let pages = ["p1": 0, "p2": 12, "p3": 30]

    func current(chapter: Int, page: Int, pages: [String: Int]) -> String? {
        let id = ReaderBook.currentEntry(in: toc, chapter: chapter, page: page, fragmentPages: pages)
        return toc.first { $0.id == id }?.title
    }

    @Test func followsThePageInsideOneFile() {
        #expect(current(chapter: 1, page: 0, pages: pages) == "Partie 1")
        #expect(current(chapter: 1, page: 11, pages: pages) == "Partie 1")
        #expect(current(chapter: 1, page: 12, pages: pages) == "Partie 2")
        #expect(current(chapter: 1, page: 29, pages: pages) == "Partie 2")
        #expect(current(chapter: 1, page: 44, pages: pages) == "Partie 3")
    }

    @Test func otherChaptersAndUnplacedAnchors() {
        #expect(current(chapter: 0, page: 3, pages: [:]) == "Couverture")
        #expect(current(chapter: 2, page: 0, pages: [:]) == "Conclusion")
        // Pages pas encore relevées : comme avant, la dernière entrée du fichier.
        #expect(current(chapter: 1, page: 0, pages: [:]) == "Partie 3")
    }
}
