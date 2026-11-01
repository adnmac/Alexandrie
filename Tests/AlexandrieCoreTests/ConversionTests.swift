import Foundation
import Testing
@testable import AlexandrieCore

/// EPUB de test généré à la volée : 3 chapitres, une image de couverture, un lien interne,
/// une feuille de style et une TOC hiérarchique.
func makeSampleEPUB(chapters: Int = 3, paragraphs: Int = 40) throws -> URL {
    var meta = BookMetadata(title: "Le Livre d'Essai", authors: ["Jeanne Dupont"], language: "fr",
                            publisher: "Éditions Test", summary: "Un résumé <b>riche</b>.")
    meta.subjects = ["Roman"]
    var epub = EPUBBuilder(metadata: meta)
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    epub.add("Images/cover.png", mediaType: "image/png", data: png)
    epub.coverPath = "Images/cover.png"
    epub.add("Styles/main.css", mediaType: "text/css",
             data: Data("body { font-family: serif; } .c { background: url(../Images/cover.png); }".utf8))
    var toc: [TOCNode] = []
    for c in 1...chapters {
        var body = "<h1 id=\"ch\(c)\">Chapitre \(c) — été</h1>\n"
        for p in 1...paragraphs {
            body += "<p id=\"p\(c)-\(p)\">Paragraphe \(p) du chapitre \(c) : « Ça déménage » à l’œil nu…</p>\n"
        }
        if c == 1 { body += "<p><a href=\"chapter3.xhtml#p3-5\">Aller au chapitre 3</a><img src=\"../Images/cover.png\" alt=\"\"/></p>\n" }
        let html = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="fr">
            <head><title>Chapitre \(c)</title><link rel="stylesheet" type="text/css" href="../Styles/main.css"/></head>
            <body>
            \(body)</body>
            </html>
            """
        epub.add("Text/chapter\(c).xhtml", mediaType: "application/xhtml+xml", data: Data(html.utf8), inSpine: true)
        toc.append(TOCNode(title: "Chapitre \(c)", path: "Text/chapter\(c).xhtml",
                           children: [TOCNode(title: "Section \(c).5", path: "Text/chapter\(c).xhtml", fragment: "p\(c)-5")]))
    }
    epub.toc = toc
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString).epub")
    try epub.write(to: url)
    return url
}

func temp(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).\(ext)")
}

@Suite struct PalmDocTests {
    @Test func roundTrip() {
        let text = Array(String(repeating: "Le chat dort. Le chien aboie. ÀÉÎ — ok\u{1}\u{2}\n", count: 120).utf8)
        for start in stride(from: 0, to: text.count, by: 4096) {
            let block = Array(text[start..<min(start + 4096, text.count)])
            let packed = PalmDoc.compress(block)
            #expect(PalmDoc.decompress(packed) == block)
            #expect(packed.count < block.count)
        }
    }

    @Test func varIntRoundTrip() {
        for v in [0, 1, 127, 128, 300, 70_000, 1 << 28] {
            let enc = VarInt.encodeForward(v)
            #expect(VarInt.readForward(enc, 0).value == v)
        }
        #expect(Base32.decode(Base32.encode(123_456, width: 10)) == 123_456)
    }
}

@Suite struct EPUBTests {
    @Test func readsMetadataAndTOC() throws {
        let url = try makeSampleEPUB()
        let reader = try EPUBReader(url: url)
        let meta = try reader.bookMetadata()
        #expect(meta.title == "Le Livre d'Essai")
        #expect(meta.authors == ["Jeanne Dupont"])
        #expect(meta.language == "fr")
        #expect(meta.coverData != nil)
        #expect(reader.spine.count == 3)
        let toc = reader.tableOfContents()
        #expect(toc.count == 3)
        #expect(toc[0].children.first?.fragment == "p1-5")
    }
}

@Suite struct AZW3Tests {
    @Test func epubToAZW3RoundTrip() throws {
        let epub = try makeSampleEPUB(chapters: 3, paragraphs: 120)
        let azw3 = temp("azw3")
        let result = try EPUBToAZW3.convert(input: epub, output: azw3)

        let book = try MobiBook(url: azw3)
        #expect(book.hasKF8)
        #expect(!book.isDRMProtected)
        let meta = book.metadata()
        #expect(meta.title == "Le Livre d'Essai")
        #expect(meta.authors == ["Jeanne Dupont"])
        #expect(meta.language == "fr")
        #expect(meta.coverData != nil)
        #expect(book.asin == result.asin)
        #expect(book.cdeType == "EBOK")

        // Retour en EPUB : mêmes chapitres, texte intact, lien et TOC résolus.
        let back = try MobiToEPUB.build(book)
        #expect(back.spinePaths.count == 3)
        let ch1 = String(decoding: back.resources.first { $0.path == back.spinePaths[0] }!.data, as: UTF8.self)
        #expect(ch1.contains("Chapitre 1 — été"))
        #expect(ch1.contains("« Ça déménage » à l’œil nu…"))
        #expect(ch1.contains("Paragraphe 120 du chapitre 1"))
        #expect(ch1.contains("href=\"part0002.xhtml#p3-5\""))
        #expect(ch1.contains("../Images/image00001.png"))
        #expect(ch1.contains("../Styles/style0001.css"))
        let ch3 = String(decoding: back.resources.first { $0.path == back.spinePaths[2] }!.data, as: UTF8.self)
        #expect(ch3.contains("Paragraphe 120 du chapitre 3"))
        #expect(back.toc.count == 3)
        #expect(back.toc[2].children.first?.fragment == "p3-5")
        #expect(back.resources.contains { $0.mediaType == "text/css" && String(decoding: $0.data, as: UTF8.self).contains("../Images/image00001.png") })

        let out = temp("epub")
        try back.write(to: out)
        let reread = try EPUBReader(url: out)
        #expect(try reread.bookMetadata().title == "Le Livre d'Essai")
    }

    @Test func extractorDispatch() throws {
        let epub = try makeSampleEPUB(chapters: 1, paragraphs: 3)
        let azw3 = temp("azw3")
        try EPUBToAZW3.convert(input: epub, output: azw3,
                               edits: MetadataEdits(title: "Titre modifié", authors: ["A", "B"],
                                                    summary: "Un résumé riche.", publishedDate: "1759"))
        let meta = try MetadataExtractor.extract(from: azw3)
        #expect(meta.title == "Titre modifié")
        #expect(meta.authors == ["A", "B"])
        #expect(meta.summary == "Un résumé riche.")
        #expect(meta.publishedDate == "1759")
    }
}
