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
    /// Bulle de la note d'un surlignage, dans la fenêtre de lecture (S-071).
    static let notePopover: CGFloat = 320
    /// Pastille d'une couleur de surlignage (S-073).
    static let colorSwatch: CGFloat = 18
    /// Feuille « Recherches » (S-075) : hauteur, liste des recherches, colonne des comptes.
    static let researchesHeight: CGFloat = 440
    static let researchesSidebar: CGFloat = 200
    static let countColumn: CGFloat = 24
    /// Menu de la thématique dans la barre d'outils de lecture (S-079) : au-delà, le nom est coupé.
    static let toolbarMenu: CGFloat = 136
    /// Recherche dans le contenu (S-082) : couverture d'un résultat, barre de progression de l'indexation.
    static let resultCover: CGFloat = 48
    static let indexProgress: CGFloat = 160
    /// Couverture de la fiche d'un livre d'un catalogue en ligne (S-088), comme celle de la bibliothèque.
    static let detailCover: CGFloat = 280
    /// Feuille « Catalogues en ligne » (S-089) : hauteur de la liste.
    static let catalogsList: CGFloat = 200
}
