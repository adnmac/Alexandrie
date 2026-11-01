import Foundation

/// Validation et normalisation des ISBN (10 et 13 chiffres).
public enum ISBN {
    /// Chiffres seuls (et « X » final d'un ISBN-10), sans préfixe ni tirets.
    static func digits(_ s: String) -> String {
        var t = s.uppercased()
        for prefix in ["URN:ISBN:", "ISBN-13", "ISBN-10", "ISBN", "EAN"] {
            t = t.replacingOccurrences(of: prefix, with: "")
        }
        return String(t.filter { $0.isNumber || $0 == "X" })
    }

    public static func isValid(_ s: String) -> Bool {
        let d = digits(s)
        return (d.count == 13 && valid13(d)) || (d.count == 10 && valid10(d))
    }

    private static func valid13(_ d: String) -> Bool {
        guard d.hasPrefix("978") || d.hasPrefix("979"), d.allSatisfy(\.isNumber) else { return false }
        let n = d.compactMap(\.wholeNumberValue)
        let sum = n.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return sum % 10 == 0
    }

    private static func valid10(_ d: String) -> Bool {
        let chars = Array(d)
        guard chars.dropLast().allSatisfy(\.isNumber), chars.last!.isNumber || chars.last == "X" else { return false }
        let sum = chars.enumerated().reduce(0) { acc, e in
            acc + (10 - e.offset) * (e.element == "X" ? 10 : e.element.wholeNumberValue!)
        }
        return sum % 11 == 0
    }

    /// Forme canonique ISBN-13 ; nil si invalide.
    public static func normalized(_ s: String) -> String? {
        let d = digits(s)
        if d.count == 13 && valid13(d) { return d }
        if d.count == 10 && valid10(d) { return to13(d) }
        return nil
    }

    static func to13(_ isbn10: String) -> String {
        let core = "978" + isbn10.prefix(9)
        let n = core.compactMap(\.wholeNumberValue)
        let sum = n.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return core + String((10 - sum % 10) % 10)
    }

    /// ISBN-10 équivalent (seulement pour le préfixe 978) : la BnF indexe les éditions anciennes ainsi.
    static func to10(_ isbn13: String) -> String? {
        guard isbn13.count == 13, isbn13.hasPrefix("978") else { return nil }
        let core = Array(isbn13.dropFirst(3).prefix(9))
        let sum = core.enumerated().reduce(0) { $0 + (10 - $1.offset) * $1.element.wholeNumberValue! }
        let check = (11 - sum % 11) % 11
        return String(core) + (check == 10 ? "X" : String(check))
    }

    /// Premier ISBN valide trouvé dans une liste d'identifiants (dc:identifier, EXTH 104…).
    public static func first(in candidates: [String]) -> String? {
        for c in candidates {
            if let n = normalized(c) { return n }
            // Identifiants composites : « urn:isbn:978-2-… », « ISBN 978… (br.) ».
            for token in c.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "," }) {
                if let n = normalized(String(token)) { return n }
            }
        }
        return nil
    }

    /// Présentation lisible (pas de découpage par groupe : il dépend de l'éditeur).
    public static func display(_ s: String) -> String { normalized(s) ?? s }
}
