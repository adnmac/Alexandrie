import Foundation
import Testing
@testable import AlexandrieCore

/// Accueil Gutenberg, tel qu'observé (liens relatifs, recherche OpenSearch, vignette `data:`).
let gutenbergRoot = Data("""
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog" xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
<id>http://www.gutenberg.org/ebooks.opds/</id>
<title>Project Gutenberg</title>
<subtitle>Free eBooks since 1971.</subtitle>
<link rel="search" type="application/opensearchdescription+xml" href="https://www.gutenberg.org/catalog/osd-books.xml"/>
<link rel="self" type="application/atom+xml;profile=opds-catalog" href="/ebooks.opds/"/>
<link rel="next" type="application/atom+xml;profile=opds-catalog" href="/ebooks.opds/?start_index=26"/>
<entry>
<id>https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads</id>
<title>Popular</title>
<content type="text">Our most popular books.</content>
<link type="application/atom+xml;profile=opds-catalog" rel="subsection" href="/ebooks/search.opds/?sort_order=downloads"/>
<link type="image/png" rel="http://opds-spec.org/image/thumbnail" href="data:image/png;base64,iVBORw0KGgo="/>
</entry>
</feed>
""".utf8)

/// Fiche d'un livre Gutenberg : contenu XHTML, EPUB et MOBI, couvertures.
let gutenbergBook = Data("""
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">
<id>http://www.gutenberg.org/ebooks/164.opds</id>
<title>Twenty Thousand Leagues under the Sea</title>
<entry>
<title>Twenty Thousand Leagues under the Sea</title>
<content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>This edition had all images removed.</p>
<p>Summary:
  A science fiction adventure.</p></div></content>
<id>urn:gutenberg:164:2</id>
<author><name>Verne, Jules</name></author>
<dcterms:language>en</dcterms:language>
<link type="application/x-mobipocket-ebook" rel="http://opds-spec.org/acquisition" length="563526" href="https://www.gutenberg.org/ebooks/164.kindle.noimages"/>
<link type="application/epub+zip" rel="http://opds-spec.org/acquisition" length="370585" href="https://www.gutenberg.org/ebooks/164.epub.noimages"/>
<link type="application/epub+zip" rel="http://opds-spec.org/acquisition" href="https://www.gutenberg.org/ebooks/164.epub3.images"/>
<link type="image/jpeg" rel="http://opds-spec.org/image" href="https://www.gutenberg.org/cache/epub/164/pg164.cover.medium.jpg"/>
<link type="image/jpeg" rel="http://opds-spec.org/image/thumbnail" href="https://www.gutenberg.org/cache/epub/164/pg164.cover.small.jpg"/>
<link type="application/atom+xml;profile=opds-catalog" rel="related" href="/ebooks/author/60.opds" title="By Verne, Jules…"/>
</entry>
</feed>
""".utf8)

/// Flux COPS (Bibliothèque numérique romande) : liens relatifs au dossier, résumé HTML, un livre acheté
/// et un livre sous DRM à écarter.
let copsFeed = Data("""
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog" xmlns:dcterms="http://purl.org/dc/terms/">
 <title>Bibliothèque numérique romande</title>
 <id>cops:catalog</id>
 <link href="feed.php?page=8" type="application/opensearchdescription+xml" rel="search"/>
 <entry>
  <title>Toinon</title>
  <id>urn:uuid:96839cb1</id>
  <content type="text/html">1884. Pierre&lt;br /&gt;fils d’une famille &amp;eacute; pauvre.</content>
  <link href="fetch.php?height=164&amp;id=1468" type="image/jpeg" rel="http://opds-spec.org/image/thumbnail"/>
  <link href="fetch.php?data=721&amp;type=epub&amp;id=1468" type="application/epub+zip" rel="http://opds-spec.org/acquisition" title="EPUB"/>
  <link href="index.php?page=3&amp;id=237" type="application/atom+xml;profile=opds-catalog;kind=navigation" rel="related" title="Other books by André Léo"/>
  <author><name>André Léo</name></author>
 </entry>
 <entry>
  <title>Livre payant</title>
  <id>urn:buy</id>
  <link href="buy.php?id=1" type="application/epub+zip" rel="http://opds-spec.org/acquisition/buy"/>
 </entry>
 <entry>
  <title>Livre sous DRM</title>
  <id>urn:drm</id>
  <link href="get.php?id=2" type="application/vnd.adobe.adept+xml" rel="http://opds-spec.org/acquisition">
   <opds:indirectAcquisition type="application/epub+zip"/>
  </link>
  <link href="get.php?id=3" type="application/epub+zip" rel="http://opds-spec.org/acquisition">
   <opds:indirectAcquisition type="application/vnd.readium.lcp.license.v1.0+json"/>
  </link>
 </entry>
 <entry>
  <title>Authors</title>
  <id>cops:authors</id>
  <link href="index.php?page=1" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
 </entry>
</feed>
""".utf8)

