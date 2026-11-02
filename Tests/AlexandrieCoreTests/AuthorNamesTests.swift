import Foundation
import Testing
@testable import AlexandrieCore

@Suite struct AuthorNamesTests {
    func book(_ path: String, _ authors: [String]) -> Book {
        Book(path: path, format: .epub, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
             title: path, authors: authors, tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
    }

    @Test func mergesSpellings() {
        let books = [
            book("a", ["Murakami,Haruki"]), book("b", ["Haruki Murakami"]), book("c", ["Murakami, Haruki"]),
            book("d", ["HARARI, Yuval Noah"]), book("e", ["Yuval Noah Harari"]),
            book("f", ["Orwell,George"]), book("g", ["Zoé Oldenbourg", "zoe oldenbourg"]),
            book("h", ["Asimov Isaac"]), book("i", ["Asimov Isaac"]), book("j", ["Asimov Isaac."]),
            book("k", ["Asimov, Isaac"]), book("l", ["Isaac Asimov"]),
            book("m", ["Carl Clausewitz (von)"]), book("n", ["Carl von Clausewitz"]),
        ]
        let groups = AuthorNames.groups(books)
        #expect(groups.map(\.name) == ["Carl von Clausewitz", "George Orwell", "Haruki Murakami",
                                        "Isaac Asimov", "Yuval Noah Harari", "Zoé Oldenbourg"])
        #expect(groups.first { $0.name == "Haruki Murakami" }?.bookCount == 3)
        // Un livre qui cite deux graphies du même auteur ne compte qu'une fois.
        #expect(groups.first { $0.name == "Zoé Oldenbourg" }?.bookCount == 1)
        #expect(AuthorNames.readable("HARARI") == "Harari")
        #expect(AuthorNames.individuals("Edwy Plenel, Lisa Fittko") == ["Edwy Plenel", "Lisa Fittko"])
        #expect(AuthorNames.individuals("Murakami, Haruki") == ["Murakami, Haruki"])
        #expect(AuthorNames.individuals("Aron Matthieu & Caroline Michel-Aguirre").count == 2)
        #expect(AuthorNames.readable("Michel-Aguirre, Caroline") == "Caroline Michel-Aguirre")
    }

    /// Statistiques sur un vrai index (ALEXANDRIE_LIBRARY_INDEX=…/library.json), lecture seule.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALEXANDRIE_LIBRARY_INDEX"] != nil))
    func realLibrary() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALEXANDRIE_LIBRARY_INDEX"]!)
        let books = try LibraryIndex.load(url)
        let raw = Set(books.flatMap(\.authors))
        let groups = AuthorNames.groups(books)
        print("📚 \(books.count) livres : \(raw.count) graphies → \(groups.count) auteurs")
        for g in groups.filter({ $0.variants.count > 1 }).prefix(12) {
            print("   \(g.name) ← \(g.variants.joined(separator: " | "))")
        }
    }
}

@Suite struct BookGroupsTests {
    func book(_ path: String, _ title: String, _ authors: [String], _ format: BookFormat) -> Book {
        Book(path: path, format: format, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
             title: title, authors: authors, tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
    }

    @Test func groupsFormatsOfSameBook() {
        let books = [
            book("1", "1Q84 (Livre 1 - Avril-juin)", ["Murakami,Haruki"], .epub),
            book("2", "1Q84 (Livre 1 - Avril-juin)", ["Haruki Murakami"], .azw3),
            book("3", "1Q84 (livre 1 – avril-juin)", ["Murakami, Haruki"], .mobi),
            book("4", "1Q84 (Livre 2 - Juillet-septembre)", ["Haruki Murakami"], .epub),
            book("5", "1984", ["Orwell,George"], .epub),
            book("6", "1984", ["Autre Auteur"], .epub),
        ]
        let groups = BookGroups.make(books)
        #expect(groups.map(\.books.count) == [3, 1, 1, 1])
        #expect(groups[0].isGroup && groups[0].id == "group:2")
        #expect(groups[0].primary.format == .azw3)
        #expect(groups[0].formats == [.azw3, .mobi, .epub])
        // La série d'un autre fichier complète le fichier principal.
        var withSeries = books
        withSeries[0].series = "1Q84"
        withSeries[0].seriesIndex = 1
        let merged = BookGroups.make(withSeries)[0].primary
        #expect(merged.format == .azw3 && merged.series == "1Q84" && merged.seriesIndex == 1)
        // Un livre seul garde son propre identifiant ; deux « 1984 » d'auteurs différents restent séparés.
        #expect(groups[1].id == "4")
        #expect(groups[2].id == "5" && groups[3].id == "6")
    }

    @Test func genreMentionDoesNotSplitBook() {
        var withGenre = book("2", "Brunetti et le mauvais augure : roman", ["Donna Leon"], .epub)
        withGenre.genre = "Roman"
        let books = [book("1", "Brunetti et le mauvais augure", ["Leon, Donna"], .azw3), withGenre,
                     book("3", "Le grand détournement : comment milliardaires", ["Matthieu Aron"], .epub),
                     book("4", "Le grand détournement", ["Matthieu Aron"], .epub)]
        let groups = BookGroups.make(books)
        #expect(groups.map(\.books.count) == [2, 1, 1])
        #expect(groups[0].primary.title == "Brunetti et le mauvais augure")
        #expect(groups[0].primary.genre == "Roman")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALEXANDRIE_LIBRARY_INDEX"] != nil))
    func realLibraryGroups() throws {
        let books = try LibraryIndex.load(URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALEXANDRIE_LIBRARY_INDEX"]!))
        let groups = BookGroups.make(books)
        print("📚 \(books.count) fichiers → \(groups.count) livres (\(groups.filter(\.isGroup).count) en plusieurs fichiers)")
        for g in groups.filter(\.isGroup).prefix(6) {
            print("   \(g.primary.title.prefix(45)) : \(g.formats.map(\.label).joined(separator: ", ")) (\(g.books.count))")
        }
    }
}
