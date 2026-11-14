import Foundation

/// Livres inventés, reproductibles, pour les tests de résistance (`StressTests`, `Foluna --stress`).
/// Le même numéro donne toujours le même livre : les paliers se comparent d'un passage à l'autre.
public enum StressCatalog {
    public struct Entry: Sendable {
        public let title: String
        public let authors: [String]
        public let language: String
        public let publisher: String
        public let series: String?
        public let seriesIndex: Double?
        public let subjects: [String]
        public let userTags: [String]
        public let summary: String
    }

    /// Titre commun du lot pathologique : beaucoup de livres au même titre, d'auteurs différents.
    public static let sharedTitle = "Mémoires"

    public static func entry(_ i: Int) -> Entry {
        var r = SplitMix64(seed: UInt64(i) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        let title = "\(r.pick(nouns)) \(r.pick(adjectives)) \(r.pick(links)) \(r.pick(nouns).lowercased())"
        let authorCount = r.next() % 10 == 0 ? 2 : 1
        let authors = (0..<authorCount).map { _ in "\(r.pick(firstNames)) \(r.pick(lastNames))" }
        let inSeries = r.next() % 10 == 0
        let tagCount = r.next() % 5 == 0 ? Int(r.next() % 3) + 1 : 0
        return Entry(
            title: title, authors: authors,
            language: r.pick(["fr", "fr", "en", "de", "nl", "es"]),
            publisher: r.pick(publishers),
            series: inSeries ? "Cycle \(r.pick(nouns).lowercased()) \(r.pick(adjectives))" : nil,
            seriesIndex: inSeries ? Double(r.next() % 12 + 1) : nil,
            subjects: [r.pick(subjects)],
            userTags: (0..<tagCount).map { _ in r.pick(tags) },
            summary: "Roman inventé n° \(i). " + String(repeating: "Une phrase de résumé assez ordinaire. ", count: Int(r.next() % 6) + 1))
    }

    static let nouns = ["Le Jardin", "La Maison", "Le Fleuve", "La Nuit", "Le Voyageur", "La Lettre", "Le Miroir",
                        "La Forêt", "Le Silence", "La Ville", "Le Phare", "La Montagne", "Le Secret", "La Mémoire",
                        "Le Chemin", "La Saison", "Le Navire", "La Porte", "Le Rêve", "La Plaine", "Le Pont",
                        "La Tour", "Le Désert", "L'Île", "Le Carnet", "La Rive", "Le Vent", "La Lumière",
                        "Le Temps", "La Promesse", "Le Masque", "La Frontière", "Le Royaume", "La Source",
                        "Le Village", "La Neige", "Le Feu", "L'Ombre", "Le Livre", "La Route"]
    static let adjectives = ["oublié", "perdu", "secret", "immobile", "lointain", "endormi", "silencieux", "brisé",
                             "invisible", "dernier", "premier", "éternel", "étrange", "ancien", "nouveau", "sauvage",
                             "fragile", "profond", "doré", "gris", "bleu", "rouge", "obscur", "clair", "vide",
                             "suspendu", "intérieur", "rêvé", "caché", "retrouvé", "tranquille", "noir",
                             "blanc", "ardent", "fidèle", "errant", "vivant", "muet", "inachevé", "double"]
    static let links = ["de", "sous", "après", "contre", "au-delà de", "avant", "près de", "sans", "pour", "dans"]
    static let firstNames = ["Anne", "Louis", "Claire", "Hugo", "Inès", "Paul", "Léa", "Marc", "Sophie", "Jules",
                             "Emma", "Victor", "Alice", "Noé", "Zoé", "Yann", "Mira", "Omar", "Lina", "Théo",
                             "Nora", "Félix", "Rosa", "Ivan", "Elsa", "Karim", "Maud", "Simon", "Jeanne", "Malo",
                             "Agathe", "Bruno", "Chloé", "David", "Eva", "Fanny", "Gaël", "Hélène", "Igor", "Joël",
                             "Katia", "Lucas", "Marie", "Nils", "Olga", "Pierre", "Quentin", "Rémi", "Sara", "Tom"]
    static let lastNames = ["Martin", "Bernard", "Dubois", "Lefèvre", "Moreau", "Laurent", "Garnier", "Roux",
                            "Fournier", "Girard", "Bonnet", "Dupont", "Lambert", "Fontaine", "Rousseau", "Vincent",
                            "Muller", "Leroy", "Faure", "André", "Mercier", "Blanc", "Guérin", "Boyer", "Chevalier",
                            "François", "Legrand", "Gauthier", "Perrin", "Robin", "Clément", "Morin", "Nicolas",
                            "Henry", "Roussel", "Mathieu", "Gautier", "Masson", "Marchand", "Duval", "Denis",
                            "Dumont", "Marie", "Lemaire", "Noël", "Meyer", "Dufour", "Meunier", "Brun", "Blanchard",
                            "Giraud", "Joly", "Rivière", "Lucas", "Brunet", "Gaillard", "Barbier", "Arnaud",
                            "Martinez", "Gérard", "Roche", "Renard", "Schmitt", "Roy", "Leroux", "Colin", "Vidal",
                            "Caron", "Picard", "Roger", "Fabre", "Aubert", "Lemoine", "Renaud", "Dumas", "Lacroix",
                            "Olivier", "Philippe", "Bourgeois", "Pierre"]
    static let publishers = ["Éditions du Nord", "Le Petit Atelier", "Maison Lune", "Presses de la Rive",
                             "Éditions Sable", "Le Grenier", "Ombre et Papier", "Collection Brume"]
    static let subjects = ["Roman", "Policier", "Poésie", "Histoire", "Science-fiction", "Essai", "Jeunesse",
                           "Voyage", "Théâtre", "Fantastique"]
    static let tags = ["À lire", "Club de lecture", "Prêté", "Été", "Relire", "Cadeau", "Cours", "Vacances",
                       "Préféré", "Recherche", "Famille", "Bibliothèque", "Classique", "Nouveauté", "Long",
                       "Court", "Audio", "Papier aussi", "Offert", "Liste 2026"]
}

/// Générateur pseudo-aléatoire minuscule et reproductible (pas de dépendance à l'aléatoire du système).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func pick<T>(_ list: [T]) -> T { list[Int(next() % UInt64(list.count))] }
}
