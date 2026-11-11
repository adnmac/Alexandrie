import SwiftUI

/// Surfaces dessinées par l'app. Les autres fonds viennent du système.
enum Surface {
    /// Opacité du fond teinté d'un bandeau (`.banner(_:)`).
    static let bannerTint = 0.12
    /// Ombre portée d'une couverture : la couverture est du contenu, posé sur la page.
    static let coverShadow = Color.black.opacity(0.18)
    static let coverShadowRadius: CGFloat = 4
    static let coverShadowY: CGFloat = 2
}

extension View {
    /// Bandeau en haut d'une page (mise à jour, livres à ranger) : marge, commandes petites, fond teinté.
    /// La teinte dit le genre de message : `Palette.info` ou `Palette.warning`.
    func banner(_ tint: Color) -> some View {
        controlSize(.small)
            .padding(Space.md)
            .background(tint.opacity(Surface.bannerTint))
    }
}
