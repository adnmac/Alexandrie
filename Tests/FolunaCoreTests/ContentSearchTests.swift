import Foundation
import Testing
@testable import FolunaCore

@Suite struct ContentSearchTests {
    @Test func xhtmlBecomesPlainText() {
        let html = """
            <?xml version="1.0"?><html><head><title>Titre</title><style>p { color: red; }</style></head>
            <body><h1>L&apos;Odyss&#233;e</h1><script>var x = "<p>";</script><p>Ulysse &amp; P&#xE9;n&eacute;lope&nbsp;!</p></body></html>
            """
        let text = BookText.plainText(Data(html.utf8))
        #expect(text.contains("L'Odyssée") && text.contains("Ulysse & Pénélope\u{A0}!"))
        #expect(!text.contains("Titre") && !text.contains("color") && !text.contains("var x") && !text.contains("<"))
    }

    @Test func epubTextIsExtractedChapterByChapter() throws {
        let url = try makeSampleEPUB()
        let file = try #require(FolderScanner.scan([url.deletingLastPathComponent()]).first { $0.url.lastPathComponent == url.lastPathComponent })
        let book = FolderScanner.makeBook(file, imported: false, coverStore: CoverStore(directory: tempDirectory()))
        let text = try BookText.extract(book)
        #expect(text.sections.count == 3)
        #expect(text.sections[1].contains("Paragraphe 4 du chapitre 2 : « Ça déménage » à l’œil nu…"))
        // Enregistré puis relu à l'identique.
        let saved = tempDirectory().appendingPathComponent("livre.txt")
        try text.save(to: saved)
        #expect(BookText.load(saved) == text)
        var drm = book
        drm.isDRMProtected = true
        #expect(!BookText.canExtract(drm) && (try? BookText.extract(drm)) == nil)
    }

    @Test func indexFindsWordsWithoutAccentsCaseOrWholeWord() throws {
        let index = try ContentIndex(url: tempDirectory().appendingPathComponent("contenu.index"))
        index.add(id: "homere", text: "Chante, ô Muse, l’Odyssée d'Ulysse aux mille ruses.")
        index.add(id: "fourmis", text: "Les fourmis font une longue ODYSSÉE vers la fourmilière.")
        index.add(id: "autre", text: "Rien à voir : un traité de géométrie.")
        index.flush()
        #expect(Set(index.search("odyssee")) == ["homere", "fourmis"])
        #expect(index.search("Ulysse ruses") == ["homere"])
        // Début de mot : la recherche se fait pendant la frappe.
        #expect(Set(index.search("odyss")) == ["homere", "fourmis"])
        #expect(index.search("géométr") == ["autre"])
        index.remove(id: "homere")
        index.flush()
        #expect(index.search("odyssée") == ["fourmis"])
        #expect(index.search("x").isEmpty)
    }

    @Test func snippetsSurroundTheMatchAndCountPassages() {
        let text = BookText(sections: ["Avant. L'Odyssée commence ici.", "Rien.", "Une odyssee, puis une autre ODYSSÉE et encore l'Odyssée."])
        let match = ContentSearch.matches(in: text, query: "odyssée", limit: 3, context: 8)
        #expect(match.count == 4)
        #expect(match.snippets.map(\.section) == [0, 2, 2])
        #expect(match.snippets[0].match == "Odyssée" && match.snippets[0].before == "…vant. L'" && match.snippets[0].after == " commenc…")
        #expect(match.snippets[1].match == "odyssee" && match.snippets[2].match == "ODYSSÉE")
        // Rang de la même graphie dans la section : la deuxième « Odyssée » du chapitre 3 a le rang 0.
        let all = ContentSearch.matches(in: text, query: "Odyssée", limit: 10)
        #expect(all.snippets.last?.match == "Odyssée" && all.snippets.last?.occurrence == 0)
        // Une expression absente : son premier mot.
        #expect(ContentSearch.matches(in: text, query: "odyssée perdue", limit: 10).count == 4)
        // Mots d'une lettre (« l’ », « d’ ») laissés de côté, accents retirés, dernier mot en début de mot.
        #expect(ContentSearch.indexQuery("L’Odyssée d'Homè") == "odyssee home*")
    }

    @Test func oneFilePerBookIsIndexed() {
        func book(_ path: String, _ title: String, _ format: BookFormat, drm: Bool = false) -> Book {
            Book(path: path, format: format, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
                 title: title, authors: ["Homère"], tags: [], hasCover: false, isDRMProtected: drm, isImported: false, asin: "")
        }
        let books = [book("/l/odyssee.mobi", "L'Odyssée", .mobi), book("/l/odyssee.epub", "L'Odyssée", .epub),
                     book("/l/odyssee.pdf", "L'Odyssée", .pdf),
                     book("/l/iliade.azw3", "L'Iliade", .azw3), book("/l/iliade.pdf", "L'Iliade", .pdf),
                     book("/l/protege.epub", "Protégé", .epub, drm: true), book("/l/protege.pdf", "Protégé", .pdf),
                     book("/l/seul.azw", "Seul", .azw)]
        let chosen = BookText.filesToIndex(books, identities: [:]).map(\.path).sorted()
        // L'EPUB de l'Odyssée, l'AZW3 de l'Iliade, le PDF du livre dont l'EPUB est protégé ; rien pour l'AZW.
        #expect(chosen == ["/l/iliade.azw3", "/l/odyssee.epub", "/l/protege.pdf"])
    }

    @Test func exactSpellingKeepsCaseAndAccents() {
        let text = BookText(sections: ["L'Odyssée d'Homère.", "Une longue odyssée.", "Odyssee sans accent, ODYSSÉE en capitales."])
        #expect(ContentSearch.matches(in: text, query: "Odyssée").count == 4)
        let exact = ContentSearch.matches(in: text, query: "Odyssée", exact: true)
        #expect(exact.count == 1 && exact.snippets.map(\.section) == [0])
        #expect(ContentSearch.matches(in: text, query: "odyssée", exact: true).snippets.map(\.section) == [1])
        #expect(ContentSearch.matches(in: text, query: "Iliade", exact: true).count == 0)
    }
}
