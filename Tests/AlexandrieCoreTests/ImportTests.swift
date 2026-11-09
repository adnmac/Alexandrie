import Foundation
import PDFKit
import Testing
@testable import AlexandrieCore

/// Image PNG de 1 × 1 pixel.
let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

/// Fichier de test dans un dossier temporaire neuf.
func writeTemp(_ name: String, _ data: Data) throws -> URL {
    let url = tempDirectory().appendingPathComponent(name)
    try data.write(to: url)
    return url
}

/// Archive ZIP de test (CBZ, FB2 compressé).
func writeZip(_ name: String, _ entries: [(String, Data)]) throws -> URL {
    let url = tempDirectory().appendingPathComponent(name)
    let zip = try ZipWriter(url: url)
    for (path, data) in entries { try zip.add(path, data: data) }
    return url
}

/// Livre indexé à partir d'un fichier.
func indexed(_ url: URL) throws -> Book {
    let file = try #require(FolderScanner.scan([url.deletingLastPathComponent()], allFormatsIn: url.deletingLastPathComponent())
        .first { $0.url.lastPathComponent == url.lastPathComponent })
    return FolderScanner.makeBook(file, imported: true, coverStore: CoverStore(directory: tempDirectory()))
}

let gutenbergText = """
    The Project Gutenberg eBook of Candide

    Title: Candide
    Author: Voltaire
    Language: French

    *** START OF THE PROJECT GUTENBERG EBOOK CANDIDE ***

    CHAPITRE PREMIER

    Comment Candide fut élevé dans un beau château, et comment il fut
    chassé d'icelui.

    Il y avait en Westphalie, dans le château de M. le baron de
    Thunder-ten-tronckh, un jeune garçon à qui la nature avait donné
    les mœurs les plus douces.

    Sa physionomie annonçait son âme. Il avait le jugement assez droit,
    avec l'esprit le plus simple.

    CHAPITRE II

    Ce que devint Candide parmi les Bulgares.

    Candide, chassé du paradis terrestre, marcha longtemps sans savoir où,
    pleurant, levant les yeux au ciel.

    *** END OF THE PROJECT GUTENBERG EBOOK CANDIDE ***

    Licence du Project Gutenberg, à ne pas garder.
    """

