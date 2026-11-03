import Foundation
import Testing
@testable import AlexandrieCore

/// Réponse SRU BnF au format observé (une notice sonore à écarter, une notice imprimée).
let bnfResponse = Data("""
<?xml version="1.0" encoding="UTF-8"?>
<srw:searchRetrieveResponse xmlns:srw="http://www.loc.gov/zing/srw/"><srw:numberOfRecords>2</srw:numberOfRecords><srw:records>
<srw:record><srw:recordData><oai_dc:dc xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/" xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier>http://catalogue.bnf.fr/ark:/12148/cb1</dc:identifier><dc:title>L'ETRANGER / Albert CAMUS ; Lu par Albert CAMUS</dc:title>
<dc:date>1961</dc:date><dc:type xml:lang="fre">enregistrement sonore</dc:type></oai_dc:dc></srw:recordData></srw:record>
<srw:record><srw:recordData><oai_dc:dc xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/" xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier>http://catalogue.bnf.fr/ark:/12148/cb48676718h</dc:identifier>
<dc:title>Le grand détournement : comment milliardaires et multinationales captent l'argent de l'État / Matthieu Aron, Caroline Michel-Aguirre</dc:title>
<dc:creator>Aron, Matthieu (1963-....). Auteur du texte / Autrice du texte</dc:creator>
<dc:creator>Michel-Aguirre, Caroline (1987-....). Auteur du texte / Autrice du texte</dc:creator>
<dc:creator>Dupont, Jean. Traducteur</dc:creator>
<dc:publisher>Allary éditions (Paris)</dc:publisher><dc:date>2025</dc:date>
<dc:identifier>ISBN 9782370735676</dc:identifier><dc:language>fre</dc:language>
<dc:type xml:lang="fre">texte imprimé</dc:type></oai_dc:dc></srw:recordData></srw:record>
</srw:records></srw:searchRetrieveResponse>
""".utf8)

@Suite struct ISBNTests {
    @Test func validatesAndConverts() {
        #expect(ISBN.isValid("978-2-37073-567-6"))
        #expect(ISBN.isValid("2070360024"))
        #expect(ISBN.isValid("080442957X"))
        #expect(!ISBN.isValid("9782370735677"))
        #expect(!ISBN.isValid("1234567890"))
        #expect(ISBN.normalized("2070360024") == "9782070360024")
        #expect(ISBN.to10("9782070360024") == "2070360024")
        #expect(ISBN.to10("9791234567896") == nil)
        #expect(ISBN.first(in: ["urn:uuid:abc", "urn:isbn:978-2-07-036002-4"]) == "9782070360024")
        #expect(ISBN.first(in: ["ISBN 2070360024 (br.)"]) == "9782070360024")
    }
}

@Suite struct CatalogTests {
    @Test func parsesBnF() {
        let records = BnFCatalog.parse(bnfResponse, match: .titleAuthor)
        #expect(records.count == 1)
        let r = records[0]
        #expect(r.title == "Le grand détournement : comment milliardaires et multinationales captent l'argent de l'État")
        #expect(r.authors == ["Matthieu Aron", "Caroline Michel-Aguirre"])
        #expect(r.publisher == "Allary éditions")
        #expect(r.publishedDate == "2025")
        #expect(r.isbn == "9782370735676")
        #expect(r.language == "fr")
        #expect(r.url == "http://catalogue.bnf.fr/ark:/12148/cb48676718h")
    }

