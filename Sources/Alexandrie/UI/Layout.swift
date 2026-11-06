import SwiftUI

/// Largeurs fixes : feuilles et fenêtre des réglages. Les feuilles font 360, 480 ou 640 pt.
enum Layout {
    /// Feuille courte : un nom, une question.
    static let sheetNarrow: CGFloat = 360
    /// Feuille ordinaire : un formulaire.
    static let sheet: CGFloat = 480
    /// Feuille large : formulaire à deux colonnes, aperçu.
    static let sheetWide: CGFloat = 640
    /// Réglages Mac : chaque onglet est un `Form` groupé de cette largeur.
    static let settingsWidth: CGFloat = 520
    /// Hauteur au-delà de laquelle une feuille ou un onglet des réglages défile.
    static let maxPanelHeight: CGFloat = 640
}