let gutenbergOSD = Data("""
<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
   <Url type="text/html" template="http://www.gutenberg.org/ebooks/search/?query={searchTerms}"/>
   <Url type="application/atom+xml" template="http://m.gutenberg.org/ebooks/search.opds/?query={searchTerms}"/>
   <Url type="application/x-suggestions+json" rel="suggestions" template="http://www.gutenberg.org/ebooks/suggest/?query={searchTerms}"/>
</OpenSearchDescription>
""".utf8)

@Suite struct OPDSParserTests {
    let gutenberg = URL(string: "https://www.gutenberg.org/ebooks.opds/")!

    @Test func parsesNavigationFeed() throws {
        let feed = try OPDSParser.feed(gutenbergRoot, url: gutenberg)
        #expect(feed.title == "Project Gutenberg")
        #expect(feed.subtitle == "Free eBooks since 1971.")
        #expect(feed.nextURL?.absoluteString == "https://www.gutenberg.org/ebooks.opds/?start_index=26")
        #expect(feed.search == .description(URL(string: "https://www.gutenberg.org/catalog/osd-books.xml")!))
        let popular = try #require(feed.entries.first)
        #expect(!popular.isBook)
        #expect(popular.navigationURL?.absoluteString == "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads")
        #expect(popular.summary == "Our most popular books.")
        #expect(popular.thumbnailURL == nil, "les vignettes data: sont ignorées")
    }

    @Test func parsesBookEntry() throws {
        let feed = try OPDSParser.feed(gutenbergBook, url: URL(string: "https://www.gutenberg.org/ebooks/164.opds")!)
        let book = try #require(feed.entries.first)
        #expect(book.isBook)
        #expect(book.authors == ["Verne, Jules"])
        #expect(book.language == "en")
        #expect(book.summary == "This edition had all images removed.\nSummary: A science fiction adventure.")
        #expect(book.acquisitions.map(\.format) == [.epub, .mobi], "un fichier par format, EPUB d'abord")
        #expect(book.acquisitions.first?.url.absoluteString == "https://www.gutenberg.org/ebooks/164.epub.noimages")
        #expect(book.acquisitions.first?.length == 370585)
        #expect(book.thumbnailURL?.lastPathComponent == "pg164.cover.small.jpg")
        #expect(book.related.map(\.title) == ["By Verne, Jules…"])
        #expect(book.related.first?.url.absoluteString == "https://www.gutenberg.org/ebooks/author/60.opds")
    }

    @Test func resolvesRelativeLinksAndSkipsPaidAndDRM() throws {
        let base = URL(string: "https://ebooks-bnr.com/opds/index.php?page=10")!
        let feed = try OPDSParser.feed(copsFeed, url: base)
        #expect(feed.search == .description(URL(string: "https://ebooks-bnr.com/opds/feed.php?page=8")!))
        let toinon = feed.entries[0]
        #expect(toinon.acquisitions.first?.url.absoluteString == "https://ebooks-bnr.com/opds/fetch.php?data=721&type=epub&id=1468")
        #expect(toinon.summary == "1884. Pierre\nfils d’une famille é pauvre.")
        #expect(toinon.related.first?.title == "Other books by André Léo")
        #expect(!feed.entries[1].isBook, "acquisition/buy écartée")
        #expect(!feed.entries[2].isBook, "acquisitions indirectes (DRM) écartées")
        #expect(feed.entries[3].navigationURL?.absoluteString == "https://ebooks-bnr.com/opds/index.php?page=1")
    }

