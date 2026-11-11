import Foundation
import Testing
@testable import FolunaCore

@Suite struct EPUBMetadataWriterTests {
    let fixed = MetadataEdits(title: "Candide — corrigé", authors: ["Voltaire", "Jean Dupont"], publisher: "Cramer",
                              language: "fr", summary: "Résumé corrigé.", publishedDate: "1759", isbn: "2-07-036002-4",
                              series: "Contes philosophiques", seriesIndex: 2)

    @Test func rewritesTheOPFOnly() throws {
        let source = try makeSampleEPUB(chapters: 2, paragraphs: 5)
        let before = try Data(contentsOf: source)
        let out = temp("epub")
        try EPUBMetadataWriter.rewrite(source, with: fixed, to: out)
        let meta = try EPUBReader(url: out).bookMetadata()
        #expect(meta.title == fixed.title)
        #expect(meta.authors == ["Voltaire", "Jean Dupont"])
        #expect(meta.publisher == "Cramer" && meta.language == "fr" && meta.publishedDate == "1759")
        #expect(meta.summary == "Résumé corrigé.")
        #expect(meta.isbn == "9782070360024")
        #expect(meta.series == "Contes philosophiques" && meta.seriesIndex == 2)
        // Chapitres intacts, `mimetype` en tête, source inchangée.
        let a = try EPUBReader(url: source), b = try EPUBReader(url: out)
        #expect(try a.tableOfContents() == b.tableOfContents())
        let first = try ZipReader(url: out).paths.first
        #expect(first == "mimetype")
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func emptyFieldsKeepTheBookValues() throws {
        let source = try makeSampleEPUB(chapters: 1, paragraphs: 2)
        let out = temp("epub")
        try EPUBMetadataWriter.rewrite(source, with: MetadataEdits(title: "Nouveau titre", authors: []), to: out)
        let meta = try EPUBReader(url: out).bookMetadata()
        #expect(meta.title == "Nouveau titre")
        #expect(meta.authors == ["Jeanne Dupont"] && meta.publisher == "Éditions Test")
        // Réécrire deux fois ne double rien.
        let again = temp("epub")
        try EPUBMetadataWriter.rewrite(out, with: fixed, to: again)
        try EPUBMetadataWriter.rewrite(again, with: fixed, to: out)
        let twice = try EPUBReader(url: out).bookMetadata()
        #expect(twice.authors == ["Voltaire", "Jean Dupont"] && twice.series == "Contes philosophiques")
    }
}

@Suite struct ReaderBrandTests {
    let fm = FileManager.default

    func volume(_ layout: [String]) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("vol-\(UUID().uuidString)", isDirectory: true)
        for path in layout {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
        return root
    }

    @Test func recognizesBrands() throws {
        #expect(VolumeKindle.brand(of: try volume(["documents/", "system/"])) == .kindle)
        #expect(VolumeKindle.brand(of: try volume([".kobo/KoboReader.sqlite", "Books/"])) == .kobo)
        #expect(VolumeKindle.brand(of: try volume([".kobo/version"])) == .kobo)
        #expect(VolumeKindle.brand(of: try volume(["Books/livre.epub"])) == nil, "un disque quelconque n'est jamais une liseuse")
        #expect(VolumeKindle.brand(of: try volume([".kobo/"])) == nil, "un dossier .kobo vide ne suffit pas")
    }

