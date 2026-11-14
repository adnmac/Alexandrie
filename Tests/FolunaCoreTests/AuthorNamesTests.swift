import Foundation
import Testing
@testable import FolunaCore

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

    /// Statistiques sur un vrai index (FOLUNA_LIBRARY_INDEX=…/library.json), lecture seule.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLUNA_LIBRARY_INDEX"] != nil))
    func realLibrary() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLUNA_LIBRARY_INDEX"]!)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLUNA_LIBRARY_INDEX"] != nil))
    func realLibraryGroups() throws {
        let books = try LibraryIndex.load(URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLUNA_LIBRARY_INDEX"]!))
        let groups = BookGroups.make(books)
        print("📚 \(books.count) fichiers → \(groups.count) livres (\(groups.filter(\.isGroup).count) en plusieurs fichiers)")
        for g in groups.filter(\.isGroup).prefix(6) {
            print("   \(g.primary.title.prefix(45)) : \(g.formats.map(\.label).joined(separator: ", ")) (\(g.books.count))")
        }
    }
}

@Suite struct DuplicateFilesTests {
    func book(_ path: String, _ format: BookFormat, fingerprint: String, modified: TimeInterval, imported: Bool = false) -> Book {
        Book(path: path, format: format, fingerprint: fingerprint, fileSize: 0, modifiedAt: Date(timeIntervalSince1970: modified),
             addedAt: Date(), title: "Changer le monde", authors: ["Jean-Marc Jancovici"], tags: [], hasCover: false,
             isDRMProtected: false, isImported: imported, asin: "A")
    }

    @Test func keepsOneFilePerFormat() {
        // Le cas réel : trois copies identiques de l'EPUB, deux AZW3 différents.
        let books = [
            book("/e/Jancovici/Changer le monde (449)/a.azw3", .azw3, fingerprint: "az1", modified: 100),
            book("/e/Jancovici/Changer le monde (449)/a.epub", .epub, fingerprint: "ep", modified: 100),
            book("/e/Jancovici/Climat (378)/Changer le monde (449)/b.epub", .epub, fingerprint: "ep", modified: 300),
            book("/e/Jancovici/Changer le monde (377)/a.azw3", .azw3, fingerprint: "az2", modified: 200),
            book("/e/Jancovici/Changer le monde (377)/a.epub", .epub, fingerprint: "ep", modified: 50),
        ]
        let hidden = BookGroups.duplicates(books)
        let kept = books.filter { !hidden.contains($0.id) }
        #expect(kept.count == 2)
        // AZW3 : le contenu le plus récent.
        #expect(kept.contains { $0.path == "/e/Jancovici/Changer le monde (377)/a.azw3" })
        // EPUB identiques : pas celui rangé dans le sous-dossier d'un autre livre, malgré sa date.
        let epub = kept.first { $0.format == .epub }!
        #expect(epub.path.split(separator: "/").count == 4)
        #expect(epub.path == "/e/Jancovici/Changer le monde (449)/a.epub")
    }

    @Test func prefersSourceOverImportAndKeepsSingleFiles() {
        let books = [
            book("/lib/Imports/x.epub", .epub, fingerprint: "same", modified: 100, imported: true),
            book("/lib/x.epub", .epub, fingerprint: "same", modified: 100),
            book("/lib/x.mobi", .mobi, fingerprint: "m", modified: 100),
        ]
        #expect(BookGroups.duplicates(books) == ["/lib/Imports/x.epub"])
        #expect(BookGroups.duplicates([books[2]]).isEmpty)
    }
}