    @Test func readsOpenSearchTemplate() throws {
        let t = try OPDSParser.searchTemplate(gutenbergOSD, url: URL(string: "https://www.gutenberg.org/catalog/osd-books.xml")!)
        let url = try #require(t.url(for: "jules verne & co"))
        #expect(url.absoluteString == "https://m.gutenberg.org/ebooks/search.opds/?query=jules%20verne%20%26%20co",
                "gabarit Atom choisi, passé en HTTPS, mots encodés")
        #expect(t.url(for: "   ") == nil)
        let optional = OPDSSearchTemplate("https://x.org/s?q={searchTerms}&p={startPage?}&l={language?}")
        #expect(optional.url(for: "a")?.absoluteString == "https://x.org/s?q=a&p=1&l=")
    }

    @Test func resolvesRelativeTemplates() throws {
        // Description COPS : gabarit relatif au dossier de la description, pas à la racine du site.
        let osd = Data(#"<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"><Url type="application/atom+xml" template="feed.php?query={searchTerms}"/></OpenSearchDescription>"#.utf8)
        let t = try OPDSParser.searchTemplate(osd, url: URL(string: "https://ebooks-bnr.com/opds/index.php?page=8")!)
        #expect(t.url(for: "verne")?.absoluteString == "https://ebooks-bnr.com/opds/feed.php?query=verne")
        let rooted = OPDSParser.resolveTemplate("/opds/search/{searchTerms}?p={startPage?}", against: URL(string: "https://x.org/a/b")!)
        #expect(rooted.url(for: "a b")?.absoluteString == "https://x.org/opds/search/a%20b?p=1")
    }

    @Test func rejectsWebPagesAndOPDS2() {
        let html = Data("<!doctype html><html><head><title>404</title></head><body>Introuvable</body></html>".utf8)
        #expect(throws: OPDSError.notAFeed) { try OPDSParser.feed(html, url: gutenberg) }
        #expect(throws: OPDSError.opds2) { try OPDSParser.feed(Data(#"  {"metadata": {}}"#.utf8), url: gutenberg) }
        #expect(throws: OPDSError.noSearch) { try OPDSParser.searchTemplate(gutenbergRoot, url: gutenberg) }
    }

    @Test func securesAddresses() {
        #expect(OPDSURL.secure(URL(string: "http://m.gutenberg.org:80/a")!)?.absoluteString == "https://m.gutenberg.org/a")
        #expect(OPDSURL.secure(URL(string: "ftp://x.org/")!) == nil)
        #expect(OPDSURL.secure(URL(string: "file:///etc/passwd")!) == nil)
        #expect(OPDSURL.parse("ebooks-bnr.com/opds/")?.absoluteString == "https://ebooks-bnr.com/opds/")
        #expect(OPDSURL.parse("pas une adresse") == nil)
        #expect(OPDSURL.parse("") == nil)
    }
}

