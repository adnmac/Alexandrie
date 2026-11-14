import Foundation
import Testing
@testable import FolunaCore

/// `BookGroups.components` (union-find) réunit les mêmes fichiers que l'ancienne fusion de proche en proche.
@Suite struct BookComponentsTests {
    /// Ancien algorithme : fusionner deux groupes liés, recommencer jusqu'à ce qu'aucun ne le soit.
    static func reference(_ files: [Book], title: String) -> [[Book]] {
        var clusters = Dictionary(grouping: files, by: BookGroups.key).map(\.value)
        var merged = true
        while merged {
            merged = false
            search: for i in clusters.indices {
                for j in clusters.indices where j > i && BookGroups.related(clusters[i], clusters[j], title: title) {
                    clusters[i] += clusters[j]
                    clusters.remove(at: j)
                    merged = true
                    break search
                }
            }
        }
        return clusters
    }

    static func partition(_ clusters: [[Book]]) -> Set<Set<String>> { Set(clusters.map { Set($0.map(\.id)) }) }

    func book(_ path: String, _ authors: [String], title: String = "Mémoires") -> Book {
        Book(path: path, format: .epub, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
             title: title, authors: authors, tags: [], hasCover: false, isDRMProtected: false, isImported: false, asin: "A")
    }

    @Test func sameGroupsAsReference() {
        let files = [
            book("/a/1.epub", ["Soljénitsyne"]), book("/a/2.epub", ["Alexandre Soljénitsyne"]),
            book("/a/3.epub", ["Alexandre Soljénitsyne", "Natalia Soljénitsyne"]),
            book("/b/4.epub", ["Saint-Simon"]), book("/b/5.epub", ["Louis de Rouvroy, duc de Saint-Simon"]),
            book("/c/Mémoires (12)/6.epub", ["Chateaubriand"]), book("/c/Mémoires (12)/7.pdf", ["Unknown"]),
            book("/d/8.epub", ["Gary"]), book("/d/9.epub", ["Ellroy"]), book("/d/10.epub", []),
            book("/e/11.epub", ["Mémoires"]), book("/f/12.epub", ["Simone de Beauvoir"]),
        ]
        let title = BookGroups.titleKey("Mémoires")
        #expect(Self.partition(BookGroups.components(files, title: title)) == Self.partition(Self.reference(files, title: title)))
        #expect(BookGroups.identities(files)["/a/1.epub"] == BookGroups.identities(files)["/a/3.epub"])
    }

    @Test func randomTitleGroups() {
        var r = SplitMix64(seed: 7)
        let words = ["Gary", "Romain", "Ellroy", "James", "Duras", "Marguerite", "Sand", "George", "de", "Saint"]
        for round in 0..<30 {
            let files = (0..<(10 + round)).map { i -> Book in
                let count = Int(r.next() % 3)
                let authors = (0..<count).map { _ in (0..<(1 + Int(r.next() % 2))).map { _ in r.pick(words) }.joined(separator: " ") }
                let folder = r.next() % 4 == 0 ? "Mémoires (\(r.next() % 3))" : "dossier\(i)"
                return book("/x/\(folder)/\(i).epub", authors)
            }
            let title = BookGroups.titleKey("Mémoires")
            #expect(Self.partition(BookGroups.components(files, title: title)) == Self.partition(Self.reference(files, title: title)))
        }
    }
}
