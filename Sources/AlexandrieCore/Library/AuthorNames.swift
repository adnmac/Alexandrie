import Foundation

/// Regroupement des graphies d'un même auteur (« Murakami,Haruki » = « Haruki Murakami »).
public enum AuthorNames {
    public struct Group: Identifiable, Hashable, Sendable {
        public var id: String { key }
        public let key: String
        /// Forme affichée : la plus lisible des variantes rencontrées.
        public let name: String
        public let variants: [String]
        public let bookCount: Int
    }

    /// Clé indépendante de la casse, des accents, de la ponctuation et de l'ordre prénom/nom.
    public static func key(_ name: String) -> String {
        Matching.personKey(name)
    }

    /// Sépare un champ qui cite plusieurs personnes : « A B & C D », « Edwy Plenel, Lisa Fittko ».
    /// « Nom, Prénom » (un seul mot de part et d'autre de la virgule) reste une seule personne.
    public static func individuals(_ author: String) -> [String] {
        author.components(separatedBy: " & ").flatMap { part -> [String] in
            let pieces = part.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
            let allFullNames = pieces.count > 1 && pieces.allSatisfy { $0.split(separator: " ").count >= 2 }
            return allFullNames ? pieces : [part.trimmingCharacters(in: .whitespaces)]
        }.filter { !$0.isEmpty }
    }

    /// Clés des auteurs d'un livre (pour filtrer par auteur).
    public static func keys(of book: Book) -> Set<String> {
        Set(book.authors.flatMap(individuals).map(key))
    }

    public static func groups(_ books: [Book]) -> [Group] {
        var variantCounts: [String: [String: Int]] = [:]
        var bookCounts: [String: Int] = [:]
        for book in books {
            var seen = Set<String>()
            for author in book.authors.flatMap(individuals) {
                let k = key(author)
                guard !k.isEmpty else { continue }
                variantCounts[k, default: [:]][author, default: 0] += 1
                if seen.insert(k).inserted { bookCounts[k, default: 0] += 1 }
            }
        }
        return variantCounts.map { k, variants in
            Group(key: k, name: displayName(variants), variants: variants.keys.sorted(), bookCount: bookCounts[k] ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Une graphie « Nom, Prénom » indique le nom de famille sans ambiguïté : elle est retenue (et remise
    /// dans l'ordre « Prénom Nom »). Sinon : sans parenthèses ni MAJUSCULES, puis la plus fréquente.
    static func displayName(_ variants: [String: Int]) -> String {
        let withComma = variants.keys.filter { $0.contains(",") }
        let pool = withComma.isEmpty ? Array(variants.keys) : withComma
        func score(_ v: String) -> (Int, Int) {
            var s = 0
            if !v.contains("(") { s += 2 }
            let words = v.split(whereSeparator: { $0 == " " || $0 == "," })
            if !words.contains(where: { $0.count > 1 && $0 == $0.uppercased() && $0.contains(where: \.isLetter) }) { s += 1 }
            if !v.contains(",") || v.contains(", ") { s += 1 }
            return (s, variants[v] ?? 0)
        }
        let best = pool.max { a, b in
            let (sa, ca) = score(a), (sb, cb) = score(b)
            return sa != sb ? sa < sb : (ca != cb ? ca < cb : a > b)
        } ?? ""
        return readable(best)
    }

    /// « Murakami,Haruki » → « Haruki Murakami » ; « HARARI » → « Harari ».
    static func readable(_ name: String) -> String {
        var n = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let parts = n.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].contains(" ") || !parts[0].contains(" ") {
            n = parts[1] + " " + parts[0]
        }
        return n.split(separator: " ").map { word -> String in
            let w = String(word)
            guard w.count > 1, w == w.uppercased(), w.contains(where: \.isLetter) else { return w }
            return w.lowercased().split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }
}
