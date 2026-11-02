import Foundation
import Vision

/// Texte lu sur la couverture par la reconnaissance de texte de macOS (sur l'appareil, rien n'est envoyé).
public struct CoverText: Equatable, Sendable {
    public var lines: [String]

    public init(lines: [String]) { self.lines = lines }

    public static func recognize(imageAt url: URL) throws -> CoverText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(url: url).perform([request])
        return CoverText(lines: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
    }

    /// Mots de la couverture, casse, accents et ponctuation ignorés, ordre de lecture conservé.
    var key: String { " " + Matching.key(lines.joined(separator: " ")) + " " }

    /// La valeur figure-t-elle sur la couverture, en mots entiers ?
    public func contains(_ value: String) -> Bool {
        let k = Matching.key(value)
        return !k.isEmpty && key.contains(" \(k) ")
    }
}

/// Ce que dit la couverture d'une proposition du catalogue.
public enum CoverVerdict: Equatable, Sendable {
    /// La valeur proposée est écrite sur la couverture.
    case confirmed
    /// La couverture porte une autre valeur : celle-ci si elle a pu être lue (un éditeur), sinon la valeur actuelle.
    case contradicted(String?)
}

public enum CoverCheck {
    /// Éditeurs courants, complétés par ceux déjà présents dans la bibliothèque.
    public static let knownPublishers = [
        "Seuil", "Points", "Gallimard", "Folio", "Albin Michel", "Grasset", "Flammarion", "Actes Sud", "Babel",
        "Calmann-Lévy", "Robert Laffont", "Stock", "Fayard", "Plon", "Julliard", "Denoël", "Belfond", "JC Lattès",
        "Le Livre de Poche", "Pocket", "J'ai lu", "10/18", "Presses de la Cité", "Mercure de France", "Minuit",
        "P.O.L", "L'Olivier", "Rivages", "Zulma", "Métailié", "Liana Levi", "Philippe Rey", "Sabine Wespieser",
        "La Découverte", "Payot", "Tallandier", "Perrin", "Odile Jacob", "Les Arènes", "Michel Lafon", "XO",
        "L'Iconoclaste", "Allary", "Héloïse d'Ormesson", "Christian Bourgois", "Bragelonne", "Milady", "Hachette",
        "Belles Lettres", "Eyrolles", "Dunod", "Casterman", "Dargaud", "Dupuis", "Glénat", "Delcourt",
    ]

    /// « Éditions Points », « Éd. Points », « Le Seuil » → « points », « seuil » : le nom tel qu'il figure sur une couverture.
    static func publisherCore(_ name: String) -> String {
        var words = Matching.key(name).split(separator: " ").map(String.init)
        let leading: Set<String> = ["editions", "edition", "ed", "les", "le", "la", "l", "groupe"]
        while let first = words.first, leading.contains(first), words.count > 1 { words.removeFirst() }
        if words.count > 1, ["editions", "edition"].contains(words.last!) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Verdict pour une proposition (éditeur, titre, auteurs) ; nil si la couverture ne permet pas de trancher.
    public static func verdict(for d: CatalogDifference, book: MetadataEdits, cover: CoverText,
                               publishers: [String]) -> CoverVerdict? {
        switch d.field {
        case .publisher: publisherVerdict(proposed: d.proposed, current: book.publisher, book: book,
                                          cover: cover, publishers: publishers)
        case .title: titleVerdict(proposed: d.proposed, current: book.title, cover: cover)
        case .authors: authorsVerdict(proposed: d.proposed, current: book.authors, cover: cover)
        default: nil
        }
    }

    static func publisherVerdict(proposed: String, current: String?, book: MetadataEdits, cover: CoverText,
                                 publishers: [String]) -> CoverVerdict? {
        let proposedCore = publisherCore(proposed)
        if cover.contains(proposedCore) { return .confirmed }
        // Un nom d'éditeur présent dans le titre ou les auteurs (« Au seuil de… ») ne prouve rien.
        let bookWords = " " + Matching.key(([book.title] + book.authors).joined(separator: " ")) + " "
        let candidates = ([current].compactMap { $0 } + publishers + knownPublishers)
            .map { ($0, publisherCore($0)) }
            .filter { $0.1.count >= 2 && $0.1 != proposedCore && !bookWords.contains(" \($0.1) ") && cover.contains($0.1) }
        // Le nom le plus long l'emporte (« Albin Michel » plutôt que « Michel ») ; la valeur actuelle est préférée à égalité.
        guard let best = candidates.max(by: { $0.1.count < $1.1.count }) else { return nil }
        let display = candidates.first { $0.1 == best.1 }!.0
        return .contradicted(display)
    }

    static func titleVerdict(proposed: String, current: String, cover: CoverText) -> CoverVerdict? {
        if cover.contains(proposed) || cover.contains(Matching.mainTitle(proposed)) { return .confirmed }
        if cover.contains(current) || cover.contains(Matching.mainTitle(current)) { return .contradicted(nil) }
        return nil
    }

    static func authorsVerdict(proposed: String, current: [String], cover: CoverText) -> CoverVerdict? {
        let names = proposed.components(separatedBy: ", ").filter { !$0.isEmpty }
        if !names.isEmpty, names.allSatisfy({ cover.contains(Matching.surname($0)) }) { return .confirmed }
        if !current.isEmpty, current.allSatisfy({ cover.contains(Matching.surname($0)) }) { return .contradicted(nil) }
        return nil
    }
}
