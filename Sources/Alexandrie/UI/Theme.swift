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

/// Fonds de la fenêtre de lecture (S-069) : papier et encre, passés en CSS au livre affiché.
/// Le PDF garde ses propres couleurs ; seul le tour de page suit le fond choisi.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, dark

    var id: Self { self }

    var label: String {
        switch self {
        case .light: "Clair"
        case .sepia: "Sépia"
        case .dark: "Sombre"
        }
    }

    /// Papier, en CSS.
    var paper: String {
        switch self {
        case .light: "#FFFFFF"
        case .sepia: "#F4ECD8"
        case .dark: "#1E1E20"
        }
    }

    /// Encre, en CSS.
    var ink: String {
        switch self {
        case .light: "#1D1D1F"
        case .sepia: "#4B3A2A"
        case .dark: "#E3E3E6"
        }
    }

    /// Surlignage, en CSS : assez clair pour garder le texte lisible sur chaque papier.
    var highlight: String {
        switch self {
        case .light, .sepia: "rgba(255, 204, 0, 0.42)"
        case .dark: "rgba(255, 204, 0, 0.32)"
        }
    }

    var paperColor: Color { Color(nsColor: NSColor(css: paper)) }
}

private extension NSColor {
    /// « #RRGGBB » seulement : les jetons ci-dessus.
    convenience init(css: String) {
        let value = Int(css.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
