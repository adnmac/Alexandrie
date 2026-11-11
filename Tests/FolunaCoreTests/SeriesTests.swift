import Foundation
import Testing
@testable import FolunaCore

@Suite struct SeriesTests {
    @Test func splitsNameAndNumber() {
        #expect(SeriesNames.split("Commissaire Brunetti #32") == ("Commissaire Brunetti", 32))
        #expect(SeriesNames.split("Brunetti 8") == ("Brunetti", 8))
        #expect(SeriesNames.split("Asimov Nouvelles") == ("Asimov Nouvelles", nil))
        #expect(SeriesNames.split("Coll, Présence du Futur n°125") == ("Coll, Présence du Futur", 125))
        #expect(SeriesNames.split("1Q84") == ("1Q84", nil))
        #expect(SeriesNames.normalized("Brunetti 16", nil) == ("Brunetti", 16))
        #expect(SeriesNames.normalized("Brunetti 16", 3) == ("Brunetti", 3))
    }

    @Test func mergesVariants() {
        #expect(SeriesNames.key("Commissaire Brunetti") == SeriesNames.key("Brunetti"))
        #expect(SeriesNames.key("Les enquêtes du commissaire Brunetti #4") == "brunetti")
        #expect(SeriesNames.key("Elijah Baley") != SeriesNames.key("Brunetti"))
    }

    @Test func detectsSeriesInTitle() {
        let a = SeriesNames.hint(title: "Brunetti - 24 - Brunetti en trois actes", currentSeries: nil)
        #expect(a == .init(series: "Brunetti", index: 24, title: "Brunetti en trois actes"))
        // Numéro seul en tête : retenu seulement si la série est déjà connue.
        #expect(SeriesNames.hint(title: "08 - L'affaire Paola", currentSeries: nil) == nil)
        #expect(SeriesNames.hint(title: "08 - L'affaire Paola", currentSeries: "Brunetti")?.index == 8)
        let t = SeriesNames.hint(title: "Le Seigneur des anneaux tome III - Le Retour du roi", currentSeries: nil)
        #expect(t?.series == "Le Seigneur des anneaux" && t?.index == 3 && t?.title == "Le Retour du roi")
        #expect(SeriesNames.hint(title: "1984", currentSeries: nil) == nil)
        #expect(SeriesNames.hint(title: "2022 - Jamais frères Ukraine et Russie", currentSeries: nil) == nil)
    }

    @Test func epubKeepsSeries() throws {
        var meta = BookMetadata(title: "L'affaire Paola", authors: ["Donna Leon"])
        meta.series = "Brunetti"
        meta.seriesIndex = 8
        var b = EPUBBuilder(metadata: meta)
        b.add("t.xhtml", mediaType: "application/xhtml+xml",
              data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>x</title></head><body><p>x</p></body></html>".utf8),
              inSpine: true)
        let url = temp("epub")
        try b.write(to: url)
        let read = try EPUBReader(url: url).bookMetadata()
        #expect(read.series == "Brunetti" && read.seriesIndex == 8)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLUNA_LIBRARY_INDEX"] != nil))
    func realLibrarySeries() throws {
        var books = try LibraryIndex.load(URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLUNA_LIBRARY_INDEX"]!))
        for i in books.indices { (books[i].series, books[i].seriesIndex) = SeriesNames.normalized(books[i].series, books[i].seriesIndex) }
        let groups = SeriesNames.groups(books)
        print("📚 \(groups.count) séries ; \(books.filter { $0.seriesHint != nil }.count) fichiers avec une proposition tirée du titre")
        for g in groups.filter({ $0.variants.count > 1 }).prefix(5) { print("   \(g.name) ← \(g.variants.joined(separator: " | "))") }
        for b in books.filter({ $0.authors.joined().lowercased().contains("leon") }).prefix(6) {
            print("   \(b.title.prefix(48)) | \(b.series ?? "-") \(b.seriesIndex.map(SeriesNames.format) ?? "") → \(b.seriesHint.map { "\($0.series ?? b.series ?? "?") n° \(SeriesNames.format($0.index))" } ?? "ok")")
        }
    }
}