    @Test func listsAndSendsByBrand() throws {
        let kobo = VolumeKindle(root: try volume([".kobo/KoboReader.sqlite", ".kobo/cache.epub", "livre.epub",
                                                  "Dossier/autre.pdf", "notes.docx", ".cache/caché.epub"]), brand: .kobo)
        #expect(try kobo.listDocuments().map(\.path) == ["Dossier/autre.pdf", "livre.epub"], "tout le disque, sauf les dossiers cachés")
        let file = fm.temporaryDirectory.appendingPathComponent("envoi-\(UUID().uuidString).epub")
        try Data("epub".utf8).write(to: file)
        try kobo.send(file: file, filename: "Candide - Voltaire.epub", thumbnail: ("B0TEST", Data([1])))
        #expect(fm.fileExists(atPath: kobo.root.appendingPathComponent("Books/Candide - Voltaire.epub").path), "Books/ créé")
        #expect(!fm.fileExists(atPath: kobo.root.appendingPathComponent("system").path), "pas de miniature Kindle")

        let generic = VolumeKindle(root: try volume(["Livres/a.epub", "Livres/b.fb2", "c.epub"]), brand: .generic, booksFolder: "Livres")
        #expect(try generic.listDocuments().map(\.path) == ["a.epub", "b.fb2"])
        #expect(generic.suggestedBooksFolder == "Livres")
        let kindle = VolumeKindle(root: try volume(["documents/a.azw3", "documents/b.epub", "documents/My Clippings.txt", "system/"]))
        #expect(try kindle.listDocuments().map(\.path) == ["a.azw3"])
    }

    @Test func choosesWhatToSend() throws {
        let dirs = AppDirectories(base: fm.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)"))
        let epubURL = try makeSampleEPUB(chapters: 1, paragraphs: 3)
        let file = ScannedFile(url: epubURL, size: Int64(try Data(contentsOf: epubURL).count), modifiedAt: Date())
        var book = FolderScanner.makeBook(file, imported: false, coverStore: CoverStore(directory: dirs.covers))
        book.title = "Titre corrigé"
        #expect(book.sentExtension(for: .kindle) == "azw3" && book.sentExtension(for: .kobo) == "epub")
        #expect(book.filename(for: .kobo).hasSuffix(".epub") && book.filename(for: .kindle) == book.kindleFilename)
        let forKobo = try KindleTransfer.prepare(book, directories: dirs, brand: .kobo)
        #expect(forKobo.pathExtension == "epub" && forKobo != epubURL)
        #expect(try EPUBReader(url: forKobo).bookMetadata().title == "Titre corrigé")
        #expect(KindleTransfer.cachedCopy(of: book, directories: dirs, brand: .kobo)
                == KindleTransfer.cachedCopy(of: book, directories: dirs, brand: .generic), "même copie EPUB")
        #expect(KindleTransfer.cachedCopy(of: book, directories: dirs, brand: .kindle).pathExtension == "azw3")

        // Un AZW3 part en EPUB sur une Kobo.
        let azw3 = temp("azw3")
        try EPUBToAZW3.convert(input: epubURL, output: azw3)
        let kindleFile = ScannedFile(url: azw3, size: Int64(try Data(contentsOf: azw3).count), modifiedAt: Date())
        let kindleBook = FolderScanner.makeBook(kindleFile, imported: false, coverStore: CoverStore(directory: dirs.covers))
        let converted = try KindleTransfer.prepare(kindleBook, directories: dirs, brand: .kobo)
        #expect(converted.pathExtension == "epub" && (try? EPUBReader(url: converted)) != nil)

        // DRM : un livre Kindle protégé ne part que sur une Kindle ; un EPUB protégé, tel quel sur une Kobo.
        var locked = kindleBook
        locked.isDRMProtected = true
        #expect(locked.canSend(to: .kindle) && !locked.canSend(to: .kobo))
        var lockedEPUB = book
        lockedEPUB.isDRMProtected = true
        #expect(!lockedEPUB.canSend(to: .kindle) && lockedEPUB.canSend(to: .kobo))
        #expect(try KindleTransfer.prepare(lockedEPUB, directories: dirs, brand: .kobo) == epubURL)
    }

    @Test func readsOldReaderLists() throws {
        let old = Data(#"[{"id":"vol:1","name":"Kindle de Léa","firstSeenAt":0,"lastSeenAt":0}]"#.utf8)
        let readers = try JSONDecoder().decode([Reader].self, from: old)
        #expect(readers.first?.brand == .kindle && readers.first?.booksFolder == nil)
    }
}
