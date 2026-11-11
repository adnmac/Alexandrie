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
