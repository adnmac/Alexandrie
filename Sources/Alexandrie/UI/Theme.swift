import AppKit
import SwiftUI

/// Couleurs de l'app. Alexandrie n'a pas de couleur de marque : l'accent est celui choisi pour le Mac
/// (Réglages Système > Apparence), sans sélecteur propre à l'app. Voir `design/DESIGN-SYSTEM.md`.
enum Palette {
    /// Accent du Mac : remplissages, contours de sélection, informations neutres.
    static let accent = Color.accentColor
    /// Texte et symboles posés sur un remplissage d'accent (jamais un blanc fixe).
    static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)

    // États : toujours accompagnés d'un symbole ou d'un mot, jamais la couleur seule.
    // Couleurs système : elles ont déjà leurs teintes sombre et Contraste élevé.

    /// Fait, présent sur la Kindle, branchée.
    static let success = Color.green
    /// À vérifier, à corriger, échec partiel : l'action reste possible.
    static let warning = Color.orange
    /// Erreur qui bloque l'action.
    static let danger = Color.red
    /// En attente, information, mise à jour : suit l'accent.
    static let info = Color.accentColor
}