@Suite struct AuthorTypoTests {
    func book(_ path: String, _ title: String, _ authors: [String], _ format: BookFormat) -> Book {
        Book(path: path, format: format, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
             title: title, authors: authors, tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
    }

    @Test func doubledLetterTypoDoesNotSplitBook() {
        // Cas réel : les deux formats d'un même livre, auteur écrit de deux façons.
        let books = [book("1", "Amérique notre histoire", ["Banks Russel"], .azw3),
                     book("2", "Amérique notre histoire", ["Russell Banks"], .epub)]
        #expect(BookGroups.make(books).map(\.books.count) == [2])
        #expect(AuthorNames.groups(books).count == 1)
        // Le catalogue continue de voir la différence (et propose la bonne graphie).
        #expect(Matching.personKey("Banks Russel") != Matching.personKey("Russell Banks"))
    }

    @Test func differentAuthorsStaySeparate() {
        let books = [book("1", "1984", ["George Orwell"], .epub), book("2", "1984", ["Autre Auteur"], .epub)]
        #expect(BookGroups.make(books).count == 2)
    }
}

@Suite struct BookIdentityTests {
    func book(_ path: String, _ title: String, _ authors: [String], _ format: BookFormat = .epub) -> Book {
        Book(path: path, format: format, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
             title: title, authors: authors, tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
    }

    func groupSizes(_ books: [Book]) -> [Int] {
        BookGroups.make(books, identities: BookGroups.identities(books)).map(\.books.count).sorted()
    }

    @Test func partialNamesAndMissingAuthorsJoin() {
        #expect(groupSizes([book("/a/1.epub", "L'archipel du Goulag", ["Soljénitsyne"]),
                            book("/b/2.azw3", "L'archipel du Goulag", ["Alexandre Soljénitsyne"], .azw3)]) == [2])
        #expect(groupSizes([book("/a/1.epub", "Chrono-minets", ["Asimov, Isaac (1920-1992)"]),
                            book("/b/2.azw3", "Chrono-minets", ["Asimov Isaac"], .azw3)]) == [2])
        #expect(groupSizes([book("/a/1.epub", "Cent ans de solitude", ["Inconnu(e)"]),
                            book("/b/2.azw3", "Cent ans de solitude", ["Gabriel Garcia Marquez"], .azw3)]) == [2])
        #expect(groupSizes([book("/a/1.epub", "La révolution Tesla", []),
                            book("/b/2.mobi", "La révolution Tesla", ["La révolution Tesla Comment Elon Musk (z-lib.org)"], .mobi)]) == [2])
    }

    @Test func calibreFolderJoinsDifferentAuthors() {
        // Même dossier de livre « Titre (40) » : un seul livre, auteur saisi différemment.
        #expect(groupSizes([book("/e/Tolkien/Dictionnaire Tolkien (40)/d.epub", "Dictionnaire Tolkien", ["Vincent Ferré"]),
                            book("/e/Tolkien/Dictionnaire Tolkien (40)/d.azw3", "Dictionnaire Tolkien", ["Tolkien J. R. R"], .azw3)]) == [2])
    }

    @Test func differentBooksWithSameTitleStaySeparate() {
        #expect(groupSizes([book("/e/Gary/a.epub", "Les enchanteurs", ["Romain Gary"]),
                            book("/e/Ellroy/b.epub", "Les Enchanteurs", ["James Ellroy"])]) == [1, 1])
        // Dossier thématique (pas un dossier de livre) : trois livres distincts.
        #expect(groupSizes([book("/e/_thema/Poutine/a.epub", "Poutine", ["Nina Bachkatov"]),
                            book("/e/_thema/Poutine/b.epub", "Poutine", ["Gessen"]),
                            book("/e/_thema/Poutine/c.epub", "Poutine", ["Frédéric Pons"])]) == [1, 1, 1])
        // Auteur manquant mais plusieurs auteurs connus : impossible de choisir, il reste à part.
        #expect(groupSizes([book("/e/x/a.epub", "Poutine", ["Unknown"]),
                            book("/e/y/b.epub", "Poutine", ["Gessen"]),
                            book("/e/z/c.epub", "Poutine", ["Frédéric Pons"])]) == [1, 1, 1])
    }
}

@Suite struct GenreNamesTests {
    func book(_ path: String, _ title: String, genre: String?) -> Book {
        var b = Book(path: path, format: .epub, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
                     title: title, authors: ["Auteur"], tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
        b.genre = genre
        return b
    }

    @Test func groupsGenresAndCountsBooks() {
        let books = [book("/a.epub", "A", genre: "Roman"), book("/a.azw3", "A", genre: "Roman"),
                     book("/b.epub", "B", genre: "roman "), book("/c.epub", "C", genre: "Essai"),
                     book("/d.epub", "D", genre: nil)]
        let groups = GenreNames.groups(books)
        #expect(groups.map(\.name) == ["Essai", "Roman"])
        // Deux fichiers du même livre comptent pour un livre.
        #expect(groups.first { $0.name == "Roman" }?.bookCount == 2)
    }
}

@Suite struct TagNamesTests {
    func book(_ path: String, _ title: String, tags: [String]?, subjects: [String] = []) -> Book {
        var b = Book(path: path, format: .epub, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
                     title: title, authors: ["Auteur"], tags: subjects, hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
        b.userTags = tags
        return b
    }

    @Test func groupsUserTagsOnly() {
        let books = [book("/a.epub", "A", tags: ["À lire", "Été"]), book("/a.azw3", "A", tags: ["à lire"]),
                     book("/b.epub", "B", tags: ["À lire"], subjects: ["FICTION / General"]),
                     book("/c.epub", "C", tags: nil, subjects: ["Roman"])]
        let groups = TagNames.groups(books)
        // Les sujets des fichiers ne deviennent pas des étiquettes.
        #expect(groups.map(\.name) == ["À lire", "Été"])
        // Graphie la plus fréquente ; deux fichiers du même livre comptent pour un livre.
        #expect(groups.first?.bookCount == 2)
        #expect(TagNames.has(books[2], key: TagNames.key("À LIRE")))
    }

    @Test func cleanDropsEmptyAndDuplicates() {
        #expect(TagNames.clean([" Été ", "", "ete", "  ", "Plage", "#"]) == ["Été", "Plage"])
    }
}

