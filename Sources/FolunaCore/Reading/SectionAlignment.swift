import Foundation

/// Correspondance entre les chapitres de deux éditions d'un même texte, pour la comparaison (S-104) :
/// l'original et sa traduction, deux traductions, deux éditions.
///
/// Les chapitres sont appariés par leur longueur relative, à la manière de l'alignement de Gale et Church :
/// un chapitre en face d'un chapitre, d'aucun (page de titre, préface propre à une édition), ou de deux
/// (chapitre coupé dans l'autre édition). Une traduction plus longue de 20 % garde ses chapitres en face.
public struct SectionAlignment: Sendable, Equatable {
    /// Groupe de chapitres en face l'un de l'autre : `left` et `right` sont des plages, vides pour un chapitre sans pendant.
    public struct Bead: Sendable, Equatable {
        public let left: Range<Int>
        public let right: Range<Int>
    }

    public let beads: [Bead]
    let leftWeights: [Double]
    let rightWeights: [Double]

    /// Aligne deux livres d'après la taille de leurs chapitres (`ReaderBook.weights`).
    public init(left: [Int], right: [Int]) {
        leftWeights = Self.normalized(left)
        rightWeights = Self.normalized(right)
        beads = Self.align(leftWeights, rightWeights)
    }

    /// Position en face, dans l'autre livre, d'une position (chapitre, avancée de 0 à 1 dans le chapitre).
    /// `fromLeft` : la position donnée est dans le livre de gauche.
    public func counterpart(chapter: Int, fraction: Double, fromLeft: Bool = true) -> (chapter: Int, fraction: Double) {
        let fraction = min(1, max(0, fraction))
        let sourceWeights = fromLeft ? leftWeights : rightWeights
        let targetWeights = fromLeft ? rightWeights : leftWeights
        guard !targetWeights.isEmpty else { return (0, 0) }
        let side: (Bead) -> Range<Int> = { fromLeft ? $0.left : $0.right }
        let other: (Bead) -> Range<Int> = { fromLeft ? $0.right : $0.left }
        guard let index = beads.firstIndex(where: { side($0).contains(chapter) }) else {
            return (min(chapter, targetWeights.count - 1), fraction)
        }
        let bead = beads[index]
        // Chapitre sans pendant : début du groupe suivant qui en a un, sinon fin du précédent.
        if other(bead).isEmpty {
            if let next = beads[(index + 1)...].first(where: { !other($0).isEmpty }) { return (other(next).lowerBound, 0) }
            if let previous = beads[..<index].last(where: { !other($0).isEmpty }) { return (other(previous).upperBound - 1, 1) }
            return (0, 0)
        }
        // Avancée dans le groupe, reportée sur les chapitres d'en face au prorata de leur longueur.
        let source = side(bead)
        let total = source.reduce(0) { $0 + sourceWeights[$1] }
        let before = source.prefix { $0 < chapter }.reduce(0) { $0 + sourceWeights[$1] }
        let progress = total > 0 ? (before + fraction * sourceWeights[chapter]) / total : fraction
        let target = other(bead)
        let targetTotal = target.reduce(0) { $0 + targetWeights[$1] }
        var remaining = progress * targetTotal
        for c in target {
            let w = targetWeights[c]
            if remaining <= w || c == target.upperBound - 1 {
                return (c, w > 0 ? min(1, max(0, remaining / w)) : 0)
            }
            remaining -= w
        }
        return (target.lowerBound, 0)
    }

    // MARK: Alignement

    static func normalized(_ weights: [Int]) -> [Double] {
        let total = Double(weights.reduce(0) { $0 + max(0, $1) })
        return total > 0 ? weights.map { Double(max(0, $0)) / total } : weights.map { _ in 0 }
    }

    /// Écart de longueur entre deux groupes (khi-deux) : nul à longueurs égales, faible pour deux petits chapitres.
    static func mismatch(_ a: Double, _ b: Double) -> Double {
        let d = a - b
        return 50 * d * d / (a + b + 0.0001)
    }

    /// Un chapitre laissé sans pendant : peu coûteux s'il est court (couverture, page de titre), cher sinon.
    static func skip(_ w: Double) -> Double { 0.5 + 20 * w }

    /// Coût d'un groupe coupé ou fusionné, en plus de l'écart de longueur.
    static let splitPenalty = 1.5

    static func align(_ a: [Double], _ b: [Double]) -> [Bead] {
        let n = a.count, m = b.count
        guard n > 0 || m > 0 else { return [] }
        var cost = Array(repeating: Array(repeating: Double.infinity, count: m + 1), count: n + 1)
        var move = Array(repeating: Array(repeating: (0, 0), count: m + 1), count: n + 1)
        cost[0][0] = 0
        let steps = [(1, 1), (1, 0), (0, 1), (2, 1), (1, 2)]
        for i in 0...n {
            for j in 0...m where cost[i][j] < .infinity {
                for (di, dj) in steps where i + di <= n && j + dj <= m {
                    let left = a[i..<(i + di)].reduce(0, +), right = b[j..<(j + dj)].reduce(0, +)
                    let step: Double = switch (di, dj) {
                    case (1, 0): skip(left)
                    case (0, 1): skip(right)
                    case (1, 1): mismatch(left, right)
                    default: mismatch(left, right) + splitPenalty
                    }
                    if cost[i][j] + step < cost[i + di][j + dj] {
                        cost[i + di][j + dj] = cost[i][j] + step
                        move[i + di][j + dj] = (di, dj)
                    }
                }
            }
        }
        var beads: [Bead] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let (di, dj) = move[i][j]
            beads.append(Bead(left: (i - di)..<i, right: (j - dj)..<j))
            i -= di
            j -= dj
        }
        return beads.reversed()
    }
}
