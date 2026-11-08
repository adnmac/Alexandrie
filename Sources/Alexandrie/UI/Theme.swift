import AlexandrieCore
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

    /// Surlignage de cette couleur, en CSS : assez clair pour garder le texte lisible sur chaque papier.
    func highlight(_ mark: HighlightMark) -> String {
        let (r, g, b) = mark.rgb
        return "rgba(\(r), \(g), \(b), \(self == .dark ? 0.32 : 0.42))"
    }

    var paperColor: Color { Color(nsColor: NSColor(css: paper)) }

    /// Surlignage d'une page de PDF (annotation) : la couleur de `highlight` sur papier clair, un PDF gardant son papier.
    static func pdfHighlight(_ mark: HighlightMark) -> NSColor {
        let (r, g, b) = mark.rgb
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 0.42)
    }
}

/// Police de la fenêtre de lecture (S-095) : celle du livre, ou une police installée avec macOS, passée en CSS.
/// Le code (`pre`, `code`) garde sa chasse fixe ; le PDF garde ses polices.
enum ReaderFont: String, CaseIterable, Identifiable {
    case book
    // Avec empattements.
    case newYork, charter, iowan, georgia, palatino, baskerville, hoefler
    // Sans empattements.
    case system, avenir, helvetica, optima, verdana

    var id: Self { self }

    static let serif: [ReaderFont] = [.newYork, .charter, .iowan, .georgia, .palatino, .baskerville, .hoefler]
    static let sansSerif: [ReaderFont] = [.system, .avenir, .helvetica, .optima, .verdana]

    var label: String {
        switch self {
        case .book: "Police du livre"
        case .newYork: "New York"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .baskerville: "Baskerville"
        case .hoefler: "Hoefler Text"
        case .system: "San Francisco"
        case .avenir: "Avenir Next"
        case .helvetica: "Helvetica Neue"
        case .optima: "Optima"
        case .verdana: "Verdana"
        }
    }

    /// Pile de polices CSS (avec un repli de la même famille) ; nil : celle du livre.
    var css: String? {
        switch self {
        case .book: nil
        case .newYork: "ui-serif, Georgia, serif"
        case .charter: "Charter, Georgia, serif"
        case .iowan: "'Iowan Old Style', Georgia, serif"
        case .georgia: "Georgia, serif"
        case .palatino: "Palatino, 'Palatino Linotype', serif"
        case .baskerville: "Baskerville, Georgia, serif"
        case .hoefler: "'Hoefler Text', Georgia, serif"
        case .system: "system-ui, -apple-system, sans-serif"
        case .avenir: "'Avenir Next', Avenir, sans-serif"
        case .helvetica: "'Helvetica Neue', Helvetica, sans-serif"
        case .optima: "Optima, sans-serif"
        case .verdana: "Verdana, sans-serif"
        }
    }

    /// Aperçu du nom dans sa police, dans le menu.
    var preview: Font {
        switch self {
        case .book: .body
        case .newYork: .system(.body, design: .serif)
        case .system: .system(.body)
        default: .custom(label, size: NSFont.systemFontSize)
        }
    }
}

extension HighlightMark {
    /// Pastille pleine de la couleur d'un surlignage ou d'un thème.
    var swatch: Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

/// Couleurs des surlignages (S-073) : les teintes système de macOS, en sRGB (`HighlightColor.hex`).
extension HighlightColor {
    /// Pastille pleine, pour choisir la couleur et la rappeler dans « Notes et surlignages ».
    var swatch: Color { HighlightMark(self).swatch }

    /// Couleur du prochain surlignage : la dernière choisie.
    static var current: HighlightColor {
        get { UserDefaults.standard.string(forKey: "highlightColor").flatMap(HighlightColor.init(rawValue:)) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "highlightColor") }
    }
}

private extension NSColor {
    /// « #RRGGBB » seulement : les jetons ci-dessus.
    convenience init(css: String) {
        let value = Int(css.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
