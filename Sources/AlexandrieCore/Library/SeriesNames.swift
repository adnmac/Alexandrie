import Foundation

/// Séries : séparation nom/numéro, regroupement des variantes, détection dans le titre.
public enum SeriesNames {
    public struct Group: Identifiable, Hashable, Sendable {
        public var id: String { key }
        public let key: String
        public let name: String
        public let variants: [String]
        public let bookCount: Int
    }

    /// Mots qui précisent une série sans la distinguer (« Commissaire Brunetti » = « Brunetti »).
    static let genericWords: Set<String> = [
        "commissaire", "inspecteur", "inspectrice", "capitaine", "detective", "enquete", "enquetes", "enquête", "enquêtes",
        "les", "le", "la", "l", "de", "du", "des", "d", "une", "un", "the", "of", "a", "saga", "serie", "série", "cycle",
        "tome", "tomes", "volume", "vol", "n", "no",
    ]

    /// Clé de regroupement d'un nom de série.
    public static func key(_ series: String) -> String {
        let words = Matching.key(split(series).name).split(separator: " ").map(String.init)
        let significant = words.filter { !genericWords.contains($0) }
        return (significant.isEmpty ? words : significant).joined(separator: " ")
    }

    /// « Commissaire Brunetti #32 » → (« Commissaire Brunetti », 32) ; « Brunetti 8 » → (« Brunetti », 8).
    public static func split(_ series: String) -> (name: String, index: Double?) {
        let s = series.trimmingCharacters(in: .whitespaces)
        let pattern = try! NSRegularExpression(pattern: "^(.*?\\S)(?:[\\s,]*(?:#|n°|no\\.|tome|t\\.|vol\\.?)\\s*|[\\s,]+)(\\d+(?:[.,]\\d+)?)$",
                                               options: .caseInsensitive)
        guard let g = pattern.firstGroups(in: s), let n = Double(g[2].replacingOccurrences(of: ",", with: ".")),
              n < 1000 else { return (s, nil) }
        return (g[1], n)
    }

    /// Nom et numéro rangés (le numéro collé au nom est séparé si le numéro manque).
    public static func normalized(_ series: String?, _ index: Double?) -> (String?, Double?) {
        guard let series, !series.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, index) }
        let (name, n) = split(series)
        if let n, index == nil { return (name, n) }
        return (index == nil ? series : name, index)
    }

    public static func groups(_ books: [Book]) -> [Group] {
        var variants: [String: [String: Int]] = [:]
        // Livres distincts (les fichiers d'un même livre en plusieurs formats comptent une fois).
        var titles: [String: Set<String>] = [:]
        for b in books {
            guard let s = b.series, !s.isEmpty else { continue }
            let name = split(s).name
            variants[key(name), default: [:]][name, default: 0] += 1
            titles[key(name), default: []].insert(BookGroups.key(b))
        }
        return variants.map { k, v in
            // Forme la plus fréquente ; à égalité, la plus courte (« Brunetti » plutôt que « Commissaire Brunetti »).
            let name = v.max { a, b in a.value != b.value ? a.value < b.value : a.key.count > b.key.count }!.key
            return Group(key: k, name: name, variants: v.keys.sorted(), bookCount: titles[k]?.count ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Détection dans le titre

    public struct TitleHint: Equatable, Sendable {
        public let series: String?
        public let index: Double
        /// Titre sans la mention de série (« Brunetti en trois actes »).
        public let title: String
    }

    private static let seriesNumberTitle = try! NSRegularExpression(
        pattern: "^\\s*(.+?)\\s*[-–—:]\\s*(?:t(?:ome)?\\.?\\s*)?(\\d{1,3})\\s*[-–—:]\\s*(.+)$", options: .caseInsensitive)
    private static let numberTitle = try! NSRegularExpression(pattern: "^\\s*(\\d{1,3})\\s*[-–—.]\\s*(.+)$")
    private static let titleTome = try! NSRegularExpression(
        pattern: "^(.+?)[\\s,-]+(?:tome|t\\.|vol\\.?|volume)\\s*(\\d{1,3}|[ivxlc]+)\\b\\s*[-–—:]?\\s*(.*)$", options: .caseInsensitive)

    /// Série et numéro lisibles dans le titre :
    /// « Brunetti - 24 - Brunetti en trois actes », « 08 - L'affaire Paola » (série déjà connue),
    /// « Le Seigneur des anneaux tome III - Le Retour du roi ».
    public static func hint(title: String, currentSeries: String?) -> TitleHint? {
        if let g = seriesNumberTitle.firstGroups(in: title), let n = Double(g[2]), !g[1].allSatisfy(\.isNumber) {
            return TitleHint(series: g[1], index: n, title: g[3])
        }
        if let g = numberTitle.firstGroups(in: title), let n = Double(g[1]), currentSeries != nil {
            return TitleHint(series: nil, index: n, title: g[2])
        }
        if let g = titleTome.firstGroups(in: title), let n = Double(g[2]) ?? roman(g[2]) {
            let rest = g[3].trimmingCharacters(in: .whitespaces)
            return TitleHint(series: g[1].trimmingCharacters(in: .whitespaces), index: n, title: rest.isEmpty ? title : rest)
        }
        return nil
    }

    static func roman(_ s: String) -> Double? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        let digits = s.lowercased().compactMap { values[$0] }
        guard digits.count == s.count, !digits.isEmpty else { return nil }
        var total = 0
        for (i, v) in digits.enumerated() {
            total += i + 1 < digits.count && v < digits[i + 1] ? -v : v
        }
        return Double(total)
    }

    /// Numéro affichable : « 8 », « 2.5 ».
    public static func format(_ index: Double) -> String {
        index == index.rounded() ? String(Int(index)) : String(index)
    }
}