@Suite struct OPDSClientTests {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
        func add(_ u: URL) { lock.withLock { urls.append(u) } }
    }

    @Test func searchesThroughOpenSearchDescription() async throws {
        let calls = Calls()
        let client = OPDSClient { url in
            calls.add(url)
            if url.path.hasSuffix("osd-books.xml") { return (gutenbergOSD, url) }
            // Redirection observée : m.gutenberg.org → www.
            return (gutenbergBook, URL(string: "https://www.gutenberg.org/ebooks/search.opds/?query=verne")!)
        }
        let root = try OPDSParser.feed(gutenbergRoot, url: URL(string: "https://www.gutenberg.org/ebooks.opds/")!)
        let template = try await client.searchTemplate(try #require(root.search))
        let results = try await client.search("verne", with: template)
        #expect(calls.urls.map(\.host) == ["www.gutenberg.org", "m.gutenberg.org"])
        #expect(results.url.host == "www.gutenberg.org", "liens rattachés à l'adresse finale")
        #expect(results.entries.first?.isBook == true)
    }

    @Test func downloadsAndChecksTheFile() async throws {
        let epub = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 100)
        let html = Data("<html>Connexion requise</html>".utf8)
        let client = OPDSClient { url in (url.lastPathComponent.hasPrefix("bad") ? html : epub, url) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("opds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = OPDSEntry(id: "1", title: "Vingt mille lieues : sous les mers", authors: ["Jules Verne"])

        let ok = OPDSAcquisition(url: URL(string: "https://x.org/164.epub.noimages")!, format: .epub)
        let file = try await client.download(ok, of: entry, into: dir)
        #expect(file.lastPathComponent == "Jules Verne - Vingt mille lieues sous les mers.epub")
        #expect(try Data(contentsOf: file) == epub)

        let bad = OPDSAcquisition(url: URL(string: "https://x.org/bad.epub")!, format: .epub)
        await #expect(throws: OPDSError.wrongFormat(.epub)) { try await client.download(bad, of: entry, into: dir) }
        let huge = OPDSAcquisition(url: ok.url, format: .epub, length: Int64(OPDSClient.maxDownload) + 1)
        await #expect(throws: OPDSError.tooLarge) { try await client.download(huge, of: entry, into: dir) }
    }

    @Test func retriesCOPSFeedWithIndex() async throws {
        let calls = Calls()
        let client = OPDSClient { url in
            calls.add(url)
            if url.lastPathComponent == "feed.php" { throw URLError(.badServerResponse) }
            return (copsFeed, url)
        }
        let feed = try await client.feed(at: URL(string: "https://ebooks-bnr.com/opds/feed.php?query=verne")!)
        #expect(feed.url.absoluteString == "https://ebooks-bnr.com/opds/index.php?query=verne")
        #expect(calls.urls.count == 2)
        // Une autre adresse en échec n'est pas réessayée.
        let down = Calls()
        let failing = OPDSClient { url in down.add(url); throw URLError(.badServerResponse) }
        await #expect(throws: URLError.self) { try await failing.feed(at: URL(string: "https://x.org/autre.php")!) }
        #expect(down.urls.count == 1)
    }

    @Test func refusesInsecureFeeds() async {
        let client = OPDSClient { url in (gutenbergRoot, url) }
        await #expect(throws: OPDSError.insecure) { try await client.feed(at: URL(string: "file:///tmp/x.xml")!) }
    }

    @Test func namesFilesSafely() {
        let e = OPDSEntry(id: "x", title: "../..: a/b?", authors: [])
        #expect(OPDSClient.fileName(for: e, format: .pdf) == "a b.pdf")
        let long = OPDSEntry(id: "y", title: String(repeating: "é", count: 300))
        #expect(OPDSClient.fileName(for: long, format: .epub).count == 125)
        #expect(OPDSClient.fileName(for: OPDSEntry(id: "z", title: "///"), format: .mobi) == "Livre.mobi")
    }

    @Test func recognizesSignatures() {
        var mobi = Data(repeating: 0, count: 68)
        mobi.replaceSubrange(60..<68, with: Array("BOOKMOBI".utf8))
        #expect(OPDSClient.looksLike(.mobi, mobi))
        #expect(OPDSClient.looksLike(.azw3, mobi))
        #expect(!OPDSClient.looksLike(.mobi, Data("%PDF-1.7".utf8)))
        #expect(OPDSClient.looksLike(.pdf, Data("%PDF-1.7".utf8)))
    }
}

@Suite struct OPDSLanguageTests {
    @Test func normalizesAndFilters() {
        #expect(["fr", "fre", "fra", "fr-FR", "FR", "fr_BE"].allSatisfy { OPDSLanguage.normalized($0) == "fr" })
        #expect(OPDSLanguage.normalized("eng") == "en")
        #expect(OPDSLanguage.name("fr") == "Français")
        let acq = [OPDSAcquisition(url: URL(string: "https://x.org/a.epub")!, format: .epub)]
        let english = OPDSEntry(id: "1", title: "Treasure Island", language: "eng", acquisitions: acq)
        let unknown = OPDSEntry(id: "2", title: "Sans langue", acquisitions: acq)
        let section = OPDSEntry(id: "3", title: "Authors", language: "en", navigationURL: URL(string: "https://x.org/a")!)
        #expect(!OPDSLanguage.keeps(english, language: "fr"))
        #expect(OPDSLanguage.keeps(english, language: "en"))
        #expect(OPDSLanguage.keeps(english, language: nil))
        #expect(OPDSLanguage.keeps(unknown, language: "fr"), "langue non indiquée : le livre reste")
        #expect(OPDSLanguage.keeps(section, language: "fr"), "les rubriques restent")
    }

    @Test func readsGutenbergBookLinks() throws {
        let gutenberg = try #require(OPDSCatalog.suggested.first { $0.id == "gutenberg" })
        func link(_ title: String, _ path: String) -> OPDSEntry {
            OPDSEntry(id: path, title: title, navigationURL: URL(string: "https://www.gutenberg.org" + path)!)
        }
        let french = link("Le tour du monde en quatre-vingts jours (French)", "/ebooks/800.opds")
        let english = link("Around the World in Eighty Days", "/ebooks/103.opds")
        let german = link("Die Verwandlung (German)", "/ebooks/22367.opds")
        let authors = link("Authors", "/ebooks/authors/search.opds/?query=verne")
        let parenthesis = link("Poems (Selected)", "/ebooks/42.opds")
        #expect(OPDSLanguage.language(of: french, in: gutenberg) == "fr")
        #expect(OPDSLanguage.language(of: english, in: gutenberg) == "en", "titre sans mention : anglais chez Gutenberg")
        #expect(OPDSLanguage.language(of: parenthesis, in: gutenberg) == "en", "parenthèse qui n'est pas une langue")
        #expect([french, english, german, authors].filter { OPDSLanguage.keeps($0, language: "fr", in: gutenberg) }
                .map(\.title) == [french.title, "Authors"], "livres d'une autre langue écartés, rubriques gardées")
        #expect(!OPDSLanguage.isBook(authors, in: gutenberg))
        // Ailleurs, un lien de navigation sans langue connue n'est pas un livre : il reste.
        let other = OPDSCatalog(name: "Autre", url: URL(string: "https://x.org/opds")!)
        #expect(OPDSLanguage.keeps(link("Around the World", "/ebooks/103.opds"), language: "fr", in: other))
    }

    @Test func restrictsGutenbergListsOnServer() throws {
        let gutenberg = try #require(OPDSCatalog.suggested.first { $0.id == "gutenberg" })
        let popular = URL(string: "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads")!
        #expect(OPDSLanguage.url(popular, language: "fr", catalog: gutenberg).absoluteString
                == "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads&query=l.fr")
        let next = URL(string: "https://www.gutenberg.org/ebooks/search.opds/?query=verne%20l.fr&start_index=26")!
        #expect(OPDSLanguage.url(next, language: "fr", catalog: gutenberg) == next, "pas de doublon")
        let search = URL(string: "https://www.gutenberg.org/ebooks/search.opds/?query=verne")!
        #expect(OPDSLanguage.url(search, language: "de", catalog: gutenberg).absoluteString.hasSuffix("query=verne%20l.de"))
        let author = URL(string: "https://www.gutenberg.org/ebooks/author/60.opds")!
        #expect(OPDSLanguage.url(author, language: "fr", catalog: gutenberg) == author)
        #expect(!OPDSLanguage.restrictsOnServer(author, catalog: gutenberg))
        #expect(OPDSLanguage.url(popular, language: nil, catalog: gutenberg) == popular)
        let bnr = try #require(OPDSCatalog.suggested.first { $0.id == "bnr" })
        #expect(OPDSLanguage.url(popular, language: "fr", catalog: bnr) == popular)
    }

    @Test func addsServerSyntax() throws {
        let gutenberg = try #require(OPDSCatalog.suggested.first { $0.id == "gutenberg" })
        let bnr = try #require(OPDSCatalog.suggested.first { $0.id == "bnr" })
        #expect(OPDSLanguage.terms("verne", language: "fr", catalog: gutenberg) == "verne l.fr")
        #expect(OPDSLanguage.terms("verne", language: nil, catalog: gutenberg) == "verne")
        #expect(OPDSLanguage.terms("verne", language: "fr", catalog: bnr) == "verne")
        #expect(bnr.onlyLanguage == "fr" && gutenberg.onlyLanguage == nil)
    }
}

