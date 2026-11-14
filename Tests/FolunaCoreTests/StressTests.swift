import Foundation
import Testing
@testable import FolunaCore

/// Bancs d'essai du cœur sur de grosses bibliothèques en mémoire, activés par `FOLUNA_STRESS=1`.
/// Paliers : `FOLUNA_STRESS_SIZES` (par défaut 1000,10000,50000,100000). Chaque mesure écrit une ligne
/// `STRESS <mesure> n=<n> <ms> ms` ; les limites sont larges : elles attrapent un effondrement, pas une lenteur.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FOLUNA_STRESS"] == "1"))
struct StressTests {
    static let sizes: [Int] = (ProcessInfo.processInfo.environment["FOLUNA_STRESS_SIZES"] ?? "1000,10000,50000,100000")
        .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

    /// Bibliothèque inventée : 5 % de copies en double (même livre, même format), 5 % du même livre
    /// en AZW3, 2 % de PDF.
    static func library(_ n: Int, root: String = "/tmp/foluna-stress-mem") -> [Book] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<n).map { i in
            let copy = i % 20 == 19 || i % 20 == 9
            let e = StressCatalog.entry(copy ? i - 1 : i)
            let format: BookFormat = i % 20 == 9 ? .azw3 : (i % 50 == 13 ? .pdf : .epub)
            var b = Book(path: "\(root)/\(i % 37)/\(i % 11)/livre-\(i).\(format.rawValue)", format: format,
                         fingerprint: "fp\(i)", fileSize: Int64(20_000 + i % 5_000),
                         modifiedAt: base, addedAt: base.addingTimeInterval(Double(i) * 60),
                         title: e.title, authors: e.authors, language: e.language, publisher: e.publisher,
                         summary: e.summary, series: e.series, seriesIndex: e.seriesIndex, tags: e.subjects,
                         hasCover: i % 3 == 0, isDRMProtected: false, isImported: false, asin: "B\(i)",
                         metadataVersion: Book.currentMetadataVersion)
            b.userTags = e.userTags.isEmpty ? nil : e.userTags
            return b
        }
    }

    @discardableResult
    static func measure<T>(_ name: String, n: Int, _ body: () throws -> T) rethrows -> (T, Duration) {
        let clock = ContinuousClock()
        var result: T?
        let elapsed = try clock.measure { result = try body() }
        print("STRESS \(name) n=\(n) \(ms(elapsed)) ms")
        return (result!, elapsed)
    }

    static func ms(_ d: Duration) -> String {
        String(format: "%.1f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    /// Limite proportionnelle au palier : `perThousand` par tranche de 1 000 livres, 1 s au minimum.
    static func limit(_ n: Int, perThousand: Double) -> Duration {
        .milliseconds(max(1000, Int(Double(n) / 1000 * perThousand)))
    }

    @Test(arguments: sizes) func index(_ n: Int) throws {
        let books = Self.library(n)
        let url = tempDirectory().appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, save) = try Self.measure("index.save", n: n) { try LibraryIndex.save(books, to: url) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("STRESS index.size n=\(n) \(size / 1024) Ko")
        let (loaded, load) = try Self.measure("index.load", n: n) { try LibraryIndex.load(url) }
        #expect(loaded == books)
        #expect(save < Self.limit(n, perThousand: 100))
        #expect(load < Self.limit(n, perThousand: 100))
    }

    @Test(arguments: sizes) func grouping(_ n: Int) {
        let books = Self.library(n)
        let (ids, identities) = Self.measure("groups.identities", n: n) { BookGroups.identities(books) }
        let (groups, make) = Self.measure("groups.make", n: n) { BookGroups.make(books, identities: ids) }
        let (dups, duplicates) = Self.measure("groups.duplicates", n: n) { BookGroups.duplicates(books, identities: ids) }
        Self.measure("groups.primary", n: n) { groups.map(\.primary.id).count }
        // Un fichier sur 10 est une autre copie du précédent (même format ou AZW3).
        #expect(groups.count <= n - n / 12)
        #expect(dups.count >= n / 25)
        #expect(identities < Self.limit(n, perThousand: 200))
        #expect(make < Self.limit(n, perThousand: 50))
        #expect(duplicates < Self.limit(n, perThousand: 50))
    }

    @Test(arguments: sizes) func sidebarLists(_ n: Int) {
        let books = Self.library(n)
        let ids = BookGroups.identities(books)
        let (_, tags) = Self.measure("sidebar.tags", n: n) { TagNames.groups(books, identities: ids) }
        let (_, authors) = Self.measure("sidebar.authors", n: n) { AuthorNames.groups(books) }
        let (_, series) = Self.measure("sidebar.series", n: n) { SeriesNames.groups(books) }
        let (_, genres) = Self.measure("sidebar.genres", n: n) { GenreNames.groups(books, identities: ids) }
        Self.measure("sidebar.suggestions", n: n) { books.filter { !$0.catalogSuggestions.isEmpty }.count }
        for d in [tags, authors, series, genres] { #expect(d < Self.limit(n, perThousand: 100)) }
    }

    /// Même filtre et même tri que `ContentView.filteredBooks` (recherche dans les titres).
    @Test(arguments: sizes) func searchAndSort(_ n: Int) {
        let books = Self.library(n)
        let query = "jardin"
        let (hits, search) = Self.measure("search.titles", n: n) {
            books.filter { b in
                [b.title, b.authorLine, b.series ?? "", b.genre ?? "", b.labels.joined(separator: " "), b.tags.joined(separator: " ")]
                    .contains { $0.localizedStandardContains(query) }
            }
        }
        #expect(!hits.isEmpty)
        let (_, byTitle) = Self.measure("sort.title", n: n) {
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        Self.measure("sort.author", n: n) {
            books.sorted { $0.authorLine.localizedStandardCompare($1.authorLine) == .orderedAscending }
        }
        #expect(search < Self.limit(n, perThousand: 100))
        #expect(byTitle < Self.limit(n, perThousand: 200))
    }

    /// Rapprochement disque / index sur de vrais petits fichiers : tous connus, puis tous déplacés.
    @Test(arguments: sizes) func merge(_ n: Int) throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<n {
            let sub = dir.appendingPathComponent("\(i % 37)/\(i % 11)", isDirectory: true)
            if i < 37 * 11 { try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true) }
            try Data("livre \(i)".utf8).write(to: sub.appendingPathComponent("livre-\(i).epub"))
        }
        let (files, scan) = Self.measure("merge.scan", n: n) { FolderScanner.scan([dir]) }
        #expect(files.count == n)
        let known = files.map { f in
            Book(path: f.url.path, format: .epub, fingerprint: FolderScanner.fingerprint(f.url, size: f.size),
                 fileSize: f.size, modifiedAt: f.modifiedAt, addedAt: f.addedAt, title: f.url.lastPathComponent,
                 authors: [], tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A",
                 metadataVersion: Book.currentMetadataVersion)
        }
        let (unchanged, plan) = Self.measure("merge.plan.unchanged", n: n) {
            LibraryMerge.plan(files: files, known: known, importsPath: "/nulle-part")
        }
        #expect(unchanged.kept.count == n && unchanged.changed.isEmpty)
        // Dossier renommé : chaque fichier est retrouvé par son empreinte (lecture de 64 Ko au plus).
        let moved = known.map { b -> Book in var b = b; b.path = "/ancien" + b.path; return b }
        let (relocated, planMoved) = Self.measure("merge.plan.moved", n: n) {
            LibraryMerge.plan(files: files, known: moved, importsPath: "/nulle-part")
        }
        #expect(relocated.kept.count == n)
        #expect(scan < Self.limit(n, perThousand: 200))
        #expect(plan < Self.limit(n, perThousand: 50))
        #expect(planMoved < Self.limit(n, perThousand: 500))
    }

    @Test(arguments: sizes) func tagEdits(_ n: Int) {
        var books = Self.library(n)
        // Comme `LibraryStore.changeTags` sur toute la bibliothèque (renommer une étiquette).
        Self.measure("tags.rename", n: n) {
            for i in books.indices where TagNames.has(books[i], key: TagNames.key("À lire")) {
                books[i].userTags = TagNames.clean(books[i].labels.map { TagNames.key($0) == TagNames.key("À lire") ? "Pile" : $0 })
            }
        }
        // Comme `LibraryStore.undoable` : copie et comparaison complètes.
        let before = books
        Self.measure("undo.compare", n: n) { zip(before, books).filter { $0 != $1 }.count }
    }

    /// Beaucoup de livres au même titre, d'auteurs différents : `identities` compare les groupes deux à deux.
    @Test(arguments: [100, 200, 400]) func sameTitle(_ k: Int) {
        let base = Self.library(k)
        let books = base.map { b -> Book in var b = b; b.title = StressCatalog.sharedTitle; return b }
        let (_, d) = Self.measure("groups.identities.sameTitle", n: k) { BookGroups.identities(books) }
        // Quelques centaines de « Sans titre » ou de « Mémoires » ne doivent pas figer la bibliothèque.
        #expect(d < .seconds(2))
    }
}
