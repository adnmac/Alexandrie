import Foundation

/// Marque d'une liseuse : où vont les livres, quels formats elle lit, ce que Foluna lui envoie.
/// Le transport (disque USB, MTP) est à part : voir `KindleDevice`.
public enum ReaderBrand: String, Codable, CaseIterable, Sendable {
    /// Amazon Kindle : AZW3, MOBI, PDF ; l'EPUB est converti en AZW3.
    case kindle
    /// Rakuten Kobo : lit l'EPUB tel quel (et le PDF).
    case kobo
    /// Autre liseuse qui lit l'EPUB (PocketBook, Tolino…), ajoutée par l'utilisateur.
    case generic

    public var label: String {
        switch self {
        case .kindle: "Kindle"
        case .kobo: "Kobo"
        case .generic: String(localized: "Liseuse USB")
        }
    }

    /// Lit l'EPUB : un livre lui est envoyé en EPUB plutôt qu'en AZW3.
    public var readsEPUB: Bool { self != .kindle }

    /// Dossier d'envoi des livres, relatif à la racine du disque (le dossier choisi pour une liseuse générique).
    public var defaultBooksFolder: String {
        switch self {
        case .kindle: "documents"
        case .kobo: "Books"
        case .generic: ""
        }
    }

    /// Dossier parcouru pour la liste des livres présents : la Kobo range ses livres n'importe où sur le disque.
    public func listFolder(booksFolder: String) -> String {
        self == .kobo ? "" : booksFolder
    }

    /// Miniature de couverture déposée à côté du livre (la Kobo et les autres la tirent du fichier).
    public var sendsThumbnails: Bool { self == .kindle }

    /// Extensions des livres affichés dans la liste de l'appareil.
    public var bookExtensions: Set<String> {
        switch self {
        case .kindle: ["azw3", "azw", "mobi", "pdf", "kfx", "txt", "prc", "azw8"]
        case .kobo: ["epub", "pdf", "mobi", "txt", "cbz", "cbr", "rtf", "html"]
        case .generic: ["epub", "pdf", "mobi", "fb2", "txt", "djvu", "cbz", "rtf"]
        }
    }

    /// Dossiers jamais parcourus (données de l'appareil).
    var hiddenFolders: Set<String> {
        switch self {
        case .kindle: []
        case .kobo: [".kobo", ".kobo-images", ".adobe-digital-editions", "System Volume Information"]
        case .generic: ["System Volume Information", "system"]
        }
    }

    /// Fichier à présenter comme un livre (exclut le fichier de notes de la Kindle).
    public func isBook(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return bookExtensions.contains((name as NSString).pathExtension.lowercased())
            && name.caseInsensitiveCompare("My Clippings.txt") != .orderedSame
    }
}

extension Book {
    /// Format du fichier envoyé à une liseuse de cette marque.
    /// Kindle : AZW3 pour un EPUB ou un PDF en texte redimensionnable. Autres : EPUB pour un livre Kindle
    /// (MOBI, AZW3, AZW) ou un PDF en texte redimensionnable ; le reste tel quel.
    public func sentExtension(for brand: ReaderBrand) -> String {
        guard brand.readsEPUB else { return becomesAZW3 ? "azw3" : format.rawValue }
        if format == .pdf { return pdfMode == .reflowable ? "epub" : "pdf" }
        return "epub"
    }

    /// Une conversion ou une copie corrigée précède l'envoi.
    public func needsConversion(for brand: ReaderBrand) -> Bool {
        guard brand.readsEPUB else { return needsConversion }
        return format != .pdf || pdfMode == .cropped || pdfMode == .reflowable
    }

    /// Peut partir sur une liseuse de cette marque. Un livre Kindle sous DRM ne se lit que sur une Kindle ;
    /// un EPUB sous DRM (Adobe) part tel quel sur une liseuse EPUB, jamais converti.
    public func canSend(to brand: ReaderBrand) -> Bool {
        guard isDRMProtected else { return true }
        return brand.readsEPUB ? format == .epub || format == .pdf : format.isKindleNative
    }

    /// Peut partir sur au moins une marque de liseuse (file d'attente, liseuse pas encore branchée).
    public var canSendToAnyReader: Bool { ReaderBrand.allCases.contains(where: canSend(to:)) }

    /// Nom proposé pour la copie sur une liseuse de cette marque.
    public func filename(for brand: ReaderBrand) -> String {
        let author = authors.first.map { " - \($0)" } ?? ""
        return "\(title)\(author)".safeFilename + "." + (isDRMProtected ? format.rawValue : sentExtension(for: brand))
    }
}
