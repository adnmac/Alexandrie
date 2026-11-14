import Foundation
import Testing
@testable import FolunaCore

/// Le tri par rangs donne le même ordre que le tri direct (`localizedStandardCompare`).
@Suite struct SortRanksTests {
    static func direct(_ list: [Book], _ key: (Book) -> String) -> [String] {
        list.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }.map { key($0) }
    }

    @Test func sameOrderAsDirectSort() {
        let books = StressTests.library(6000)
        let ranks = SortRanks(books)
        let titles = SortRanks.ordered(books, ranks: ranks.title, key: \.title).map(\.title)
        #expect(titles == Self.direct(books, \.title))
        let authors = SortRanks.ordered(books, ranks: ranks.author, key: \.authorLine).map(\.authorLine)
        #expect(authors == Self.direct(books, \.authorLine))
        // Une page (sous-ensemble) garde l'ordre.
        let page = books.filter { $0.format == .epub }
        #expect(SortRanks.ordered(page, ranks: ranks.title, key: \.title).map(\.title) == Self.direct(page, \.title))
    }

    @Test func booksAddedSinceLastRankingFindTheirPlace() {
        let books = StressTests.library(6000)
        let ranks = SortRanks(Array(books.dropLast(300)))  // 300 livres arrivés après le calcul
        let titles = SortRanks.ordered(books, ranks: ranks.title, key: \.title).map(\.title)
        #expect(titles == Self.direct(books, \.title))
        #expect(titles.count == books.count)
    }

    @Test func smallListsAreSortedDirectly() {
        let books = StressTests.library(500)
        #expect(SortRanks.ordered(books, ranks: [:], key: \.title).map(\.title) == Self.direct(books, \.title))
    }
}
