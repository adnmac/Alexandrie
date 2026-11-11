import SwiftUI

/// Rayons d'angle. Les angles imbriqués sont concentriques : rayon intérieur = extérieur - marge.
enum Radius {
    /// Couverture de livre, et son contour de sélection posé dessus.
    static let cover: CGFloat = 4
    /// Cadre d'un champ de texte dessiné à la main (`TextEditor`).
    static let field: CGFloat = 4
    /// Fond de survol d'un bouton sans bordure (`HoverButtonStyle`).
    static let hover: CGFloat = 5
    /// Zone de dépôt qui entoure la fenêtre.
    static let dropZone: CGFloat = 12
}