@Suite struct OPDSCatalogListTests {
    @Test func managesCatalogs() throws {
        var list = OPDSCatalogList()
        #expect(list.catalogs.map(\.id) == ["gutenberg", "ebooksgratuits", "bnr"])
        let added = list.add(name: "  ", url: URL(string: "https://exemple.org/opds")!)
        #expect(added.name == "exemple.org")
        #expect(list.add(name: "Doublon", url: URL(string: "https://EXEMPLE.org/opds/")!).id == added.id)
        list.rename("gutenberg", to: "Gutenberg")
        list.rename(added.id, to: "Exemple")
        list.remove("bnr")
        #expect(list.catalogs.map(\.name) == ["Gutenberg", "Ebooks libres et gratuits", "Exemple"])
        // Rajouter l'adresse d'un catalogue proposé retiré le rétablit.
        #expect(list.add(name: "x", url: URL(string: "https://ebooks-bnr.com/opds")!).id == "bnr")
        list.remove(added.id)
        list.restoreSuggestions()
        #expect(list.catalogs.map(\.name) == ["Project Gutenberg", "Ebooks libres et gratuits", "Bibliothèque numérique romande"])

        list.downloads["urn:gutenberg:164:2"] = "/tmp/a.epub"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("opds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try list.save(to: file)
        #expect(OPDSCatalogList.load(file) == list)
        #expect(OPDSCatalogList.load(file.appendingPathExtension("absent")) == OPDSCatalogList())
    }

    @Test func readsFilesFromBeforeLanguages() throws {
        let old = Data(#"{"added":[],"downloads":{"urn:a":"/tmp/a.epub"},"hiddenSuggestions":["bnr"],"renamed":{}}"#.utf8)
        let list = try JSONDecoder().decode(OPDSCatalogList.self, from: old)
        #expect(list.downloads["urn:a"] == "/tmp/a.epub" && list.hiddenSuggestions == ["bnr"] && list.languages.isEmpty)
        var withLanguage = list
        withLanguage.languages["gutenberg"] = "fr"
        let again = try JSONDecoder().decode(OPDSCatalogList.self, from: JSONEncoder().encode(withLanguage))
        #expect(again == withLanguage)
    }
}