    @Test func parsesOpenLibrary() {
        let isbn = Data(#"{"ISBN:9782070360024": {"url": "https://openlibrary.org/books/OL1M", "title": "L’étranger", "authors": [{"name": "Albert Camus"}], "publishers": [{"name": "Gallimard"}], "publish_date": "07-01-1972"}}"#.utf8)
        let r = OpenLibraryCatalog.parseISBN(isbn, isbn: "9782070360024")
        #expect(r?.title == "L’étranger")
        #expect(r?.publishedDate == "1972")
        #expect(OpenLibraryCatalog.parseISBN(Data("{}".utf8), isbn: "x") == nil)
    }

    @Test func comparesWithoutNoise() {
        let r = BnFCatalog.parse(bnfResponse, match: .titleAuthor)[0]
        // Même livre, écrit autrement : aucune différence sur titre, auteurs, éditeur, date, langue.
        let same = MetadataEdits(title: "Le grand détournement - Comment milliardaires et multinationales captent l'argent de l'État",
                                 authors: ["Michel-Aguirre, Caroline", "aron, matthieu"], publisher: "Allary Éditions",
                                 language: "fr-FR", publishedDate: "2025-09-10")
        #expect(CatalogComparison.differences(same, r).map(\.field) == [.isbn])

        // Erreurs typiques : auteur dans le titre, date manquante, ISBN invalide.
        let broken = MetadataEdits(title: "2026", authors: ["Le grand détournement"], isbn: "9782370735677")
        let fields = Set(CatalogComparison.differences(broken, r).map(\.field))
        #expect(fields == [.isbn, .title, .authors, .publisher, .publishedDate, .language])

        var fixed = broken
        CatalogComparison.apply([.title, .authors, .isbn], from: r, to: &fixed)
        #expect(fixed.title == r.title && fixed.authors == r.authors && fixed.isbn == "9782370735676")
        #expect(fixed.publisher == nil)
    }

    @Test func keepsValidEbookISBNFromTitleSearch() {
        let r = BnFCatalog.parse(bnfResponse, match: .titleAuthor)[0]
        let ebook = MetadataEdits(title: "Le grand détournement", authors: ["Matthieu Aron", "Caroline Michel-Aguirre"],
                                  isbn: "9782070360024")
        #expect(!CatalogComparison.differences(ebook, r).contains { $0.field == .isbn })
    }

    @Test func lookupFallsBackToTitleSearch() async throws {
        let queried = Box()
        let client = CatalogClient { url in
            queried.urls.append(url)
            let q = url.absoluteString
            if q.contains("openlibrary.org/api/books") { return Data("{}".utf8) }
            if q.contains("bib.isbn") { return Data("<r/>".utf8) }
            if q.contains("bib.title") { return bnfResponse }
            return Data(#"{"docs": []}"#.utf8)
        }
        let book = MetadataEdits(title: "Le grand détournement (French Edition)", authors: ["Aron, Matthieu"],
                                 isbn: "978-2-37073-567-7")   // ISBN invalide → recherche directe par titre
        let r = try await client.lookup(book)
        #expect(r?.isbn == "9782370735676")
        #expect(queried.urls.count == 1)
        #expect(queried.urls[0].absoluteString.contains("aron"))

        // Titre sans rapport : la notice trouvée est rejetée.
        #expect(try await client.lookup(MetadataEdits(title: "Autre chose", authors: ["Aron"])) == nil)
    }
}

final class Box: @unchecked Sendable { var urls: [URL] = [] }

/// Vraies requêtes réseau, activées par ALEXANDRIE_NETWORK=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ALEXANDRIE_NETWORK"] != nil))
struct LiveCatalogTests {
    @Test func realLookups() async throws {
        let client = CatalogClient()
        let byISBN = try await client.lookup(MetadataEdits(title: "x", authors: [], isbn: "9782070360024"))
        print("ISBN →", byISBN as Any)
        #expect(byISBN?.source == "BnF")
        #expect(byISBN?.publisher == "Gallimard")

        let byTitle = try await client.lookup(MetadataEdits(title: "Le grand détournement - Comment milliardaires",
                                                            authors: ["Matthieu Aron"]))
        print("Titre →", byTitle as Any)
        #expect(byTitle?.isbn == "9782370735676")

        let english = try await client.lookup(MetadataEdits(title: "Moby Dick; Or, The Whale", authors: ["Herman Melville"]))
        print("Moby Dick →", english as Any)
        #expect(english != nil)
    }
}

@Suite struct CatalogFallbackTests {
    static let olISBN = Data(#"{"ISBN:9782070360024": {"url": "https://openlibrary.org/books/OL1M", "title": "L’étranger", "authors": [{"name": "Albert Camus"}], "publishers": [{"name": "Gallimard"}], "publish_date": "1972"}}"#.utf8)
    static let tlsError = URLError(.secureConnectionFailed, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://catalogue.bnf.fr/api/SRU")!])
    let book = MetadataEdits(title: "L'Étranger", authors: ["Albert Camus"], isbn: "9782070360024")

    @Test func bnfDownFallsBackToOpenLibrary() async throws {
        let client = CatalogClient { url in
            if url.host == "catalogue.bnf.fr" { throw Self.tlsError }
            return Self.olISBN
        }
        let r = try await client.lookup(book)
        #expect(r?.source == "Open Library")
        #expect(r?.title == "L’étranger")
    }

    @Test func outageIsNotReportedAsNoRecord() async {
        let client = CatalogClient { url in
            if url.host == "catalogue.bnf.fr" { throw Self.tlsError }
            return Data("{}".utf8)
        }
        await #expect(throws: URLError.self) { try await client.lookup(book) }
    }

    @Test func friendlyMessage() {
        #expect(CatalogClient.describe(Self.tlsError)
                == "Vérification impossible : le catalogue de la BnF ne répond pas pour le moment. Réessayez plus tard.")
        #expect(CatalogClient.describe(URLError(.notConnectedToInternet)) == "Vérification impossible : pas de connexion Internet.")
    }
}

@Suite struct GenreMentionTests {
    @Test func removesGenreOnly() {
        #expect(Matching.withoutGenre("Brunetti et le mauvais augure : roman") == "Brunetti et le mauvais augure")
        #expect(Matching.withoutGenre("Le Crime de l'Orient-Express : roman policier") == "Le Crime de l'Orient-Express")
        #expect(Matching.withoutGenre("Les Fleurs du mal : Poèmes.") == "Les Fleurs du mal")
        #expect(Matching.withoutGenre("Dix petits nègres : nouvelles inédites") == "Dix petits nègres")
        // Vrais sous-titres conservés.
        #expect(Matching.withoutGenre("Le grand détournement : comment milliardaires et multinationales captent l'argent de l'État")
                == "Le grand détournement : comment milliardaires et multinationales captent l'argent de l'État")
        #expect(Matching.withoutGenre("Bernanos : journal d'un curé de campagne") == "Bernanos : journal d'un curé de campagne")
        #expect(Matching.withoutGenre("Romans") == "Romans")
    }

    @Test func savedRecordNoLongerProposesGenre() {
        let edits = MetadataEdits(title: "Brunetti et le mauvais augure", authors: ["Donna Leon"])
        let record = CatalogRecord(source: "BnF", url: nil, match: .titleAuthor, isbn: nil,
                                   title: "Brunetti et le mauvais augure : roman", authors: ["Donna Leon"],
                                   publisher: nil, publishedDate: nil, language: nil)
        let differences = CatalogComparison.differences(edits, record)
        #expect(!differences.contains { $0.field == .title })
        // Le genre retiré du titre est proposé à part.
        #expect(differences.first { $0.field == .genre }?.proposed == "Roman")
        var other = MetadataEdits(title: "Brunetti 21", authors: ["Donna Leon"])
        CatalogComparison.apply([.title, .genre], from: record, to: &other)
        #expect(other.title == "Brunetti et le mauvais augure")
        #expect(other.genre == "Roman")
        #expect(!CatalogComparison.differences(other, record).contains { $0.field == .genre })
    }

    @Test func splitsGenre() {
        #expect(Matching.splitGenre("Le Crime de l'Orient-Express : roman policier") == ("Le Crime de l'Orient-Express", "Roman policier"))
        #expect(Matching.splitGenre("Les Fleurs du mal : Poèmes.").genre == "Poèmes")
        #expect(Matching.splitGenre("Le grand détournement : comment milliardaires").genre == nil)
    }

    @Test func bnfRecordCarriesGenre() {
        let xml = String(decoding: bnfResponse, as: UTF8.self).replacingOccurrences(
            of: "Le grand détournement : comment milliardaires et multinationales captent l'argent de l'État",
            with: "Le grand détournement : roman")
        let r = BnFCatalog.parse(Data(xml.utf8), match: .titleAuthor).first
        #expect(r?.title == "Le grand détournement")
        #expect(r?.genre == "Roman")
    }
}

@Suite struct CatalogReviewTests {
    func book(_ path: String, _ title: String, _ format: BookFormat, record: CatalogRecord?) -> Book {
        var b = Book(path: path, format: format, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
                     title: title, authors: ["Thomas Piketty"], tags: [], hasCover: false, isDRMProtected: false,
                     isImported: false, asin: "A")
        b.catalogRecord = record
        return b
    }

    @Test func oneRowPerBookAndField() {
        let record = CatalogRecord(source: "BnF", url: nil, match: .titleAuthor, isbn: "9782021338041",
                                   title: "Capital et idéologie", authors: ["Thomas Piketty"],
                                   publisher: "Éditions Points", publishedDate: "2022", language: nil)
        let groups = BookGroups.make([book("/a.azw3", "Capital et idéologie", .azw3, record: record),
                                      book("/a.epub", "Capital et idéologie", .epub, record: nil),
                                      book("/b.epub", "Sans notice", .epub, record: nil)])
        let rows = CatalogReview.rows(groups)
        #expect(Set(rows.map(\.difference.field)) == [.isbn, .publisher, .publishedDate])
        #expect(rows.allSatisfy { $0.book.id == "/a.azw3" && Set($0.fileIDs) == ["/a.azw3", "/a.epub"] })
        let byBook = CatalogReview.fieldsByBook(rows.filter { $0.difference.field != .publisher })
        #expect(byBook["/a.azw3"]?.fields == [.isbn, .publishedDate])
    }
}