@Suite struct TXTImportTests {
    @Test func gutenbergInWindows1252() throws {
        let url = try writeTemp("candide.txt", try #require(gutenbergText.data(using: .windowsCP1252)))
        let doc = try TXTImporter.document(of: url)
        #expect(doc.metadata.title == "Candide")
        #expect(doc.metadata.authors == ["Voltaire"])
        #expect(doc.metadata.language == "fr")
        #expect(doc.chapters.map(\.title) == ["CHAPITRE PREMIER", "CHAPITRE II"])
        let text = doc.plainTexts.joined(separator: " ")
        #expect(text.contains("les mœurs les plus douces"))
        #expect(text.contains("de M. le baron de Thunder-ten-tronckh, un jeune"))   // lignes recollées
        #expect(!text.contains("Licence du Project Gutenberg"))
        #expect(!text.contains("START OF"))
    }

    @Test func utf16AndFilename() throws {
        var data = Data([0xFF, 0xFE])
        data.append(try #require("Une ligne.\nUne autre ligne, déjà.".data(using: .utf16LittleEndian)))
        let url = try writeTemp("Le Titre - Jeanne Dupont.txt", data)
        let doc = try TXTImporter.document(of: url)
        #expect(doc.metadata.title == "Le Titre")
        #expect(doc.metadata.authors == ["Jeanne Dupont"])
        #expect(doc.plainTexts.joined().contains("déjà"))
        #expect(doc.chapters.count == 1)
    }

    @Test func headings() {
        #expect(TXTImporter.isHeading("Chapitre 12"))
        #expect(TXTImporter.isHeading("CHAPTER IV. THE RETURN"))
        #expect(TXTImporter.isHeading("XII"))
        #expect(TXTImporter.isHeading("3."))
        #expect(!TXTImporter.isHeading("Il y avait en Westphalie un château."))
        #expect(!TXTImporter.isHeading("Partiellement couvert"))
        #expect(!TXTImporter.isHeading("part of the town where the river was"))
        #expect(!TXTImporter.isHeading("mix"))
        #expect(TXTImporter.isHeading("Livre premier"))
        #expect(TXTImporter.isHeading("PROLOGUE"))
    }

    @Test func binaryIsRefused() throws {
        let url = try writeTemp("binaire.txt", Data([0x00, 0x01, 0x02, 0x00]))
        #expect(throws: (any Error).self) { try TXTImporter.document(of: url) }
    }

    @Test func epubThenAZW3() throws {
        let url = try writeTemp("candide.txt", Data(gutenbergText.utf8))
        let epub = temp("epub")
        try Importers.writeEPUB(url, format: .txt, to: epub, edits: MetadataEdits(title: "Candide corrigé", authors: ["Voltaire"]))
        let reader = try EPUBReader(url: epub)
        #expect(reader.spine.count == 2)
        #expect(try reader.bookMetadata().title == "Candide corrigé")
        let azw3 = temp("azw3")
        try EPUBToAZW3.convert(input: epub, output: azw3)
        #expect(try MobiBook(url: azw3).metadata().title == "Candide corrigé")
    }
}

func fb2(cover: Bool = true, extra: String = "") -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
    <description>
      <title-info>
        <genre>prose</genre>
        <author><first-name>Jeanne</first-name><last-name>Dupont</last-name></author>
        <book-title>Le Fleuve</book-title>
        <annotation><p>Un résumé.</p></annotation>
        <date value="1903-05-01">1903</date>
        \(cover ? #"<coverpage><image l:href="#cover.png"/></coverpage>"# : "")
        <lang>fr</lang>
        <sequence name="Les Rivières" number="2"/>
      </title-info>
      <publish-info><publisher>Éditions Test</publisher><isbn>978-2-07-036024-6</isbn></publish-info>
    </description>
    <body>
      <title><p>Le Fleuve</p></title>
      <section id="s1">
        <title><p>Premier chapitre</p></title>
        <p>Il <emphasis>était</emphasis> une fois<a l:href="#n1" type="note">1</a> &amp; ailleurs.</p>
        <p><a l:href="javascript:alert(1)">piège</a></p>
        <section><title><p>Sous-partie</p></title><p>Texte de la sous-partie.</p></section>
      </section>
      <section>
        <title><p>Second chapitre</p></title>
        <poem><stanza><v>Un vers</v></stanza></poem>
        <image l:href="#cover.png"/>
      </section>
    </body>
    <body name="notes">
      <section id="n1"><title><p>1</p></title><p>La note.</p></section>
    </body>
    \(extra)
    <binary id="cover.png" content-type="image/png">\(tinyPNG.base64EncodedString())</binary>
    </FictionBook>
    """
}

@Suite struct FB2ImportTests {
    @Test func metadataAndChapters() throws {
        let url = try writeTemp("fleuve.fb2", Data(fb2().utf8))
        let meta = try MetadataExtractor.extract(from: url)
        #expect(meta.title == "Le Fleuve")
        #expect(meta.authors == ["Jeanne Dupont"])
        #expect(meta.language == "fr")
        #expect(meta.series == "Les Rivières")
        #expect(meta.seriesIndex == 2)
        #expect(meta.publisher == "Éditions Test")
        #expect(meta.isbn == "9782070360246")
        #expect(meta.publishedDate == "1903-05-01")
        #expect(meta.coverData != nil)

        let doc = try FB2Importer.document(of: url)
        #expect(doc.chapters.map(\.title) == [nil, "Premier chapitre", "Second chapitre", "Notes"])
        let first = doc.chapters[1].body
        #expect(first.contains("<em>était</em>"))
        #expect(first.contains("&amp; ailleurs"))
        #expect(first.contains("href=\"chapter0004.xhtml#n1\""))     // appel de note vers le chapitre des notes
        #expect(!first.contains("javascript"))
        #expect(first.contains("Sous-partie"))
        #expect(doc.chapters[2].body.contains("../Images/image1.png"))
        #expect(doc.chapters[3].body.contains("id=\"n1\""))
        #expect(doc.cover == "image1.png")
    }

    @Test func zippedFB2() throws {
        let url = try writeZip("Le Fleuve.fb2.zip", [("fleuve.fb2", Data(fb2().utf8))])
        #expect(BookFormat(url: url) == .fb2)
        #expect(try MetadataExtractor.extract(from: url).title == "Le Fleuve")
        let epub = temp("epub")
        try Importers.writeEPUB(url, format: .fb2, to: epub, edits: nil)
        let reader = try EPUBReader(url: epub)
        #expect(reader.spine.count == 4)
        #expect(reader.coverItem != nil)
    }

    @Test func declaredEntitiesAreRefused() throws {
        let bomb = """
            <?xml version="1.0"?>
            <!DOCTYPE FictionBook [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>
            <FictionBook><body><section><p>&b;</p></section></body></FictionBook>
            """
        let url = try writeTemp("bombe.fb2", Data(bomb.utf8))
        #expect(throws: (any Error).self) { try FB2Importer.document(of: url) }
    }

    @Test func notFictionBook() throws {
        let url = try writeTemp("autre.fb2", Data("<?xml version=\"1.0\"?><html/>".utf8))
        #expect(throws: (any Error).self) { try FB2Importer.document(of: url) }
    }
}

func comicInfo() -> Data {
    Data("""
        <?xml version="1.0"?>
        <ComicInfo><Series>Les Pirates</Series><Number>3</Number><Writer>A. Auteur, B. Dessin</Writer>
        <Summary>Une aventure.</Summary><LanguageISO>fr</LanguageISO></ComicInfo>
        """.utf8)
}

@Suite struct CBZImportTests {
    func album() throws -> URL {
        try writeZip("pirates.cbz", [("p10.png", tinyPNG), ("p2.png", tinyPNG), ("p1.png", tinyPNG),
                                     ("__MACOSX/._p1.png", Data([1, 2, 3])), (".cache/x.png", tinyPNG),
                                     ("lisez-moi.txt", Data("x".utf8)), ("ComicInfo.xml", comicInfo())])
    }

    @Test func pagesInNaturalOrder() throws {
        let zip = try ZipReader(url: try album())
        #expect(try CBZImporter.pagePaths(zip) == ["p1.png", "p2.png", "p10.png"])
    }

    @Test func metadata() throws {
        let meta = try MetadataExtractor.extract(from: try album())
        #expect(meta.title == "Les Pirates 3")
        #expect(meta.authors == ["A. Auteur", "B. Dessin"])
        #expect(meta.series == "Les Pirates")
        #expect(meta.seriesIndex == 3)
        #expect(meta.coverData != nil)
    }

    @Test func pdfAndEPUB() throws {
        let url = try album()
        let pdf = temp("pdf")
        try Importers.writePDF(url, format: .cbz, to: pdf, edits: MetadataEdits(title: "Corrigé", authors: []))
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount == 3)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Corrigé")
        let epub = temp("epub")
        try Importers.writeEPUB(url, format: .cbz, to: epub, edits: nil)
        #expect(try EPUBReader(url: epub).spine.count == 3)
    }

    @Test func noImage() throws {
        let url = try writeZip("vide.cbz", [("a.txt", Data("x".utf8))])
        #expect(throws: (any Error).self) { try CBZImporter.document(of: url) }
    }
}

@Suite struct ImportLimitsTests {
    @Test func entryOverLimitIsRefused() throws {
        let url = try writeZip("gros.cbz", [("page.png", Data(repeating: 7, count: 10_000))])
        let zip = try ZipReader(url: url)
        #expect(throws: (any Error).self) { try zip.data("page.png", limit: 1_000) }
        #expect(try zip.data("page.png", limit: 10_000).count == 10_000)
    }

    @Test func hugeImageIsRefused() {
        // En-tête PNG annonçant 50 000 × 50 000 pixels (sans données d'image).
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: [UInt8]) {
            let bytes = Array(type.utf8) + body
            png.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
            png.append(contentsOf: bytes)
            png.append(contentsOf: withUnsafeBytes(of: crc32(bytes).bigEndian, Array.init))
        }
        let side = withUnsafeBytes(of: UInt32(50_000).bigEndian, Array.init)
        chunk("IHDR", side + side + [8, 2, 0, 0, 0])
        chunk("IEND", [])
        #expect(!ImportLimits.acceptsImage(png))
        #expect(ImportLimits.acceptsImage(tinyPNG))
    }

    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }
}

@Suite struct ImportedBookTests {
    @Test func scanSkipsTextOutsideImports() throws {
        let dir = tempDirectory()
        try Data(gutenbergText.utf8).write(to: dir.appendingPathComponent("README.txt"))
        try Data(fb2().utf8).write(to: dir.appendingPathComponent("fleuve.fb2"))
        #expect(FolderScanner.scan([dir]).map(\.url.lastPathComponent) == ["fleuve.fb2"])
        #expect(Set(FolderScanner.scan([dir], allFormatsIn: dir).map(\.url.lastPathComponent)) == ["README.txt", "fleuve.fb2"])
    }

    @Test func sentFormats() throws {
        let fb2Book = try indexed(try writeTemp("fleuve.fb2", Data(fb2().utf8)))
        #expect(fb2Book.title == "Le Fleuve")
        #expect(fb2Book.becomesAZW3)
        #expect(fb2Book.kindleFilename.hasSuffix(".azw3"))
        #expect(fb2Book.sentExtension(for: .kobo) == "epub")
        #expect(fb2Book.needsConversion(for: .kobo))

        let comic = try indexed(try writeZip("pirates.cbz", [("p1.png", tinyPNG)]))
        #expect(comic.becomesPDF && !comic.becomesAZW3)
        #expect(comic.sentExtension(for: .kindle) == "pdf")
        #expect(comic.sentExtension(for: .kobo) == "cbz")
        #expect(!comic.needsConversion(for: .kobo))

        let prc = try indexed(try writeTemp("vieux.prc", Data(repeating: 0, count: 100)))
        #expect(prc.format == .prc && prc.format.isKindleNative && !prc.becomesAZW3)
    }

    @Test func transferToReaders() throws {
        let directories = AppDirectories(base: tempDirectory())
        let book = try indexed(try writeTemp("fleuve.fb2", Data(fb2().utf8)))
        let epub = try KindleTransfer.prepare(book, directories: directories, brand: .kobo)
        #expect(epub.pathExtension == "epub")
        #expect(try EPUBReader(url: epub).bookMetadata().title == "Le Fleuve")
        let azw3 = try KindleTransfer.prepare(book, directories: directories, brand: .kindle)
        #expect(try MobiBook(url: azw3).metadata().title == "Le Fleuve")

        let comic = try indexed(try writeZip("pirates.cbz", [("p1.png", tinyPNG), ("p2.png", tinyPNG)]))
        #expect(try KindleTransfer.prepare(comic, directories: directories, brand: .kobo) == comic.url)
        let pdf = try KindleTransfer.prepare(comic, directories: directories, brand: .kindle)
        #expect(PDFDocument(url: pdf)?.pageCount == 2)
    }

    @Test func readingAndText() throws {
        let directories = AppDirectories(base: tempDirectory())
        let book = try indexed(try writeTemp("candide.txt", Data(gutenbergText.utf8)))
        #expect(ReaderBook.canRead(book))
        let reader = try ReaderBook.prepare(book, directories: directories)
        #expect(reader.chapters.count == 2)
        #expect(reader.toc.map(\.title) == ["CHAPITRE PREMIER", "CHAPITRE II"])
        #expect(BookText.canExtract(book))
        #expect(try BookText.extract(book).sections.joined().contains("Bulgares"))
    }

    @Test func disabledFormats() throws {
        let defaults = try #require(UserDefaults(suiteName: "foluna-tests-\(UUID().uuidString)"))
        #expect(Importers.disabledFormats(defaults).isEmpty)
        Importers.setEnabled(.txt, false, defaults: defaults)
        Importers.setEnabled(.epub, false, defaults: defaults)   // format de base : ignoré
        #expect(Importers.disabledFormats(defaults) == [.txt])
        Importers.setEnabled(.txt, true, defaults: defaults)
        #expect(Importers.disabledFormats(defaults).isEmpty)
    }
}
