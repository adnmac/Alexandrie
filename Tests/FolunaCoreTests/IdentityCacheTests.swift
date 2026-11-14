import Foundation
import Testing
@testable import FolunaCore

/// Le cache titre par titre donne toujours les mêmes identités que le calcul complet.
@Suite struct IdentityCacheTests {
    func book(_ path: String, _ title: String, _ authors: [String]) -> Book {
        Book(path: path, format: .epub, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
             title: title, authors: authors, tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
    }

    var library: [Book] {
        [book("/a/Candide.epub", "Candide", ["Voltaire"]), book("/a/Candide.azw3", "Candide", ["François-Marie Arouet Voltaire"]),
         book("/b/Candide.epub", "Candide", []), book("/c/Zadig.epub", "Zadig", ["Voltaire"]),
         book("/d/Les Enchanteurs.epub", "Les Enchanteurs", ["Romain Gary"]),
         book("/e/Les Enchanteurs.epub", "Les Enchanteurs", ["James Ellroy"]),
         book("/f/Mémoires (12)/Mémoires.epub", "Mémoires", ["Unknown"]),
         book("/f/Mémoires (12)/Mémoires.pdf", "Mémoires", ["Saint-Simon"])]
    }

    @Test func matchesFullComputationAfterEachChange() {
        var books = library
        var cache = IdentityCache()
        #expect(cache.update(books) == BookGroups.identities(books))
        let changes: [(inout [Book]) -> Void] = [
            { $0[0].userTags = ["À lire"] },                       // aucun titre touché
            { $0[3].title = "Candide" },                            // Zadig rejoint Candide
            { $0[5].authors = ["Romain Gary"] },                    // les deux Enchanteurs se rejoignent
            { $0[2].authors = ["Voltaire"] },
            { $0.remove(at: 1) },                                    // fichier disparu
            { $0.append(self.book("/g/Zadig.epub", "Zadig", ["Voltaire"])) },
            { $0[0].path = "/h/Candide.epub" },                     // fichier déplacé
            { $0[6].title = "Mémoires : roman" },                   // même clé de titre
        ]
        for change in changes {
            change(&books)
            #expect(cache.update(books) == BookGroups.identities(books))
        }
    }

    @Test func randomEditsOnLargeLibrary() {
        var books = StressTests.library(3000)
        var cache = IdentityCache()
        cache.update(books)
        var r = SplitMix64(seed: 42)
        for _ in 0..<40 {
            let i = Int(r.next() % UInt64(books.count))
            switch r.next() % 4 {
            case 0: books[i].title = StressCatalog.entry(Int(r.next() % 3000)).title
            case 1: books[i].authors = StressCatalog.entry(Int(r.next() % 3000)).authors
            case 2: books[i].userTags = ["Pile"]
            default: books.remove(at: i)
            }
            #expect(cache.update(books) == BookGroups.identities(books))
        }
    }
}
